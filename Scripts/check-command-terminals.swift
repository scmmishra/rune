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

@MainActor final class TestTerminalLayout: ObservableObject {
    @Published var value = TerminalLayout.slideovers
}

struct TestTerminalLayouts: View {
    @ObservedObject var sessions: TerminalSessions
    @ObservedObject var layout: TestTerminalLayout

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                if layout.value == .tabs {
                    TerminalTabBar(sessions: sessions, onSelect: sessions.select,
                                   onAdd: { _ = sessions.add() }, onClose: sessions.remove)
                }
                let visible = layout.value == .slideovers || sessions.active === sessions.primary
                PrimaryTerminalPane(session: sessions.primary, focusRequest: 0, isVisible: visible,
                                    isActive: sessions.active === sessions.primary,
                                    onActivate: { sessions.select(sessions.primary) }, onRestart: sessions.restartPrimary)
                    .opacity(visible ? 1 : 0)
            }
            ForEach(sessions.supporting) { session in
                let visible = sessions.active === session
                TerminalDrawer(session: session, isVisible: visible, isParked: false,
                               isTabbed: layout.value == .tabs, onClose: {},
                               onActivate: { sessions.select(session) })
                    .frame(width: layout.value == .tabs ? 640 : 400,
                           height: layout.value == .tabs ? 400 - TerminalTabBar.height : 368)
                    .padding(.top, layout.value == .tabs ? TerminalTabBar.height : 0)
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(visible)
            }
        }
    }
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
                let sessions = TerminalSessions(workingDirectory: root)
                let originalPrimary = sessions.primary
                let supporting = sessions.add()
                sessions.select(supporting)
                originalPrimary.terminal.onClose?(false)
                try await Task.sleep(for: .milliseconds(50))
                precondition(sessions.primary !== originalPrimary, "Main shell exit must respawn")
                precondition(sessions.primary.id == originalPrimary.id, "Respawn must preserve navigation identity")
                precondition(sessions.active === supporting, "Respawn must not select the main terminal")
                let replacement = sessions.primary
                replacement.terminal.onClose?(false)
                try await Task.sleep(for: .milliseconds(50))
                precondition(sessions.primary === replacement && replacement.hasExited,
                             "An immediately exiting replacement must wait for manual restart")
                sessions.restartPrimary()
                precondition(sessions.primary !== replacement && !sessions.primary.hasExited,
                             "Manual restart must recover from a rapid exit")
                supporting.terminal.onClose?(false)
                precondition(sessions.supporting.isEmpty, "Supporting terminals must still close normally")
                sessions.stopAll()

                let closingSessions = TerminalSessions(workingDirectory: root)
                let closingPrimary = closingSessions.primary
                closingPrimary.terminal.onClose?(false)
                closingSessions.stopAll()
                try await Task.sleep(for: .milliseconds(50))
                precondition(closingSessions.primary === closingPrimary, "Shutdown must cancel a queued respawn")
                print("Main terminal respawn, rapid-exit recovery, navigation, and shutdown checks passed")

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
                setenv("SHELL", "/bin/zsh", 1)
                let layoutSessions = TerminalSessions(workingDirectory: root)
                let layout = TestTerminalLayout()
                let secondary = layoutSessions.add()
                window.contentView = NSHostingView(rootView: TestTerminalLayouts(sessions: layoutSessions, layout: layout))
                window.orderBack(nil)
                try await Task.sleep(for: .seconds(1))
                let primaryView = layoutSessions.primary.terminal.attachedPlatformView!
                let secondaryView = secondary.terminal.attachedPlatformView!
                let primarySurface = layoutSessions.primary.terminal.surface!
                let secondarySurface = secondary.terminal.surface!
                let primaryPID = layoutSessions.primary.rootProcess!.pid
                let secondaryPID = secondary.rootProcess!.pid
                precondition(secondary.terminal.paste(text: "printf 'layout-output-marker\\n'"))
                precondition(secondary.terminal.sendKey(.enter))
                try await Task.sleep(for: .milliseconds(150))
                for mode in [TerminalLayout.tabs, .slideovers, .tabs] {
                    layoutSessions.select(secondary)
                    layout.value = mode
                    try await Task.sleep(for: .milliseconds(150))
                    precondition(layoutSessions.primary.terminal.attachedPlatformView === primaryView)
                    precondition(secondary.terminal.attachedPlatformView === secondaryView)
                    precondition(layoutSessions.primary.terminal.surface === primarySurface)
                    precondition(secondary.terminal.surface === secondarySurface)
                    precondition(layoutSessions.primary.rootProcess?.pid == primaryPID)
                    precondition(secondary.rootProcess?.pid == secondaryPID, "Layout switches must not restart shells")
                    precondition(layoutSessions.primary.terminal.isSurfaceVisible == (mode == .slideovers))
                    precondition(secondary.terminal.isSurfaceVisible)
                }
                precondition(secondarySurface.performBindingAction("select_all"))
                precondition(secondarySurface.readSelection()?.contains("layout-output-marker") == true,
                             "Terminal output must survive layout switches")
                layoutSessions.select(layoutSessions.primary)
                try await Task.sleep(for: .milliseconds(150))
                precondition(layoutSessions.primary.terminal.isSurfaceVisible && !secondary.terminal.isSurfaceVisible)
                layoutSessions.stopAll()
                window.orderOut(nil)
                print("Terminal layouts passed: stable views, surfaces, processes, output, and hidden-tab visibility")
                print("Ghostty command integration checks passed: exit status, retained output, typography, stop, and shutdown.")
                exit(0)
            } catch { print(error); exit(1) }
        }
        app.run()
    }
}
