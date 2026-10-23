import Foundation
import Darwin

/// `Rune --rune-mcp`: the MCP server an agent starts over stdio. It holds no state of its
/// own. It passes each tool call to the Rune whose terminal it runs in, and outside Rune
/// it offers no tools.
nonisolated enum RuneMCPServer {
    private static let argument = "--rune-mcp"

    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.dropFirst().first == argument else { return false }
        // A closed client must end the server, not kill it with SIGPIPE mid-write.
        signal(SIGPIPE, SIG_IGN)
        let socket = enclosingSocket()
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // Notifications carry no ID and get no reply.
            guard let id = message["id"] else { continue }
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]
            let response: [String: Any]
            switch method {
            case "initialize":
                response = ["jsonrpc": "2.0", "id": id, "result": initializeResult(params: params, socket: socket)]
            case "tools/list":
                response = ["jsonrpc": "2.0", "id": id, "result": ["tools": socket == nil ? [] : tools]]
            case "tools/call":
                response = ["jsonrpc": "2.0", "id": id, "result": call(params: params, socket: socket)]
            case "ping":
                response = ["jsonrpc": "2.0", "id": id, "result": [String: Any]()]
            default:
                response = ["jsonrpc": "2.0", "id": id,
                            "error": ["code": -32601, "message": "Unknown method \(method)"]]
            }
            guard let output = try? JSONSerialization.data(withJSONObject: response) else { continue }
            FileHandle.standardOutput.write(output + Data("\n".utf8))
        }
        return true
    }

    /// The socket of the Rune this server runs under: the nearest ancestor that has one.
    private static func enclosingSocket() -> String? {
        RuneControl.ancestry(of: getpid()).lazy
            .map(RuneControl.socketPath(for:))
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func initializeResult(params: [String: Any], socket: String?) -> [String: Any] {
        var result: [String: Any] = [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "rune", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"],
        ]
        if socket != nil { result["instructions"] = instructions }
        return result
    }

    private static let instructions = """
    You are running in a terminal pane of Rune, a Mac app that shows a repository in one window. \
    The window has a hub of terminal tabs and split panes, and columns of cards beside it. \
    Use these tools to show the user what you are talking about: open a file at a line, open a diff, or show a plan as Markdown. \
    Read other terminals in the window to see what a dev server or a test run printed. \
    Call rune_notify when you finish a long task or need an answer. \
    Use rune_open_terminal to run something long-lived, such as a dev server or a test watcher, in a pane beside yours. \
    The user keeps the processes they run often, such as dev servers, as saved commands. Use the rune_*_command tools to list, change, run and stop them. \
    The tools act only on the window that contains your terminal.
    """

    private static var tools: [[String: Any]] { [
        tool("rune_space", "Describe the Rune window you run in: its repository, branch, setup, variables, and terminal tabs. The pane marked as yours is where you run.",
             properties: [:]),
        tool("rune_open_file", "Open a file in Rune's preview drawer, scrolled to a line. Use it to show the user code you are talking about.",
             properties: [
                "path": ["type": "string", "description": "Path to the file, absolute or relative to the repository root."],
                "line": ["type": "integer", "description": "Line to scroll to, starting at 1."],
             ], required: ["path"]),
        tool("rune_open_diff", "Open the diff of an uncommitted change to a file in Rune's diff drawer.",
             properties: [
                "path": ["type": "string", "description": "Path to the changed file, absolute or relative to the repository root."],
                "staged": ["type": "boolean", "description": "Show the staged diff instead of the unstaged one."],
             ], required: ["path"]),
        tool("rune_open_terminal", "Open a terminal pane beside yours in the repository root, and run a command in it. The shell stays open after the command ends. Your pane keeps the keyboard.",
             properties: [
                "command": ["type": "string", "description": "Shell command to run. Leave it out for an empty shell."],
                "name": ["type": "string", "description": "Name shown on the pane."],
                "placement": ["type": "string", "enum": ["right", "down", "tab"],
                              "description": "Split your pane to the right (default) or down, or open a new tab."],
             ]),
        tool("rune_read_terminal", "Read the last lines of a terminal in your window, scrollback included. Use it to see a dev server's errors or a test run's output. Name the pane by the id or name that rune_space lists. Saved commands count as panes.",
             properties: [
                "pane": ["type": "string", "description": "The pane's id or name, from rune_space."],
                "lines": ["type": "integer", "description": "How many lines from the end. Defaults to 200."],
             ], required: ["pane"]),
        tool("rune_notify", "Tell the user something needs them, such as a finished task or a question. Your tab shows that it is waiting. If the Rune window is focused, Rune shows the message in the window. If not, it sends a macOS notification. If your pane has the keyboard, nothing is shown.",
             properties: [
                "message": ["type": "string", "description": "One short sentence."],
             ], required: ["message"]),
        tool("rune_open_markdown", "Show Markdown in Rune's preview drawer, such as a plan or a summary. Mermaid code blocks render as diagrams. Links to repository paths, such as `src/app.ts:42`, open that file at that line. A second call replaces the page.",
             properties: [
                "title": ["type": "string", "description": "Title shown above the page."],
                "markdown": ["type": "string", "description": "The Markdown to show."],
             ], required: ["markdown"]),
        tool("rune_send_to_terminal", "Type a command into a terminal pane and press Return. The pane must be at a shell prompt. It cannot be your own pane, a pane where another agent runs, or a saved command. Use it to rerun a command in a pane you opened.",
             properties: [
                "pane": ["type": "string", "description": "The pane's id or name, from rune_space."],
                "command": ["type": "string", "description": "The command to run."],
             ], required: ["pane", "command"]),
        tool("rune_interrupt_terminal", "Send Ctrl-C to a terminal pane, to stop what runs there but keep the pane open. It cannot be your own pane, a pane where another agent runs, or a saved command.",
             properties: ["pane": ["type": "string", "description": "The pane's id or name, from rune_space."]],
             required: ["pane"]),
        tool("rune_close_terminal", "Close a terminal pane and stop its processes. Use it for panes you opened and no longer need. It cannot be your own pane, the main terminal, a pane where another agent runs, or a saved command.",
             properties: ["pane": ["type": "string", "description": "The pane's id or name, from rune_space."]],
             required: ["pane"]),
        tool("rune_wait_for_output", "Wait until a terminal prints some text, such as a server's ready line or a test summary. Only output printed after the call counts. Returns the last lines of the terminal when the text appears or the time runs out.",
             properties: [
                "pane": ["type": "string", "description": "The pane's id or name, from rune_space or rune_list_commands."],
                "text": ["type": "string", "description": "Text to wait for. The match is exact and case-sensitive."],
                "timeout": ["type": "number", "description": "Seconds to wait. Defaults to 30, at most 50."],
             ], required: ["pane", "text"]),
        tool("rune_focus_terminal", "Show a terminal pane and give it the keyboard, so the user can answer a prompt there. It takes the keyboard from the user, so use it only when the user has to act in that pane.",
             properties: ["pane": ["type": "string", "description": "The pane's id or name, from rune_space."]],
             required: ["pane"]),
        tool("rune_list_commands", "List the saved commands of the Commands card: dev servers, watchers and other processes the user runs for this repository. Each shows its shell command, folder, group, auto-start, and status. A running command also shows its pane, for rune_read_terminal, and the TCP ports it listens on.",
             properties: [:]),
        tool("rune_save_command", "Add a saved command to the Commands card, or update the one with this name. Fields you leave out keep their value. A command with auto-start runs each time the repository opens in Rune. Updating a running command does not restart it.",
             properties: [
                "name": ["type": "string", "description": "Name of the command to add or update."],
                "command": ["type": "string", "description": "Shell command to run. Required for a new command."],
                "new_name": ["type": "string", "description": "A new name, to rename the command."],
                "directory": ["type": "string", "description": "Folder to run in, relative to the repository root. Defaults to the root."],
                "group": ["type": "string", "description": "Group to show the command in. An empty string removes it from its group."],
                "auto_start": ["type": "boolean", "description": "Run the command each time the repository opens in Rune."],
             ], required: ["name"]),
        tool("rune_delete_command", "Delete a saved command from the Commands card. A running command is stopped first.",
             properties: commandReference, required: ["name"]),
        tool("rune_run_command", "Run a saved command. Read its output with rune_read_terminal and the pane id this returns.",
             properties: commandReference, required: ["name"]),
        tool("rune_stop_command", "Stop a running saved command and the processes it started.",
             properties: commandReference, required: ["name"]),
        tool("rune_restart_command", "Stop a saved command if it runs, then run it again. Use it after you change the command or its config.",
             properties: commandReference, required: ["name"]),
        tool("rune_set_variable", "Set a variable on the space. Cards bound to the variable reload with the new value.",
             properties: [
                "name": ["type": "string", "description": "Variable name: letters, digits and underscores."],
                "value": ["type": "string"],
             ], required: ["name", "value"]),
    ] }

    private static var commandReference: [String: Any] { [
        "name": ["type": "string", "description": "The saved command's name or id, from rune_list_commands."],
        "group": ["type": "string", "description": "The command's group, if two commands share the name."],
    ] }

    private static func tool(_ name: String, _ description: String, properties: [String: Any],
                             required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    private static func call(params: [String: Any], socket: String?) -> [String: Any] {
        func reply(_ text: String, isError: Bool) -> [String: Any] {
            ["content": [["type": "text", "text": text]], "isError": isError]
        }
        guard let socket else { return reply("This agent is not running in a Rune terminal.", isError: true) }
        guard let name = params["name"] as? String else { return reply("The call has no tool name.", isError: true) }
        let request: [String: Any] = ["tool": name, "arguments": params["arguments"] ?? [String: Any]()]
        guard let body = try? JSONSerialization.data(withJSONObject: request) else {
            return reply("The arguments are not valid JSON.", isError: true)
        }
        guard let data = send(body + Data("\n".utf8), to: socket),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            return reply("Rune did not answer. It may have quit.", isError: true)
        }
        return reply(text, isError: object["isError"] as? Bool ?? false)
    }

    private static func send(_ body: Data, to path: String) -> Data? {
        guard var address = RuneControl.makeAddress(path) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        // rune_wait_for_output holds the reply for up to 50 seconds.
        var timeout = timeval(tv_sec: 70, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        RuneControl.writeAll(body, to: descriptor)
        return RuneControl.readMessage(from: descriptor)
    }
}
