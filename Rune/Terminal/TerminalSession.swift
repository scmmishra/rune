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
    private var attentionObservations: Set<AnyCancellable> = []
    /// Something asked for you here while you were elsewhere: an agent finished or wants
    /// an answer, a build ended. Cleared the moment you visit this terminal.
    @Published private(set) var needsAttention = false
    /// Bumped with each new request, so a tab can nudge again for a second one.
    @Published private(set) var attentionCount = 0
    let savedCommandID: UUID?
    private let startDirectory: URL?
    /// Where the shell is now (OSC 7), falling back to where it started. Relative paths
    /// printed by a build or test run resolve against this.
    var currentDirectory: URL? {
        terminal.workingDirectory.map { URL(fileURLWithPath: $0) } ?? startDirectory
    }
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
    /// Ports, memory and CPU, sampled only while the terminal's header is on screen.
    /// A separate object so its once-a-second updates redraw the readout alone.
    let resources = TerminalResourceMeter()
    /// The foreground process of every shell session.
    @Published var foreground: TerminalProcessStatus?
    var onExit: (() -> Void)?
    /// A ⌘-clicked link in this terminal, routed by the workspace.
    var onOpenURL: ((String) -> Void)?

    private static let runtimes: Set<String> = ["node", "bun", "deno", "python", "python3"]

    var name: String {
        if let customName { return customName }
        if let processStatus {
            if processStatus.isIdle { return processStatus.name }
            return TerminalAgent.detect(in: processStatus.name)?.rawValue
                ?? (Self.runtimes.contains(processStatus.name) ? detectedAgent?.rawValue : nil) ?? processStatus.name
        }
        return detectedAgent?.rawValue ?? defaultName
    }

    /// The coding agent running in the foreground, if any.
    var agent: TerminalAgent? {
        guard let foreground else { return detectedAgent }
        if foreground.isIdle { return nil }
        return TerminalAgent.detect(in: foreground.name)
            ?? (Self.runtimes.contains(foreground.name) ? detectedAgent : nil)
    }

    /// The mark and tile colors for what runs in the foreground.
    var processTile: TerminalProcessTile {
        if let agent { return .agent(agent) }
        return foreground?.tile ?? .shell
    }
    @Published private(set) var hasExited = false
    @Published var needsCloseConfirmation = false

    /// A shell at its prompt, or one that has exited, has nothing to lose, so closing it
    /// needs no confirmation. Before the first process sample this is false, to be safe.
    var closesWithoutConfirmation: Bool { hasExited || foreground?.isIdle == true }

    /// - Parameter startCommand: Run in the shell before its first prompt, such as an agent
    ///   resuming a thread. The shell stays when it exits.
    init(name: String, workingDirectory: URL?, detectsAgent: Bool = true,
         savedCommandID: UUID? = nil, execution: CommandExecution? = nil, startCommand: String? = nil) {
        id = UUID()
        self.defaultName = name
        self.savedCommandID = savedCommandID
        self.startDirectory = workingDirectory
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
            theme: RuneTheme.current.terminalTheme,
            terminalConfiguration: TerminalConfiguration { builder in
                builder.withWindowPaddingX(12)
                builder.withWindowPaddingY(10)
            }
        )
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: workingDirectory?.path,
            command: processGuardian?.launchCommand(execution?.launchCommand ?? Self.shellCommand(running: startCommand), shellIntegration: execution == nil),
            waitAfterCommand: execution == nil ? nil : true
        )
        self.terminal = terminal
        terminal.makePlatformView = { [weak self] in
            let view = RuneTerminalView(frame: .zero)
            if self?.processGuardian == nil || self?.preventsLaunch != false { view.stop() }
            view.onOpenURL = { [weak self] url in self?.onOpenURL?(url) }
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
        // zsh rings the bell for tab completion, so a terminal you are typing in never
        // asks for attention: you are already looking at it.
        terminal.$bellCount
            .dropFirst()
            .sink { [weak self] _ in self?.requestAttention() }
            .store(in: &attentionObservations)
        terminal.$isFocused
            .filter { $0 }
            .sink { [weak self] _ in self?.clearAttention() }
            .store(in: &attentionObservations)
        // Clicking straight into the surface counts as visiting it.
        terminal.$isFocused
            .filter { $0 }
            .sink { [weak self] _ in self?.clearAttention() }
            .store(in: &attentionObservations)
        terminal.$lastDesktopNotificationAt
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] _ in self?.requestAttention() }
            .store(in: &attentionObservations)

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

    /// The login shell, or one that runs `startCommand` first and then becomes the login
    /// shell. Interactive, so the command sees the same PATH a typed one would.
    private static func shellCommand(running startCommand: String?) -> String {
        let shell = CommandExecution.quote(ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        guard let startCommand else { return "\(shell) -l" }
        return "\(shell) -l -i -c \(CommandExecution.quote("\(startCommand); exec \(shell) -l"))"
    }

    /// Marks the session as waiting, unless it has the keyboard. Also called for an agent's
    /// `rune_notify`.
    func requestAttention() {
        guard !terminal.isFocused else { return }
        needsAttention = true
        attentionCount &+= 1
    }

    /// Visiting the terminal is the acknowledgement.
    func clearAttention() {
        guard needsAttention else { return }
        needsAttention = false
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
    @Published private(set) var all: [TerminalSession]
    /// Navigation tracks tabs and saved commands, never single panes: a tab is known by
    /// its own ID and a command by its session's.
    @Published private(set) var navigation: TerminalNavigation
    /// Tabs in the order they were opened. There is always at least one.
    @Published private(set) var tabs: [TerminalTab]
    private let workingDirectory: URL?
    private var nextNumber = 2
    private var commandObservations: [UUID: AnyCancellable] = [:]
    /// A tab shows that any of its panes is waiting, so the tab row has to hear about panes
    /// it is not otherwise watching.
    private var attentionObservations: [UUID: AnyCancellable] = [:]
    private var isShuttingDown = false
    private var lastReplacedAt: ContinuousClock.Instant?
    /// A window's only terminal has to outlive this for its exit to start a fresh one.
    private static let minimumReplacementLifetime: Duration = .seconds(5)

    /// Where the keyboard is: the focused pane of a tab, or a saved command beside the panel.
    var active: TerminalSession { shown(for: navigation.activeID) ?? panel }
    /// The tab filling the terminal panel.
    var panelTab: TerminalTab { tabs.first { $0.id == navigation.panelID } ?? tabs[0] }
    /// The focused pane of the tab filling the terminal panel.
    var panel: TerminalSession { session(panelTab.focusedID) ?? all[0] }
    /// Sessions open beside the panel, in column order. A peeked tab shows its focused pane.
    var peeked: [TerminalSession] { navigation.peekedIDs.compactMap(shown) }
    /// Once any tab is split, the tab row and every pane are cards of their own.
    var isSplit: Bool { tabs.contains(where: \.isSplit) }

    func session(_ id: UUID) -> TerminalSession? { all.first { $0.id == id } }
    func tab(containing session: TerminalSession) -> TerminalTab? { tabs.first { $0.contains(session.id) } }
    func isPeeked(_ session: TerminalSession) -> Bool {
        navigation.isPeeked(navigationID(for: session)) && shown(for: navigationID(for: session)) === session
    }

    /// The tab a pane belongs to, or the session itself for a saved command.
    private func navigationID(for session: TerminalSession) -> UUID { tab(containing: session)?.id ?? session.id }

    /// The session a navigation ID puts on screen.
    private func shown(for navigationID: UUID) -> TerminalSession? {
        session(tabs.first { $0.id == navigationID }?.focusedID ?? navigationID)
    }

    /// Whether a session is the window's last terminal, which a fresh one replaces.
    func isOnlyTerminal(_ session: TerminalSession) -> Bool {
        tabs.count == 1 && tabs[0].paneIDs == [session.id]
    }

    /// The next tab when cycling.
    func cycleTarget(in direction: Int) -> TerminalSession? {
        session(forNavigation: navigation.neighbor(in: direction))
    }

    /// The number ⌘-number reaches a session's tab by, which follows the tab row.
    func tabNumber(of session: TerminalSession) -> Int? {
        tabs.firstIndex { $0.contains(session.id) }.map { $0 + 1 }.flatMap { $0 <= 9 ? $0 : nil }
    }

    /// The session ⌘-number and the tab at `index` stand for.
    func tabSession(at index: Int) -> TerminalSession? {
        tabs.indices.contains(index) ? session(tabs[index].focusedID) : nil
    }

    /// The session a navigation target resolves to, such as the next tab when cycling.
    func session(forNavigation id: UUID) -> TerminalSession? { shown(for: id) }

    private func updateTab(containing session: TerminalSession, _ change: (inout TerminalTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.contains(session.id) }) else { return }
        change(&tabs[index])
    }
    /// A peek column past this many slots leaves each terminal too short to read.
    static let peekLimit = 3

    /// Where a ⌘-clicked link goes. Applied to every session, new ones included.
    var onOpenLink: ((TerminalLink) -> Void)? {
        didSet { all.forEach(routeLinks) }
    }

    /// The pane of a tab that is waiting for you, if any.
    func waitingPane(in tab: TerminalTab) -> TerminalSession? {
        tab.paneIDs.lazy.compactMap { self.session($0) }.first(where: \.needsAttention)
    }

    private func observeAttention(_ session: TerminalSession) {
        attentionObservations[session.id] = session.$needsAttention
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private func routeLinks(_ session: TerminalSession) {
        session.onOpenURL = { [weak self, weak session] raw in
            guard let self, let session,
                  let link = TerminalLink.parse(raw, relativeTo: session.currentDirectory) else { return }
            self.onOpenLink?(link)
        }
    }

    func peek(_ session: TerminalSession) {
        session.clearAttention()
        navigation.peek(navigationID(for: session), limit: Self.peekLimit)
    }

    func closePeek(_ session: TerminalSession) { navigation.closePeek(navigationID(for: session)) }

    /// Splits the focused pane of the panel's tab. The new shell starts in the project
    /// root and takes the focus.
    func split(_ axis: TerminalSplitAxis) -> TerminalSession {
        let tabID = panelTab.id
        let session = makeShell()
        all.append(session)
        if let index = tabs.firstIndex(where: { $0.id == tabID }) { tabs[index].split(axis, adding: session.id) }
        // A split made while the keyboard is in a peek still lands in the panel.
        navigation.select(tabID)
        return session
    }

    /// Moves a tab along the tab row.
    func moveTab(_ tabID: UUID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == tabID }), tabs.indices.contains(index) else { return }
        tabs.insert(tabs.remove(at: from), at: index)
        navigation.orderTabs(tabs.map(\.id))
    }

    func toggleZoom() { updatePanelTab { $0.toggleZoom() } }
    func resizePane(dx: Int, dy: Int) { updatePanelTab { $0.resize(dx: dx, dy: dy) } }
    func equalizePanes() { updatePanelTab { $0.equalize() } }
    func setRatio(_ ratio: CGFloat, of dividerID: TerminalSplitDivider.ID) { updatePanelTab { $0.setRatio(ratio, of: dividerID) } }
    func movePane(_ paneID: UUID, to drop: TerminalPaneDrop) { updatePanelTab { $0.move(paneID, to: drop) } }

    /// Moves the focus to the pane beside the focused one, if there is one that way.
    func focusPane(dx: Int, dy: Int) {
        guard navigation.activeID == panelTab.id, let id = panelTab.neighbor(dx: dx, dy: dy),
              let session = session(id) else { return }
        select(session)
    }

    private func updatePanelTab(_ change: (inout TerminalTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == navigation.panelID }) else { return }
        change(&tabs[index])
    }

    init(workingDirectory: URL?) {
        self.workingDirectory = workingDirectory
        let first = TerminalSession(name: "Terminal 1", workingDirectory: workingDirectory)
        all = [first]
        navigation = TerminalNavigation(firstID: first.id)
        tabs = [TerminalTab(id: first.id, paneID: first.id)]
        watch(first)
    }

    private func watch(_ session: TerminalSession) {
        session.onExit = { [weak self, weak session] in
            guard let self, let session else { return }
            guard self.isOnlyTerminal(session) else {
                self.remove(session)
                return
            }
            // Leave Ghostty's close callback before replacing its native surface.
            Task { @MainActor [weak self, weak session] in
                guard let self, let session, !self.isShuttingDown else { return }
                // A shell that fails at startup would be replaced forever. It stays on
                // screen instead, with its Restart button.
                if let lastReplacedAt = self.lastReplacedAt,
                   lastReplacedAt.duration(to: .now) < Self.minimumReplacementLifetime { return }
                self.remove(session)
            }
        }
        routeLinks(session)
        observeAttention(session)
    }

    /// The tab running each agent thread, by the thread's key.
    private var threadSessions: [String: UUID] = [:]

    /// The tab of the thread for `key`: the one already open in this window, or a new one
    /// running `command`.
    func thread(key: String, name: String?, command: () -> String) -> TerminalSession {
        if let id = threadSessions[key], let session = session(id) { return session }
        // Asked for only now: building the command records a new thread's ID.
        let session = add(startCommand: command())
        session.customName = name
        threadSessions[key] = session.id
        return session
    }

    /// Opens a shell beside `session` for an agent in it: a split of its pane, or a tab of
    /// its own when `axis` is nil. `session` keeps the focus, so the agent's user keeps typing.
    func open(beside session: TerminalSession, axis: TerminalSplitAxis?, startCommand: String?) -> TerminalSession {
        guard let axis, let index = tabs.firstIndex(where: { $0.contains(session.id) }) else {
            return add(startCommand: startCommand)
        }
        let added = makeShell(startCommand: startCommand)
        all.append(added)
        tabs[index].focus(session.id)
        tabs[index].split(axis, adding: added.id)
        tabs[index].focus(session.id)
        return added
    }

    /// Opens a shell in a tab of its own.
    func add(startCommand: String? = nil) -> TerminalSession {
        let session = makeShell(startCommand: startCommand)
        navigation.add(session.id)
        tabs.append(TerminalTab(id: session.id, paneID: session.id))
        all.append(session)
        return session
    }

    private func makeShell(startCommand: String? = nil) -> TerminalSession {
        let session = TerminalSession(name: "Terminal \(nextNumber)", workingDirectory: workingDirectory,
                                      startCommand: startCommand)
        nextNumber += 1
        watch(session)
        return session
    }

    func add(command: ProjectCommand, directory: URL, execution: CommandExecution) -> TerminalSession {
        let session = TerminalSession(name: command.name, workingDirectory: directory, detectsAgent: false,
                                      savedCommandID: command.id, execution: execution)
        commandObservations[session.id] = session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        navigation.add(session.id)
        routeLinks(session)
        all.append(session)
        return session
    }

    /// Brings a session's tab into the panel and gives the session the keyboard.
    func select(_ session: TerminalSession) {
        session.clearAttention()
        updateTab(containing: session) { $0.focus(session.id) }
        navigation.select(navigationID(for: session))
    }

    func remove(_ session: TerminalSession) {
        session.stop()
        guard !isShuttingDown else { return }
        commandObservations.removeValue(forKey: session.id)
        attentionObservations.removeValue(forKey: session.id)
        threadSessions = threadSessions.filter { $0.value != session.id }
        if let index = tabs.firstIndex(where: { $0.contains(session.id) }) {
            // A tab's last pane takes the tab with it; any other gives its room to a sibling.
            if !tabs[index].close(session.id) {
                if tabs.count == 1 { replaceLastTab() }
                navigation.remove(tabs[index].id)
                tabs.remove(at: index)
            }
        } else {
            navigation.remove(session.id)
        }
        all.removeAll { $0.id == session.id }
    }

    /// A window always has a terminal, so a fresh one takes over from the last tab.
    private func replaceLastTab() {
        nextNumber = 1
        lastReplacedAt = .now
        navigation.select(add().id)
    }

    func terminate(_ session: TerminalSession) async {
        if await session.stopCommand() {
            // Explicit closing always removes the session, even during the cooldown
            // that keeps a failing last shell on screen.
            remove(session)
        }
    }

    /// Closes every pane of a session's tab.
    func terminateTab(containing session: TerminalSession) async {
        let panes = tab(containing: session)?.paneIDs.compactMap { self.session($0) } ?? [session]
        for pane in panes { await terminate(pane) }
    }

    func monitorProcesses() async {
        while !Task.isCancelled {
            let shells = all.filter { $0.execution == nil }
            let roots = Dictionary(uniqueKeysWithValues: shells.compactMap { session in
                session.rootProcess.map { (session.id, $0) }
            })
            let statuses = await Task.detached(priority: .utility) {
                TerminalProcessMonitor.snapshot(roots: roots)
            }.value
            guard !Task.isCancelled else { return }
            for session in shells where session.foreground != statuses[session.id] {
                session.foreground = statuses[session.id]
            }
            for session in all {
                await session.refreshCommand()
                if session.execution != nil { continue }
                let status = statuses[session.id]
                if session.processStatus != status { session.processStatus = status }
            }
            await sampleResources()
            do { try await Task.sleep(for: .milliseconds(all.contains { $0.isCommandRunning } ? 250 : 1000)) } catch { return }
        }
    }

    private var lastResourceSample: ContinuousClock.Instant?

    /// At most once a second, however fast the process loop runs.
    private func sampleResources() async {
        let now = ContinuousClock.now
        if let lastResourceSample, now - lastResourceSample < .seconds(1) { return }
        lastResourceSample = now
        // Only terminals whose header is on screen: peeks, and the panes of a split layout.
        let tab = panelTab
        let shown = Set(peeked.map(\.id)).union(isSplit ? tab.paneIDs.filter(tab.shows) : [])
        for session in all where !shown.contains(session.id) { session.resources.reset() }
        let roots = all.filter { shown.contains($0.id) && !$0.hasExited }
            .compactMap { session in session.rootProcess.map { (session, $0) } }
        guard !roots.isEmpty else { return }
        let targets = roots.map(\.1)
        let samples = await Task.detached(priority: .utility) {
            targets.map(TerminalProcessMonitor.resources)
        }.value
        guard !Task.isCancelled else { return }
        for ((session, _), sample) in zip(roots, samples) { session.resources.record(sample, at: now) }
    }

    func stopAll() {
        isShuttingDown = true
        all.forEach {
            $0.onExit = nil
            $0.stop()
        }
    }
}
