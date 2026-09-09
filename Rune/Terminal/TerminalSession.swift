import Foundation
import Combine
import GhosttyTerminal

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id: UUID
    let terminal: TerminalViewState
    private let defaultName: String
    @Published var customName: String?
    @Published private var detectedAgent: TerminalAgent?
    private var titleObservation: AnyCancellable?
    let savedCommandID: UUID?
    let execution: CommandExecution?
    private let processGuardian: TerminalProcessGuardian?
    let launchError: String?
    private var preventsLaunch = false
    var rootProcess: TerminalProcessMonitor.TerminationTarget? { processGuardian?.root }
    @Published private(set) var isStopping = false
    @Published private(set) var cleanupFailed = false
    @Published private(set) var wasStopped = false
    @Published private(set) var exitCode: Int?

    var isCommandRunning: Bool { execution != nil && !hasExited }
    var commandStatus: String {
        if isStopping { return "Stopping…" }
        if cleanupFailed { return "Cleanup failed" }
        if wasStopped { return "Stopped" }
        if let exitCode { return exitCode == 0 ? "Finished" : "Failed (\(exitCode))" }
        return hasExited ? "Exited" : "Running"
    }

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

    init(name: String, workingDirectory: URL?, detectsAgent: Bool = true,
         savedCommandID: UUID? = nil, execution: CommandExecution? = nil, id: UUID = UUID()) {
        self.id = id
        self.defaultName = name
        self.savedCommandID = savedCommandID
        self.execution = execution
        if savedCommandID != nil { customName = name }
        do {
            processGuardian = try TerminalProcessGuardian()
            launchError = nil
        } catch {
            processGuardian = nil
            launchError = "Could not start terminal cleanup protection: \(error.localizedDescription)"
            hasExited = true
        }
        let terminal = TerminalViewState(
            theme: TerminalTheme(
                light: TerminalConfiguration(startingFrom: .alabaster) { builder in
                    builder.withBackground(TerminalSurface.lightHex)
                },
                dark: TerminalConfiguration(startingFrom: .afterglow) { builder in
                    builder.withBackground(TerminalSurface.darkHex)
                }
            ),
            terminalConfiguration: TerminalConfiguration { builder in
                builder.withWindowPaddingX(12)
                builder.withWindowPaddingY(10)
            }
        )
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: workingDirectory?.path,
            command: processGuardian?.launchCommand(execution?.launchCommand ?? "\(CommandExecution.quote(ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")) -l", shellIntegration: execution == nil),
            waitAfterCommand: execution == nil ? nil : true
        )
        self.terminal = terminal
        terminal.makePlatformView = { [weak self] in
            let view = RuneTerminalView(frame: .zero)
            if self?.processGuardian == nil || self?.preventsLaunch != false { view.stop() }
            return view
        }
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
            // A keypress after wait-after-command requests a close. Keep saved
            // command output mounted until the user explicitly runs it again.
            if self.execution != nil {
                if !processAlive {
                    Task { await self.finishCommand(exitCode: self.execution?.snapshot().exitCode) }
                }
                return
            }
            if processAlive {
                self.needsCloseConfirmation = true
            } else {
                self.processGuardian?.requestStop()
                self.hasExited = true
                self.onExit?()
            }
        }
    }

    func stop() {
        preventsLaunch = true
        processGuardian?.requestStop()
        (terminal.attachedPlatformView as? RuneTerminalView)?.stop()
    }

    func refreshCommand() async {
        guard let processGuardian, !hasExited, !isStopping else { return }
        let code = await Task.detached { processGuardian.exitCode }.value
        guard !isStopping, !hasExited, let code else { return }
        await finishCommand(exitCode: code)
        if execution == nil, hasExited { onExit?() }
    }

    private func finishCommand(exitCode: Int?) async {
        guard !hasExited, !isStopping else { return }
        self.exitCode = exitCode
        _ = await stopCommand(markStopped: false)
    }

    func stopCommand(markStopped: Bool = true) async -> Bool {
        guard let processGuardian, !isStopping else { return false }
        guard !hasExited else { return true }
        isStopping = true
        cleanupFailed = false
        preventsLaunch = true
        defer { isStopping = false }
        // Cancel a not-yet-mounted surface without discarding existing output.
        if terminal.surface == nil { (terminal.attachedPlatformView as? RuneTerminalView)?.stop() }
        let cleaned = await Task.detached { processGuardian.waitForCleanup() }.value
        guard cleaned else { cleanupFailed = true; return false }
        wasStopped = markStopped
        hasExited = true
        return true
    }

}

