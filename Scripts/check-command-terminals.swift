import AppKit
import SwiftUI
import GhosttyTerminal

@MainActor final class TestTypography: ObservableObject {
    @Published var value = RuneTypography(family: RuneTypography.defaultFamily, baseSize: 18)
}
struct TestPane: View {
    let terminal: TerminalViewState
    @ObservedObject var typography: TestTypography
    var body: some View { TerminalPane(terminal: terminal).environment(\.runeTypography, typography.value) }
}

@main
struct CommandTerminalChecks {
    @MainActor static func main() {
        if TerminalProcessGuardian.runIfRequested() { return }
        TerminalDebugLog.isEnabled = ProcessInfo.processInfo.environment["RUNE_TEST_DEBUG"] == "1"
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
                let typography = TestTypography()
                let execution = try CommandExecution(command: "printf 'Rune saved command output\\n'; sleep 1; exit 7", shell: "/bin/zsh")
                let session = TerminalSession(name: "Test", workingDirectory: root, detectsAgent: false, savedCommandID: UUID(), execution: execution)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = NSHostingView(rootView: TestPane(terminal: session.terminal, typography: typography))
                window.orderBack(nil)
                for _ in 0..<100 {
                    await session.refreshCommand()
                    if session.hasExited { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                print("Ghostty exit status: \(session.commandStatus), code: \(String(describing: session.exitCode)), surface retained: \(session.terminal.surface != nil)")
                fflush(nil)
                precondition(session.exitCode == 7)
                precondition(session.terminal.surface != nil)
                let finishedSurface = session.terminal.surface
                typography.value = RuneTypography(family: RuneTypography.defaultFamily, baseSize: 22)
                try await Task.sleep(for: .milliseconds(250))
                precondition(session.terminal.surface === finishedSurface, "Font changes must retain output and not rerun commands")
                session.stop()
                window.orderOut(nil)

                let longExecution = try CommandExecution(command: "trap '' TERM; while :; do sleep 1; done", shell: "/bin/zsh")
                let longSession = TerminalSession(name: "Stop", workingDirectory: root, detectsAgent: false, savedCommandID: UUID(), execution: longExecution)
                window.contentView = NSHostingView(rootView: TestPane(terminal: longSession.terminal, typography: typography))
                window.orderBack(nil)
                try await Task.sleep(for: .seconds(1))
                let runningSurface = longSession.terminal.surface
                let beforeRoot = longExecution.snapshot().root
                typography.value = RuneTypography(family: RuneTypography.defaultFamily, baseSize: 16)
                try await Task.sleep(for: .milliseconds(250))
                precondition(longSession.terminal.surface === runningSurface)
                precondition(longExecution.snapshot().root?.pid == beforeRoot?.pid)
                let stopped = await longSession.stopCommand()
                print("Ghostty stop: \(stopped), output retained: \(longSession.terminal.surface != nil)")
                fflush(nil)
                precondition(stopped && longSession.wasStopped && longSession.terminal.surface != nil)
                longSession.stop()
                window.orderOut(nil)
                let closingExecution = try CommandExecution(command: "trap '' HUP TERM; while :; do sleep 1; done", shell: "/bin/zsh")
                let closingSession = TerminalSession(name: "Close", workingDirectory: root, detectsAgent: false, savedCommandID: UUID(), execution: closingExecution)
                window.contentView = NSHostingView(rootView: TestPane(terminal: closingSession.terminal, typography: typography))
                window.orderBack(nil)
                try await Task.sleep(for: .seconds(1))
                let closingRoot = closingExecution.snapshot().root!
                closingSession.stop()
                window.orderOut(nil)
                try await Task.sleep(for: .milliseconds(1200))
                precondition(!TerminalProcessMonitor.isAlive(closingRoot))
                for shell in ["/bin/zsh", "/bin/bash"] {
                    setenv("SHELL", shell, 1)
                    let interactive = TerminalSession(name: "Interactive", workingDirectory: root)
                    window.contentView = NSHostingView(rootView: TestPane(terminal: interactive.terminal, typography: typography))
                    window.orderBack(nil)
                    try await Task.sleep(for: .seconds(1))
                    let originalSurface = interactive.terminal.surface
                    let originalProcess = interactive.rootProcess?.pid
                    let initialSize = interactive.terminal.surfaceSize!
                    precondition(interactive.terminal.sendKey(.digit0, modifiers: .super_))
                    try await Task.sleep(for: .milliseconds(250))
                    let resetSize = interactive.terminal.surfaceSize!
                    precondition(initialSize.cellWidthPixels == resetSize.cellWidthPixels
                                 && initialSize.cellHeightPixels == resetSize.cellHeightPixels,
                                 "Command-0 must preserve the initial saved font size")
                    precondition(interactive.terminal.surface === originalSurface)
                    precondition(interactive.rootProcess?.pid == originalProcess)
                    let marker = root.appendingPathComponent("rune-shell-" + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: marker) }
                    precondition(interactive.terminal.paste(text: "cd /; printf ok > " + CommandExecution.quote(marker.path)))
                    precondition(interactive.terminal.sendKey(.enter))
                    for _ in 0..<50 {
                        if FileManager.default.fileExists(atPath: marker.path),
                           shell == "/bin/bash" || interactive.terminal.workingDirectory == "/" { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    print("Interactive \(shell): working directory \(String(describing: interactive.terminal.workingDirectory))")
                    fflush(nil)
                    precondition(FileManager.default.fileExists(atPath: marker.path), "Interactive shell must execute input")
                    if shell != "/bin/bash" {
                        precondition(interactive.terminal.workingDirectory == "/", "Shell integration must report directory changes")
                    }
                    let closed = await interactive.stopCommand()
                    precondition(closed)
                    interactive.stop()
                    window.orderOut(nil)
                }
                print("Ghostty command integration checks passed: exit status, retained output, typography, stop, and shutdown.")
                exit(0)
            } catch { print(error); exit(1) }
        }
        app.run()
    }
}
