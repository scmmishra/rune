import Foundation
import Combine
import GhosttyTerminal

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let terminal: TerminalViewState
    private let defaultName: String
    @Published var customName: String?
    @Published private var detectedAgent: TerminalAgent?
    private var titleObservation: AnyCancellable?

    @Published var processStatus: TerminalProcessStatus?
    var onExit: (() -> Void)?

    var name: String {
        if let customName { return customName }
        if let processStatus {
            if processStatus.isIdle { return processStatus.name }
            let runtime = ["node", "bun", "deno", "python", "python3"].contains(processStatus.name)
            return TerminalAgent.detect(in: processStatus.name)?.rawValue
                ?? (runtime ? detectedAgent?.rawValue : nil) ?? processStatus.name
        }
        return detectedAgent?.rawValue ?? defaultName
    }
    @Published private(set) var hasExited = false
    @Published var needsCloseConfirmation = false

    init(name: String, workingDirectory: URL?, detectsAgent: Bool = true) {
        self.defaultName = name
        let terminal = TerminalViewState(
            theme: TerminalTheme(
                light: TerminalConfiguration(startingFrom: .alabaster) { builder in
                    builder.withBackground("EFEFEF")
                },
                dark: TerminalConfiguration(startingFrom: .afterglow) { builder in
                    builder.withBackground("181818")
                }
            ),
            terminalConfiguration: TerminalConfiguration { builder in
                builder.withWindowPaddingX(12)
                builder.withWindowPaddingY(10)
            }
        )
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            fontSize: 12,
            workingDirectory: workingDirectory?.path
        )
        terminal.makePlatformView = {
            RuneTerminalView(frame: .zero)
        }
        self.terminal = terminal
        if detectsAgent {
            // Subscribe to Ghostty's published title instead of polling processes.
            // A new unknown title clears stale detection; a manual name takes priority.
            titleObservation = terminal.$title
                .map { TerminalAgent.detect(in: $0) }
                .removeDuplicates()
                .sink { [weak self] in self?.detectedAgent = $0 }
        }
        terminal.onClose = { [weak self] processAlive in
            guard let self else { return }
            if processAlive {
                self.needsCloseConfirmation = true
            } else {
                self.hasExited = true
                self.onExit?()
            }
        }
    }

    func stop() {
        (terminal.attachedPlatformView as? RuneTerminalView)?.stop()
    }
}

@MainActor
final class TerminalSessions: ObservableObject {
    let primary: TerminalSession
    @Published private(set) var supporting: [TerminalSession] = []
    @Published private(set) var navigation: TerminalNavigation
    private let workingDirectory: URL?
    private var nextNumber = 1

    var all: [TerminalSession] { [primary] + supporting }
    var active: TerminalSession { all.first { $0.id == navigation.activeID } ?? primary }

    init(workingDirectory: URL?) {
        self.workingDirectory = workingDirectory
        let primary = TerminalSession(name: "Main Terminal", workingDirectory: workingDirectory, detectsAgent: false)
        self.primary = primary
        navigation = TerminalNavigation(primaryID: primary.id)
    }

    func add() -> TerminalSession {
        let session = TerminalSession(name: "Terminal \(nextNumber)", workingDirectory: workingDirectory)
        nextNumber += 1
        session.onExit = { [weak self, weak session] in
            guard let self, let session else { return }
            self.remove(session)
        }
        navigation.add(session.id)
        supporting.append(session)
        return session
    }

    func select(_ session: TerminalSession) {
        navigation.select(session.id)
    }

    func remove(_ session: TerminalSession) {
        guard session.id != primary.id else { return }
        session.stop()
        navigation.remove(session.id)
        supporting.removeAll { $0.id == session.id }
    }

    func terminate(_ session: TerminalSession) async {
        let root = (session.terminal.attachedPlatformView as? RuneTerminalView)?.rootProcess
        let targets = await Task.detached(priority: .userInitiated) {
            TerminalProcessMonitor.beginTermination(root: root)
        }.value
        remove(session)
        // A closing pane must not cancel escalation for a process ignoring TERM.
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1))
            TerminalProcessMonitor.forceTermination(targets)
        }
    }

    func monitorProcesses() async {
        while !Task.isCancelled {
            let roots = Dictionary(uniqueKeysWithValues: supporting.compactMap { session in
                (session.terminal.attachedPlatformView as? RuneTerminalView)?.rootProcess.map { (session.id, $0) }
            })
            let statuses = await Task.detached(priority: .utility) {
                TerminalProcessMonitor.snapshot(roots: roots)
            }.value
            guard !Task.isCancelled else { return }
            for session in supporting {
                let status = statuses[session.id]
                if session.processStatus != status { session.processStatus = status }
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    func stopAll() {
        primary.stop()
        supporting.forEach { $0.stop() }
    }
}