@MainActor
final class TerminalSessions: ObservableObject {
    @Published private(set) var primary: TerminalSession
    @Published private(set) var supporting: [TerminalSession] = []
    @Published private(set) var navigation: TerminalNavigation
    private let workingDirectory: URL?
    private var nextNumber = 1
    private var commandObservations: [UUID: AnyCancellable] = [:]
    private var isShuttingDown = false
    private var primaryRestartedAt: ContinuousClock.Instant?
    private static let minimumPrimaryLifetime: Duration = .seconds(5)

    var all: [TerminalSession] { [primary] + supporting }
    var active: TerminalSession { all.first { $0.id == navigation.activeID } ?? primary }

    init(workingDirectory: URL?) {
        self.workingDirectory = workingDirectory
        let primary = TerminalSession(name: "Main Terminal", workingDirectory: workingDirectory, detectsAgent: false)
        self.primary = primary
        navigation = TerminalNavigation(primaryID: primary.id)
        observePrimaryExit()
    }

    private func observePrimaryExit() {
        primary.onExit = { [weak self, weak session = primary] in
            // Leave Ghostty's close callback before replacing its native surface.
            Task { @MainActor [weak self, weak session] in
                guard let self, let session, self.primary === session, !self.isShuttingDown else { return }
                if let restartedAt = self.primaryRestartedAt,
                   restartedAt.duration(to: .now) < Self.minimumPrimaryLifetime { return }
                self.restartPrimary()
            }
        }
    }

    func restartPrimary() {
        guard !isShuttingDown, primary.hasExited else { return }
        let id = primary.id
        let customName = primary.customName
        primary.onExit = nil
        primary.stop()
        primaryRestartedAt = .now
        // Keep shortcuts and parked-terminal navigation stable across shell lifetimes.
        primary = TerminalSession(name: "Main Terminal", workingDirectory: workingDirectory,
                                  detectsAgent: false, id: id)
        primary.customName = customName
        observePrimaryExit()
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

    func add(command: ProjectCommand, directory: URL, execution: CommandExecution) -> TerminalSession {
        let session = TerminalSession(name: command.name, workingDirectory: directory, detectsAgent: false,
                                      savedCommandID: command.id, execution: execution)
        commandObservations[session.id] = session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
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
        commandObservations.removeValue(forKey: session.id)
        navigation.remove(session.id)
        supporting.removeAll { $0.id == session.id }
    }

    func terminate(_ session: TerminalSession) async {
        if await session.stopCommand() {
            // Explicit closing always replaces the main shell, even during the
            // automatic respawn cooldown used for failing shell startup.
            if session === primary { restartPrimary() } else { remove(session) }
        }
    }

    func monitorProcesses() async {
        while !Task.isCancelled {
            let roots = Dictionary(uniqueKeysWithValues: supporting.compactMap { session in
                session.rootProcess.map { (session.id, $0) }
            })
            let statuses = await Task.detached(priority: .utility) {
                TerminalProcessMonitor.snapshot(roots: roots)
            }.value
            guard !Task.isCancelled else { return }
            await primary.refreshCommand()
            for session in supporting {
                await session.refreshCommand()
                if session.execution != nil { continue }
                let status = statuses[session.id]
                if session.processStatus != status { session.processStatus = status }
            }
            do { try await Task.sleep(for: .milliseconds(supporting.contains { $0.isCommandRunning } ? 250 : 1000)) } catch { return }
        }
    }

    func stopAll() {
        isShuttingDown = true
        primary.onExit = nil
        primary.stop()
        supporting.forEach { $0.stop() }
    }
}
