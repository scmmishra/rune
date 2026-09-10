import AppKit
import SwiftUI

struct WorkspaceView: View {
    let directoryURL: URL?
    let onOpenProject: () -> Void
    let onOpenWorkspace: (WorkspaceIdentity) -> Void
    @StateObject private var terminals: TerminalSessions
    @StateObject private var projectCommands: ProjectCommands
    @StateObject private var repository: GitSidebarModel
    @StateObject private var guide: ChangeGuideModel

    init(directoryURL: URL?, onOpenProject: @escaping () -> Void, onOpenWorkspace: @escaping (WorkspaceIdentity) -> Void) {
        _guide = StateObject(wrappedValue: ChangeGuideModel(rootURL: directoryURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
        let sessions = TerminalSessions(workingDirectory: directoryURL)
        _terminals = StateObject(wrappedValue: sessions)
        _projectCommands = StateObject(wrappedValue: ProjectCommands(
            root: directoryURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath), sessions: sessions
        ))
        self.directoryURL = directoryURL
        self.onOpenProject = onOpenProject
        self.onOpenWorkspace = onOpenWorkspace
        _repository = StateObject(wrappedValue: GitSidebarModel(
            rootURL: directoryURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ))
    }
    @State private var openDrawer: WorkspaceDrawer?
    // One observer for the whole workspace so every column's header band shifts together.
    @State private var isWindowFullScreen = false
    /// The peek opened most recently, while it still owns Escape and Return.
    @State private var armedPeekID: UUID?
    @State private var isPeekArmed = false
    /// The peek ⌘D opened, so pressing it again closes that one and no other.
    @State private var recentPeekID: UUID?
    /// The peek a held ⌘-number opened, closed again when the key is released.
    @State private var holdPeekID: UUID?
    @State private var isQuickOpenPresented = false
    @State private var isBranchPickerPresented = false
    @State private var isCommandPalettePresented = false
    @State private var isProjectPickerPresented = false
    @State private var isHelpPresented = false
    @State private var recentWorkspaces: [WorkspaceIdentity] = []

    private var isPalettePresented: Bool {
        isQuickOpenPresented || isBranchPickerPresented || isCommandPalettePresented || isProjectPickerPresented
    }
    @State private var isDrawerVisible = false
    @State private var drawerCleanupTask: Task<Void, Never>?
    @State private var diffSelections: [GitDiffSelection] = []
    @State private var fileSidebarWidth: CGFloat = 240
    @State private var gitSidebarWidth: CGFloat = 240
    @State private var dragStart: CGFloat?
    @State private var terminalFocusRequest = 0
    @State private var isCommandHeld = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedDiff: GitDiffSelection? {
        guard isDrawerVisible, case let .diff(change, area) = openDrawer else { return nil }
        return GitDiffSelection(change: change, area: area)
    }

    private var isGitPreviewVisible: Bool {
        guard isDrawerVisible else { return false }
        switch openDrawer {
        case .diff, .commit: return true
        default: return false
        }
    }

    private var isGuideOpen: Bool {
        if case .guide = openDrawer { return true }
        return false
    }

    private enum Layout {
        static let workspaceInset: CGFloat = 16
        static let workspaceCornerRadius: CGFloat = 14
        static let drawerCloseDuration = Duration.milliseconds(90)
    }

    var body: some View {
        GeometryReader { geometry in
            let drawerWidth = min(max(480, geometry.size.width * 0.62), geometry.size.width * 0.78)
            let gitWidth = min(gitSidebarWidth, geometry.size.width * 0.28)
            let fileWidth = min(fileSidebarWidth, geometry.size.width * 0.28)
            let terminalWidth = max(0, geometry.size.width - fileWidth - gitWidth - 8)
            let headerTop = WorkspaceMetrics.titleBarClearance(isFullScreen: isWindowFullScreen)
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    Group {
                        if let directoryURL {
                            FileTreeView(terminals: {
                                ProjectCommandsView(model: projectCommands, sessions: terminals, onSelect: showTerminal)
                            }, rootURL: directoryURL, onOpenFile: open, onOpenProjects: presentProjects,
                               topInset: 0)
                        } else {
                            Color.clear
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        WorkspaceHelpButton(isPresented: $isHelpPresented)
                            .padding(12)
                    }
                    .padding(.top, headerTop)
                    .padding(.bottom, WorkspaceMetrics.outerMargin)
                    .padding(.leading, WorkspaceMetrics.outerMargin)
                    .padding(.trailing, WorkspaceMetrics.panelGap)
                    .frame(width: fileWidth)
                    sidebarDivider(width: $fileSidebarWidth, direction: 1, availableWidth: geometry.size.width)

                    Group {
                        if let directoryURL {
                            VStack(spacing: 0) {
                                TerminalTabBar(sessions: terminals, showsShortcuts: isCommandHeld,
                                               onSelect: showTerminal, onPeek: peekTerminal,
                                               onAdd: addTerminal, onClose: removeTerminal)
                                    .disabled(isPalettePresented)
                                let visible = terminals.navigation.panelID == terminals.primary.id
                                PrimaryTerminalPane(
                                    session: terminals.primary,
                                    focusRequest: terminalFocusRequest,
                                    isVisible: visible,
                                    isActive: terminals.navigation.activeID == terminals.primary.id && !isPalettePresented,
                                    onActivate: primaryTerminalActivated,
                                    onRestart: terminals.restartPrimary
                                )
                                .id(directoryURL)
                                .opacity(visible ? 1 : 0)
                                .allowsHitTesting(visible)
                                .accessibilityHidden(!visible)
                            }
                        } else {
                            WorkspacePlaceholder()
                        }
                    }
                    .workspacePanel(isVisible: directoryURL != nil, fill: TerminalSurface.color)
                    .padding(.top, headerTop)
                    .padding(.bottom, WorkspaceMetrics.outerMargin)
                    .padding(.horizontal, WorkspaceMetrics.panelGap)
                    .frame(minWidth: min(480, geometry.size.width * 0.40))

                    sidebarDivider(width: $gitSidebarWidth, direction: -1, availableWidth: geometry.size.width)
                    Group {
                        if let directoryURL {
                            GitSidebarView(
                                rootURL: directoryURL,
                                topInset: 0,
                                onOpenBranches: {
                                    presentBranches()
                                },
                                selectedDiff: selectedDiff,
                                onSelectionsChange: { diffSelections = $0 },
                                onOpenFile: open,
                                onOpenDiff: { selection, selections in
                                    showDiff(selection, among: selections)
                                },
                                onOpenCommit: { commit in
                                    showCommit(commit)
                                },
                                onOpenGuide: showGuide
                            )
                            .id(directoryURL)
                        } else {
                            Color.clear
                        }
                    }
                    .padding(.top, headerTop)
                    .padding(.bottom, WorkspaceMetrics.outerMargin)
                    .padding(.leading, WorkspaceMetrics.panelGap)
                    .padding(.trailing, WorkspaceMetrics.outerMargin)
                    .frame(width: gitWidth)
                }

                if isGuideOpen && isDrawerVisible && !isPalettePresented {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { closeDrawer() }
                        .accessibilityLabel("Dismiss change brief")
                        .zIndex(0.5)
                }

                if let directoryURL {
                    // Keep each surface at one structural identity across both layouts.
                    // Moving it between conditional containers would rebuild its PTY.
                    // Source: libghostty-spm 1.5.2, TerminalSurfaceCoordinator.rebuildIfReady.
                    ForEach(terminals.supporting) { session in
                        let peekIndex = terminals.navigation.peekedIDs.firstIndex(of: session.id)
                        let isPeek = peekIndex != nil
                        let fillsPanel = terminals.navigation.panelID == session.id
                        let visible = isPeek || fillsPanel
                        let slot = peekSlot(
                            index: peekIndex ?? 0,
                            count: max(1, terminals.navigation.peekedIDs.count),
                            in: geometry.size,
                            headerTop: headerTop
                        )
                        TerminalDrawer(
                            session: session,
                            isVisible: visible,
                            isParked: isPalettePresented || isDrawerVisible,
                            isTabbed: fillsPanel,
                            isPreview: isPeek,
                            onClose: { closeTerminalSurface(session) },
                            onActivate: {
                                // Clicking a shell preview promotes it. A command has
                                // nowhere to be promoted to, so it stays put.
                                guard session.savedCommandID == nil else { return }
                                showTerminal(session)
                            },
                            onRunCommand: {
                                guard let command = projectCommands.commands.first(where: { $0.id == session.savedCommandID }) else { return }
                                Task { if let restarted = await projectCommands.restart(command) { showTerminal(restarted) } }
                            },
                            onStopCommand: {
                                guard let command = projectCommands.commands.first(where: { $0.id == session.savedCommandID }) else { return }
                                Task { _ = await projectCommands.stop(command) }
                            }
                        )
                            .frame(width: peekWidth(isPeek: isPeek, fillsPanel: fillsPanel,
                                                    terminalWidth: terminalWidth, drawerWidth: drawerWidth),
                                   height: isPeek
                                    ? slot.height
                                    : (fillsPanel
                                       ? max(0, geometry.size.height - headerTop - WorkspaceMetrics.outerMargin - TerminalTabBar.height)
                                       : max(0, geometry.size.height - 32)))
                            .padding(.top, isPeek ? slot.top : (fillsPanel ? headerTop + TerminalTabBar.height : 16))
                            .padding(.bottom, isPeek ? slot.bottom : (fillsPanel ? WorkspaceMetrics.outerMargin : 16))
                            .padding(.trailing, isPeek
                                     ? WorkspaceMetrics.outerMargin
                                     : (fillsPanel ? gitWidth + 4 + WorkspaceMetrics.panelGap : 16))
                            // Park just past the right edge (plus the shadow) rather than a
                            // window-width away, with no fade: the peek reads as sliding in.
                            .offset(x: visible ? 0 : drawerWidth + WorkspaceMetrics.outerMargin + 48)
                            .allowsHitTesting(visible)
                            .accessibilityHidden(!visible)
                            .disabled(isPalettePresented)
                            .zIndex(isPeek ? 1 : 0.25)
                    }
                    ZStack(alignment: .top) {
                        if let openDrawer {
                            drawer(openDrawer, rootURL: directoryURL)
                        }
                    }
                    .disabled(isPalettePresented)
                    .frame(width: isGuideOpen ? min(1100, geometry.size.width - 32) : drawerWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(16)
                    .offset(x: isDrawerVisible ? 0 : geometry.size.width)
                    .opacity(isDrawerVisible ? 1 : 0)
                    .allowsHitTesting(isDrawerVisible)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(1)
                }

                if isPalettePresented, let directoryURL {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { dismissPalettes() }
                        .accessibilityLabel("Dismiss palette")
                        .zIndex(1.5)

                    Group {
                        if isProjectPickerPresented {
                            ProjectPickerView(
                                workspaces: recentWorkspaces,
                                onClose: { isProjectPickerPresented = false },
                                onOpen: { workspace in
                                    isProjectPickerPresented = false
                                    onOpenWorkspace(workspace)
                                },
                                onChooseDirectory: {
                                    isProjectPickerPresented = false
                                    onOpenProject()
                                }
                            )
                        } else if isCommandPalettePresented {
                            CommandPalette(
                                canSwitchBranch: repository.snapshot.isRepository && !repository.isBusy,
                                canHideTerminal: terminals.navigation.panelID != terminals.primary.id
                                    || !terminals.navigation.peekedIDs.isEmpty,
                                rootURL: directoryURL,
                                canShowGuide: repository.snapshot.isRepository,
                                guide: guide,
                                onSelectGuide: { scope in
                                    guide.scope = scope
                                    guide.openFromPalette = true
                                    guide.paletteRequestID = UUID()
                                    showGuide()
                                },
                                terminals: terminals,
                                onClose: { isCommandPalettePresented = false },
                                onSelect: performCommand,
                                onSelectTerminal: showTerminal
                            )
                        } else if isBranchPickerPresented {
                            BranchPickerView(rootURL: directoryURL, onClose: { isBranchPickerPresented = false })
                        } else {
                            QuickOpenPanel(
                                rootURL: directoryURL,
                                onOpen: open,
                                onClose: { isQuickOpenPresented = false }
                            )
                        }
                    }
                    .frame(width: min(600, geometry.size.width - 64), height: 420)
                    .padding(.top, 48)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
                }
            }
            .clipped()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background { WindowFullScreenObserver(isFullScreen: $isWindowFullScreen) }
        .background {
            WorkspaceShortcutMonitor(
                onQuickOpen: presentQuickOpen,
                onCommands: presentCommands,
                onProjects: presentProjects,
                onBranches: presentBranches,
                onNewTerminal: addTerminal,
                onSelectTerminal: selectTerminal,
                onPeekTerminal: peekTerminal,
                onPeekRecent: peekRecentTerminal,
                onHoldPeek: beginHoldPeek,
                onEndHoldPeek: endHoldPeek,
                onDismissPeek: dismissPeek,
                onPromotePeek: promotePeek,
                onCycleTerminal: cycleTerminal,
                onTogglePrimaryTerminal: togglePrimaryTerminal,
                preservesPreviewHunkShortcuts: isGitPreviewVisible && !isPalettePresented,
                isCommandHeld: $isCommandHeld,
                isPeekArmed: $isPeekArmed
            )
        }
        .transaction { if reduceMotion { $0.animation = nil } }
        .onChange(of: isPalettePresented) { _, isPresented in
            if isPresented { isHelpPresented = false }
        }
        .onChange(of: terminals.navigation.activeID) {
            if !isPalettePresented, !isDrawerVisible {
                terminals.active.terminal.requestFocus()
            }
        }
        .task { await terminals.monitorProcesses() }
        .task { if directoryURL != nil { await projectCommands.load() } }
        .onChange(of: terminals.supporting.map(\.id)) {
            if case let .terminal(id) = openDrawer,
               !terminals.supporting.contains(where: { $0.id == id }) {
                if terminals.navigation.activeID == terminals.primary.id {
                    // A parked session exiting must not take focus from a
                    // palette, editor, or the primary terminal being used.
                    drawerCleanupTask?.cancel()
                    withAnimation(.snappy(duration: 0.22)) {
                        openDrawer = nil
                        isDrawerVisible = false
                    }
                } else {
                    showTerminal(terminals.active)
                }
            }
        }
        .environmentObject(repository)
        .onAppear { if directoryURL != nil { repository.start() } }
        .onDisappear {
            repository.stop()
            guide.cancel()
            drawerCleanupTask?.cancel()
            terminals.stopAll()
        }
        .onAppear {
            guard let directoryURL else { return }
            let widths = UserDefaults.standard.array(forKey: "sidebarWidths:" + directoryURL.path) as? [Double]
            if let widths, widths.count == 2 {
                fileSidebarWidth = max(160, widths[0])
                gitSidebarWidth = max(160, widths[1])
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .focusedSceneValue(\.presentQuickOpen) {
            presentQuickOpen()
        }
        .focusedSceneValue(\.presentRecentProjects, presentProjects)
        .focusedSceneValue(\.presentCommandPalette, presentCommands)
    }

    private func dismissPalettes() {
        isProjectPickerPresented = false
        isQuickOpenPresented = false
        isBranchPickerPresented = false
        isCommandPalettePresented = false
    }

    private func presentCommands() {
        guard !repository.isSwitchingBranch else { return }
        let shouldPresent = !isCommandPalettePresented
        dismissPalettes()
        isCommandPalettePresented = shouldPresent
    }

    private func presentBranches() {
        guard repository.snapshot.isRepository, !repository.isBusy else { return }
        let shouldPresent = !isBranchPickerPresented
        dismissPalettes()
        isBranchPickerPresented = shouldPresent
    }

    private func presentQuickOpen() {
        guard directoryURL != nil, !repository.isSwitchingBranch else { return }
        isBranchPickerPresented = false
        isProjectPickerPresented = false
        isCommandPalettePresented = false
        withAnimation(.snappy(duration: 0.18)) {
            isQuickOpenPresented.toggle()
        }
    }

    private func open(_ fileURL: URL) {
        isQuickOpenPresented = false
        drawerCleanupTask?.cancel()
        withAnimation(.snappy(duration: 0.22)) {
            openDrawer = .file(fileURL)
            isDrawerVisible = true
        }
    }

    private func performCommand(_ command: WorkspaceCommand) {
        isCommandPalettePresented = false
        switch command {
        case .changeGuide: showGuide()
        case .reload: repository.reload()
        case .hideTerminal: hideTerminalDrawer()
        case .openProject: presentProjects()
        case .switchBranch:
            guard repository.snapshot.isRepository, !repository.isBusy else { return }
            isBranchPickerPresented = true
        }
    }

    private func presentProjects() {
        guard !repository.isSwitchingBranch else { return }
        let shouldPresent = !isProjectPickerPresented
        isQuickOpenPresented = false
        isCommandPalettePresented = false
        isBranchPickerPresented = false
        recentWorkspaces = RecentWorkspaces.load()
        isProjectPickerPresented = shouldPresent
    }

    private func showDiff(
        _ selection: GitDiffSelection,
        among selections: [GitDiffSelection]
    ) {
        drawerCleanupTask?.cancel()
        diffSelections = selections
        withAnimation(.snappy(duration: 0.22)) {
            openDrawer = .diff(selection.change, selection.area)
            isDrawerVisible = true
        }
    }

    private func showGuide() {
        dismissPalettes()
        drawerCleanupTask?.cancel()
        withAnimation(.snappy(duration: 0.18)) {
            openDrawer = .guide
            isDrawerVisible = true
        }
    }

    private func showCommit(_ commit: GitCommit) {
        drawerCleanupTask?.cancel()
        withAnimation(.snappy(duration: 0.22)) {
            openDrawer = .commit(commit)
            isDrawerVisible = true
        }
    }

    @ViewBuilder
    private func drawer(_ drawer: WorkspaceDrawer, rootURL: URL) -> some View {
        switch drawer {
        case .guide:
            ChangeGuideDrawer(rootURL: rootURL, model: guide, onClose: closeDrawer)
        case let .file(fileURL):
            FileEditorDrawer(fileURL: fileURL, onClose: closeDrawer)
        case let .diff(change, area):
            GitDiffDrawer(
                rootURL: rootURL,
                change: change,
                area: area,
                position: diffSelections.firstIndex(where: { $0.change.path == change.path && $0.area == area }).map { "\($0 + 1) of \(diffSelections.count)" },
                onClose: closeDrawer,
                onNavigate: navigateDiff
            )
        case .terminal:
            EmptyView()
        case let .commit(commit):
            GitCommitDrawer(rootURL: rootURL, commit: commit, onClose: closeDrawer)
        }
    }

    /// Vertical slot for one peek in the column beside the panel.
    private func peekSlot(index: Int, count: Int, in size: CGSize, headerTop: CGFloat)
        -> (top: CGFloat, height: CGFloat, bottom: CGFloat) {
        let gap = WorkspaceMetrics.gap
        let available = max(0, size.height - headerTop - WorkspaceMetrics.outerMargin)
        let height = max(0, (available - gap * CGFloat(count - 1)) / CGFloat(count))
        let top = headerTop + CGFloat(index) * (height + gap)
        let bottom = max(0, size.height - top - height)
        return (top, height, bottom)
    }

    private func peekWidth(isPeek: Bool, fillsPanel: Bool, terminalWidth: CGFloat, drawerWidth: CGFloat) -> CGFloat {
        if isPeek { return drawerWidth }
        return fillsPanel ? terminalWidth - WorkspaceMetrics.panelGap * 2 : drawerWidth
    }

    private static let peekAnimation = Animation.snappy(duration: 0.16)

    private func peekTerminal(_ session: TerminalSession) {
        dismissPalettes()
        withAnimation(Self.peekAnimation) { terminals.peek(session) }
        // Only a shell preview arms Escape and Return: a command peek has no promote
        // target, and it is usually opened while you are typing somewhere else.
        let armable = terminals.navigation.isPeeked(session.id) && session.savedCommandID == nil
        armedPeekID = armable ? session.id : nil
        isPeekArmed = armable
    }

    private func peekTerminal(_ number: Int) {
        guard directoryURL != nil else { return }
        let index = number - 1
        guard terminals.tabbed.indices.contains(index) else { return }
        peekTerminal(terminals.tabbed[index])
    }

    /// ⌘D: peek the shell you used last, or close the peek ⌘D opened. Returns whether a
    /// peek opened and is armed for Return.
    private func peekRecentTerminal() -> Bool {
        guard directoryURL != nil else { return false }
        if let id = recentPeekID, let session = terminals.peeked.first(where: { $0.id == id }) {
            recentPeekID = nil
            closeTerminalSurface(session)
            return false
        }
        // Only supporting shells can sit in the peek column; commands have their own rows.
        let shells = Set(terminals.supporting.filter { $0.savedCommandID == nil }.map(\.id))
        guard let id = terminals.navigation.recentPeekCandidate(among: shells),
              let session = terminals.supporting.first(where: { $0.id == id }) else { return false }
        peekTerminal(session)
        recentPeekID = session.id
        // Shells arm on peek; read navigation rather than state just written this frame.
        return terminals.navigation.isPeeked(session.id)
    }

    /// Holding ⌘-number shows that terminal only while held. A terminal already on screen
    /// is left alone, so releasing never closes a peek the hold didn't open.
    private func beginHoldPeek(_ number: Int) -> Bool {
        guard directoryURL != nil else { return false }
        let index = number - 1
        guard terminals.tabbed.indices.contains(index) else { return false }
        let session = terminals.tabbed[index]
        guard session.id != terminals.navigation.panelID,
              !terminals.navigation.isPeeked(session.id) else { return false }
        peekTerminal(session)
        holdPeekID = session.id
        return terminals.navigation.isPeeked(session.id)
    }

    private func endHoldPeek() {
        guard let id = holdPeekID else { return }
        holdPeekID = nil
        // Return while holding moved it into the panel; only a peek still open closes.
        if let session = terminals.peeked.first(where: { $0.id == id }) { closeTerminalSurface(session) }
    }

    /// Escape dismisses the newest preview, command or shell, and reports whether
    /// there was one. Escape reaches the panel untouched whenever the column is empty.
    private func dismissPeek() -> Bool {
        guard let session = terminals.peeked.last else { return false }
        closeTerminalSurface(session)
        return true
    }

    /// Return on a just-opened preview: it takes the panel.
    private func promotePeek() {
        guard let session = armedPeek, session.savedCommandID == nil else { return }
        armedPeekID = nil
        isPeekArmed = false
        showTerminal(session)
    }

    private var armedPeek: TerminalSession? {
        guard let armedPeekID else { return nil }
        return terminals.peeked.first { $0.id == armedPeekID }
    }

    private func addTerminal() {
        guard directoryURL != nil else { return }
        showTerminal(terminals.add())
    }

    private func showTerminal(_ session: TerminalSession) {
        guard session.savedCommandID == nil else {
            // A running command never takes the panel, however it was opened.
            peekTerminal(session)
            return
        }
        dismissPalettes()
        drawerCleanupTask?.cancel()
        terminals.select(session)
        if case .terminal = openDrawer {
            openDrawer = nil
            isDrawerVisible = false
        }
        // Also focus an already-visible session, e.g. after using the file tree
        // or a palette. New surfaces replay this request when they attach.
        // Source: libghostty-spm 1.5.2, TerminalViewState.requestFocus().
        session.terminal.requestFocus()
    }

    /// Close this surface: a peek leaves the column, the panel returns to primary.
    private func closeTerminalSurface(_ session: TerminalSession) {
        dismissPalettes()
        if terminals.navigation.isPeeked(session.id) {
            if armedPeekID == session.id {
                armedPeekID = nil
                isPeekArmed = false
            }
            withAnimation(Self.peekAnimation) { terminals.closePeek(session) }
            terminals.active.terminal.requestFocus()
            return
        }
        showTerminal(terminals.primary)
    }

    /// The palette's Hide Terminal: close the focused peek, else return the panel.
    private func hideTerminalDrawer() {
        if let focusedPeek = terminals.peeked.first(where: { $0.id == terminals.navigation.activeID }) {
            closeTerminalSurface(focusedPeek)
            return
        }
        if let lastPeek = terminals.peeked.last {
            closeTerminalSurface(lastPeek)
            return
        }
        showTerminal(terminals.primary)
    }

    private func primaryTerminalActivated() {
        terminals.select(terminals.primary)
    }

    private func selectTerminal(_ number: Int) {
        guard directoryURL != nil else { return }
        let index = number - 1
        guard terminals.tabbed.indices.contains(index) else { return }
        showTerminal(terminals.tabbed[index])
    }

    private func cycleTerminal(_ direction: Int) {
        guard directoryURL != nil else { return }
        let id = terminals.navigation.neighbor(in: direction)
        guard let session = terminals.all.first(where: { $0.id == id }) else { return }
        showTerminal(session)
    }

    private func togglePrimaryTerminal() {
        guard directoryURL != nil,
              let session = terminals.all.first(where: { $0.id == terminals.navigation.toggleTarget }) else { return }
        showTerminal(session)
    }

    private func removeTerminal(_ session: TerminalSession) {
        Task { await terminals.terminate(session) }
    }

    private func closeDrawer() {
        drawerCleanupTask?.cancel()
        withAnimation(.easeOut(duration: 0.09)) {
            isDrawerVisible = false
        }

        drawerCleanupTask = Task {
            try? await Task.sleep(for: Layout.drawerCloseDuration)
            guard !Task.isCancelled else { return }
            openDrawer = nil
            terminals.active.terminal.requestFocus()
        }
    }

    private func navigateDiff(_ navigation: GitDiffNavigation) {
        guard case let .diff(change, area) = openDrawer,
              let currentIndex = diffSelections.firstIndex(where: {
                  $0.change.path == change.path && $0.area == area
              })
        else { return }

        let nextIndex = switch navigation {
        case .previous: currentIndex - 1
        case .next: currentIndex + 1
        }
        guard diffSelections.indices.contains(nextIndex) else { return }

        let selection = diffSelections[nextIndex]
        openDrawer = .diff(selection.change, selection.area)
    }

    private func sidebarDivider(width: Binding<CGFloat>, direction: CGFloat, availableWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: 4)
            .contentShape(Rectangle())
            .onHover { isHovered in
                if isHovered {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            // The divider moves during resizing; measure in a fixed space so its
            // own movement cannot feed back into the next width calculation.
            // Source: https://developer.apple.com/documentation/swiftui/draggesture/coordinatespace
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil { dragStart = width.wrappedValue }
                    width.wrappedValue = min(max(160, (dragStart ?? width.wrappedValue) + direction * value.translation.width), availableWidth * 0.28)
                }
                .onEnded { _ in
                    dragStart = nil
                    guard let directoryURL else { return }
                    UserDefaults.standard.set([Double(fileSidebarWidth), Double(gitSidebarWidth)], forKey: "sidebarWidths:" + directoryURL.path)
                })
            .accessibilityLabel("Resize sidebar")
    }
}

private enum WorkspaceDrawer {
    case guide
    case terminal(UUID)
    case file(URL)
    case diff(GitChange, GitChange.Area)
    case commit(GitCommit)
}

private struct WorkspacePlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color.primary
            .opacity(colorScheme == .dark ? 0.08 : 0.045)
            .accessibilityHidden(true)
    }
}
