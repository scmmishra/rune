import Foundation
import GhosttyTerminal

/// The MCP tools that act on an open pane: type a command into it, interrupt it, wait for
/// its output, show it, or close it. An agent cannot type into, interrupt or close its own
/// pane, or a pane where another agent runs.
@MainActor
enum PaneTools {
    static let names: Set<String> = [
        "rune_send_to_terminal", "rune_interrupt_terminal", "rune_close_terminal",
        "rune_wait_for_output", "rune_focus_terminal",
    ]

    /// Codex gives an MCP tool 60 seconds by default, so a wait has to end before that.
    private static let maximumWait = 50.0

    static func handle(_ tool: String, _ arguments: [String: JSONValue], caller: TerminalSession,
                       terminals: TerminalSessions, find: (String) -> TerminalSession?,
                       show: (TerminalSession) -> Void) async -> RuneControlReply {
        guard let reference = arguments["pane"]?.string, let session = find(reference) else {
            return .failure("Name a pane by the id or the name that rune_space lists.")
        }
        let isCaller = session.id == caller.id
        switch tool {
        case "rune_focus_terminal":
            show(session)
            return RuneControlReply(text: "Showed \(session.name) and gave it the keyboard.")
        case "rune_wait_for_output":
            guard let text = arguments["text"]?.string, !text.isEmpty else { return .failure("Give the text to wait for.") }
            let timeout = arguments["timeout"]?.number.map { min(maximumWait, max(1, $0)) } ?? 30
            return await wait(for: text, in: session, timeout: timeout)
        default:
            break
        }
        if isCaller { return .failure("That is your own pane. Use your shell tool to run commands there.") }
        if let agent = session.agent { return .failure("\(agent.rawValue) runs in \(session.name). Rune does not act on another agent's pane.") }
        if session.savedCommandID != nil {
            return .failure("\(session.name) is a saved command. Use rune_stop_command, rune_restart_command or rune_delete_command.")
        }
        switch tool {
        case "rune_send_to_terminal":
            guard let command = arguments["command"]?.string, !command.isEmpty else { return .failure("Give the command to type.") }
            // Rune samples each shell's foreground process once a second, so a new pane has none yet.
            guard let foreground = session.foreground else {
                return .failure("\(session.name) has not started yet. Try again in a moment.")
            }
            guard !session.hasExited, foreground.isIdle else {
                return .failure("\(session.name) is not at a shell prompt. \(foreground.name) runs there. Interrupt it first, or open a new pane.")
            }
            // The command goes in as a paste, so a newline in it never runs a line early.
            // Return is a key press, which runs the whole command.
            guard session.terminal.paste(text: command), session.terminal.sendKey(.enter) else {
                return .failure("\(session.name) has not started yet.")
            }
            return RuneControlReply(text: "Ran the command in \(session.name). Read its output with rune_read_terminal or rune_wait_for_output.")
        case "rune_interrupt_terminal":
            guard session.foreground?.isIdle == false else { return RuneControlReply(text: "Nothing runs in \(session.name).") }
            guard session.terminal.sendKey(.c, modifiers: .ctrl) else { return .failure("\(session.name) has not started yet.") }
            return RuneControlReply(text: "Sent Ctrl-C to \(session.name).")
        case "rune_close_terminal":
            guard session.id != terminals.primary.id else { return .failure("The main terminal cannot be closed.") }
            await terminals.terminate(session)
            guard terminals.session(session.id) == nil else { return .failure("Could not close \(session.name).") }
            return RuneControlReply(text: "Closed \(session.name) and stopped its processes.")
        default:
            return .failure("Rune has no tool named \(tool).")
        }
    }

    /// Waits for `text` to appear in output printed after the call. Text already on the
    /// screen does not count, so a server's earlier "ready" line does not end the wait.
    private static func wait(for text: String, in session: TerminalSession, timeout: Double) async -> RuneControlReply {
        func count() -> Int? {
            session.recentText(lines: 2_000).map { $0.components(separatedBy: text).count - 1 }
        }
        guard let start = count() else { return .failure("\(session.name) has not started yet.") }
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            if let current = count(), current > start {
                return RuneControlReply(text: "\(session.name) printed \"\(text)\".\n\n" + tail(of: session))
            }
            if session.hasExited { return .failure("\(session.name) exited first.\n\n" + tail(of: session)) }
        }
        return .failure("\(session.name) did not print \"\(text)\" within \(Int(timeout)) seconds.\n\n" + tail(of: session))
    }

    private static func tail(of session: TerminalSession) -> String {
        "Last lines:\n" + (session.recentText(lines: 30) ?? "")
    }
}
