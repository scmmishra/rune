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
    @StateObject private var layoutModel: WorkspaceLayoutModel

    init(directoryURL: URL?, onOpenProject: @escaping () -> Void, onOpenWorkspace: @escaping (WorkspaceIdentity) -> Void) {
        _guide = StateObject(wrappedValue: ChangeGuideModel(rootURL: directoryURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
        let sessions = TerminalSessions(workingDirectory: directoryURL)
        _terminals = StateObject(wrappedValue: sessions)
        _projectCommands = StateObject(wrappedValue: ProjectCommands(
            root: directoryURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath), sessions: sessions
        ))
        _layoutModel = StateObject(wrappedValue: WorkspaceLayoutModel(root: directoryURL))
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
    /// The peek a held ⌘-number opened, closed again when the key is released.
    @State private var holdPeekID: UUID?
    @State private var isQuickOpenPresented = false
    @State private var isBranchPickerPresented = false
    @State private var isCommandPalettePresented = false
    @State private var isProjectPickerPresented = false
    @State private var isHelpPresented = false
    @State private var recentWorkspaces: [WorkspaceIdentity] = []
    @State private var paletteBranches: [String] = []
    @State private var paletteBranchTask: Task<Void, Never>?
    // Held without observing: only the drawer redraws as the query and results change,
    // not the whole workspace on every keystroke.
    @State private var search = ProjectSearchModel()

    private var isPalettePresented: Bool {
        isQuickOpenPresented || isBranchPickerPresented || isCommandPalettePresented || isProjectPickerPresented
    }
    @State private var isDrawerVisible = false
    @State private var drawerCleanupTask: Task<Void, Never>?
    @State private var diffSelections: [GitDiffSelection] = []
    @State private var dragStart: CGFloat?
    // Held without observing: the pointer's every move redraws the drag overlay alone.
    @State private var cardDrag = WorkspaceCardDrag()
    /// The card being dragged. Set once at each end of a drag, to lift the cards above the
    /// terminals while one of them is carried across.
    @State private var draggedCard: WorkspaceCardID?
    @State private var isCommandHeld = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var updater = AppUpdater.shared

    private var selectedDiff: GitDiffSelection? {
        guard isDrawerVisible, case let .diff(change, area) = openDrawer else { return nil }
        return GitDiffSelection(change: change, area: area)
    }

    /// Previews that use ⌥⌘↑↓ for hunks or search results instead of terminal cycling.
    private var isPreviewNavigationVisible: Bool {
        guard isDrawerVisible else { return false }
        switch openDrawer {
        case .diff, .commit, .searchMatch: return true
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
            let headerTop = WorkspaceMetrics.titleBarClearance(isFullScreen: isWindowFullScreen)
            let isSplit = terminals.isSplit
            // The window as a row of card columns around the hub.
            let arrangement = layoutModel.layout.arrangement(
                in: geometry.size.width, margin: WorkspaceMetrics.outerMargin, gap: WorkspaceMetrics.gap
            )
            let contentHeight = max(0, geometry.size.height - headerTop - WorkspaceMetrics.outerMargin)
            // Where panes go: the hub below the tab row.
            let paneTop = headerTop + TerminalTabBar.height + (isSplit ? WorkspaceMetrics.gap : 0)
            // A lone pane sits inside the hub's card, one point in so the card's border shows.
            let paneInset: CGFloat = isSplit ? 0 : 1
            let paneHeight = max(0, geometry.size.height - paneTop - WorkspaceMetrics.outerMargin - paneInset)
            let paneArea = CGRect(x: arrangement.hubX + paneInset, y: paneTop,
                                  width: max(0, arrangement.hubWidth - paneInset * 2), height: paneHeight)
            ZStack(alignment: .trailing) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    if directoryURL != nil {
                        ForEach(arrangement.slots) { slot in
                            columnDivider(slot, availableWidth: geometry.size.width)
                                .frame(height: contentHeight)
                                .offset(x: slot.side == .leading ? slot.x + slot.width + 2 : slot.x - 6, y: headerTop)
                        }
                    }
                    Group {
                        if directoryURL != nil {
                            // Only the tab row lives here. Every terminal is placed over the
                            // hub further down, so a pane keeps one identity however the tab
                            // is split.
                            VStack(spacing: isSplit ? WorkspaceMetrics.gap : 0) {
                                TerminalTabBar(sessions: terminals, showsShortcuts: isCommandHeld,
                                               onSelect: showTerminal, onPeek: peekTerminal,
                                               onAdd: addTerminal, onClose: removeTab)
                                    .disabled(isPalettePresented)
                                    // Split panes are cards of their own, and so is the tab row.
                                    .workspacePanel(isVisible: isSplit, fill: TerminalSurface.color)
                                Color.clear
                            }
                        } else {
                            WorkspacePlaceholder()
                        }
                    }
                    .workspacePanel(isVisible: directoryURL != nil && !isSplit, fill: TerminalSurface.color)
                    .frame(width: arrangement.hubWidth, height: contentHeight)
                    .offset(x: arrangement.hubX, y: headerTop)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)

                if let directoryURL {
                    cards(arrangement, rootURL: directoryURL, top: headerTop, height: contentHeight,
                          size: geometry.size)
                        // A carried card passes over the terminals, not under them.
                        .zIndex(draggedCard == nil ? 0 : 1.1)
                }

                WorkspaceCardDragOverlay(drag: cardDrag)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .zIndex(1.2)

                if isGuideOpen && isDrawerVisible && !isPalettePresented {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { closeDrawer() }
                        .accessibilityLabel("Dismiss change brief")
                        .zIndex(0.5)
                }

                if let directoryURL {
                    let peeked = terminals.peeked
                    // Keep each surface at one structural identity across every layout.
                    // Moving it between conditional containers would rebuild its PTY.
                    // Source: libghostty-spm 1.5.2, TerminalSurfaceCoordinator.rebuildIfReady.
                    ForEach(terminals.all) { session in
                        terminalSurface(session, placement: placement(
                            of: session, peeked: peeked, paneArea: paneArea, size: geometry.size,
                            headerTop: headerTop, drawerWidth: drawerWidth
                        ), in: geometry.size)
                    }
                    if terminals.panelTab.stackDepth > 0 {
                        // Above the panes left underneath, below the zoomed one.
                        TerminalZoomStack(area: paneArea, depth: terminals.panelTab.stackDepth)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .transition(.opacity)
                            .zIndex(0.29)
                    }
                    if isSplit {
                        TerminalSplitDividers(dividers: terminals.panelTab.layout(in: paneArea, gap: WorkspaceMetrics.gap).dividers,
                                              onResize: { id, ratio in terminals.setRatio(ratio, ofSplit: id) })
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .disabled(isPalettePresented)
                            .zIndex(0.28)
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
                                canHideTerminal: terminals.navigation.panelID != terminals.primary.id,
                                canCheckForUpdates: updater.isConfigured && updater.canCheckForUpdates
                                    || !terminals.navigation.peekedIDs.isEmpty,
                                rootURL: directoryURL,
                                canShowGuide: repository.snapshot.isRepository,
                                projects: recentWorkspaces,
                                branches: paletteBranches,
                                currentBranch: repository.snapshot.branch,
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
                                onSelectTerminal: showTerminal,
                                onOpenProject: { workspace in
                                    isCommandPalettePresented = false
                                    onOpenWorkspace(workspace)
                                },
                                onSwitchBranch: { name in
                                    // Close first; the sidebar shows progress and any checkout error.
                                    isCommandPalettePresented = false
                                    guard name != repository.snapshot.branch, !repository.isBusy else { return }
                                    Task { await repository.switchBranch(name, create: false) }
                                }
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
            .coordinateSpace(.named(Self.workspaceSpace))
        }
        .background(WorkspaceChrome.color)
        .background { WindowFullScreenObserver(isFullScreen: $isWindowFullScreen) }
        .onAppear { terminals.onOpenLink = openTerminalLink }
        .background {
            WorkspaceShortcutMonitor(
                onQuickOpen: presentQuickOpen,
                onCommands: presentCommands,
                onProjects: presentProjects,
                onBranches: presentBranches,
                onSearch: toggleSearch,
                onNewTerminal: addTerminal,
                onSelectTerminal: selectTerminal,
                onPeekTerminal: peekTerminal,
                onPaneAction: performPaneAction,
                onHoldPeek: beginHoldPeek,
                onEndHoldPeek: endHoldPeek,
                onDismissPeek: dismissPeek,
                onPromotePeek: promotePeek,
                onCycleTerminal: cycleTerminal,
                onTogglePrimaryTerminal: togglePrimaryTerminal,
                preservesPreviewHunkShortcuts: isPreviewNavigationVisible && !isPalettePresented,
                isCommandHeld: $isCommandHeld,
                isPeekArmed: $isPeekArmed
            )
        }
        .transaction { if reduceMotion { $0.animation = nil } }
        .onChange(of: isPalettePresented) { _, isPresented in
            if isPresented { isHelpPresented = false }
        }
        .onChange(of: terminals.active.id) {
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
        .ignoresSafeArea(.container, edges: .top)
        .focusedSceneValue(\.presentQuickOpen) {
            presentQuickOpen()
        }
        .focusedSceneValue(\.presentRecentProjects, presentProjects)
        .focusedSceneValue(\.presentCommandPalette, presentCommands)
        .focusedSceneValue(\.presentProjectSearch, toggleSearch)
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
        if shouldPresent {
            recentWorkspaces = RecentWorkspaces.load()
            loadPaletteBranches()
        }
        isCommandPalettePresented = shouldPresent
    }

    /// Fetches branches fresh on every open, off the main thread, so the palette never lists
    /// a branch from an earlier open that may have been deleted or renamed since.
    private func loadPaletteBranches() {
        paletteBranchTask?.cancel()
        paletteBranches = []
        guard let directoryURL, repository.snapshot.isRepository else { return }
        paletteBranchTask = Task {
            let names = await Task.detached(priority: .userInitiated) {
                GitRepository.branches(at: directoryURL).names
            }.value
            guard !Task.isCancelled else { return }
            paletteBranches = names
        }
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

    private func open(_ fileURL: URL) { open(fileURL, line: nil) }

    private func open(_ fileURL: URL, line: Int?) {
        isQuickOpenPresented = false
        drawerCleanupTask?.cancel()
        withAnimation(.snappy(duration: 0.22)) {
            openDrawer = .file(fileURL, line: line)
            isDrawerVisible = true
        }
    }

    private func performCommand(_ command: WorkspaceCommand) {
        isCommandPalettePresented = false
        switch command {
        case .changeGuide: showGuide()
        case .searchProject: showSearch()
        case .reload: repository.reload()
        case .hideTerminal: hideTerminalDrawer()
        case .saveLayoutToRepository:
            do {
                try layoutModel.saveToRepository()
            } catch {
                NSAlert(error: error).runModal()
            }
        case .newTerminal: addTerminal()
        // The tab bar owns the confirmation, so ask there rather than ending processes here.
        case .closeTerminal: terminals.panel.needsCloseConfirmation = true
        case .showWelcome: openWindow(id: "onboarding")
        case .checkForUpdates: updater.controller.updater.checkForUpdates()
        case .openProject: presentProjects()
        // The palette lists terminals itself rather than handing this back.
        case .switchTerminal: break
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

    private func showSearch() {
        guard directoryURL != nil, !repository.isSwitchingBranch else { return }
        dismissPalettes()
        drawerCleanupTask?.cancel()
        withAnimation(.snappy(duration: 0.18)) {
            openDrawer = .search
            isDrawerVisible = true
        }
    }

    /// ⇧⌘F closes the results when they are showing; from a result's file it goes back to them.
    private func toggleSearch() {
        if isDrawerVisible, case .search = openDrawer {
            closeDrawer()
        } else {
            showSearch()
        }
    }

    /// A ⌘-clicked link in a terminal: project files open in Rune, the rest go to the system.
    private func openTerminalLink(_ link: TerminalLink) {
        switch link {
        case let .file(fileURL, line): open(fileURL, line: line)
        case let .external(url): NSWorkspace.shared.open(url)
        }
    }

    private func openSearchMatch(_ match: ProjectSearchMatch) {
        drawerCleanupTask?.cancel()
        search.selection = match.id
        openDrawer = .searchMatch(match)
        isDrawerVisible = true
    }

    private func searchNavigation(for match: ProjectSearchMatch) -> SearchResultNavigation {
        let matches = search.matches
        let index = matches.firstIndex { $0.id == match.id }
        func step(_ offset: Int) -> (() -> Void)? {
            guard let index, matches.indices.contains(index + offset) else { return nil }
            return { openSearchMatch(matches[index + offset]) }
        }
        return SearchResultNavigation(
            position: index.map { "\($0 + 1) of \(matches.count)" },
            onPrevious: step(-1),
            onNext: step(1),
            onBack: showSearch
        )
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
        case let .file(fileURL, line):
            FileEditorDrawer(fileURL: fileURL, revealLine: line, onClose: closeDrawer)
        case .search:
            ProjectSearchDrawer(model: search, onOpen: openSearchMatch, onClose: closeDrawer)
        case let .searchMatch(match):
            FileEditorDrawer(fileURL: match.url, reveal: match.range,
                             searchNavigation: searchNavigation(for: match), onClose: closeDrawer)
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

    /// Where one terminal sits in the workspace, and how it is drawn there.
    private struct TerminalPlacement {
        let frame: CGRect
        let isPeek: Bool
        /// Whether the terminal can be seen and used.
        let isVisible: Bool
        /// Whether it sits at its frame or waits past the window's edge. Panes under a
        /// zoomed one stay in place, so the zoomed pane grows over them and shrinks back.
        let isInPlace: Bool
        let isZoomed: Bool
        /// The focused pane draws above its siblings, which is what lets it cover them.
        let isRaised: Bool
        let style: TerminalDrawer.Style
    }

    private func placement(of session: TerminalSession, peeked: [TerminalSession], paneArea: CGRect,
                           size: CGSize, headerTop: CGFloat, drawerWidth: CGFloat) -> TerminalPlacement {
        if let index = peeked.firstIndex(where: { $0.id == session.id }) {
            let frame = peekFrame(index: index, count: peeked.count, in: size, headerTop: headerTop, width: drawerWidth)
            return TerminalPlacement(frame: frame, isPeek: true, isVisible: true, isInPlace: true,
                                     isZoomed: false, isRaised: false, style: .floating)
        }
        guard let tab = terminals.tab(containing: session),
              let frame = tab.layout(in: paneArea, gap: WorkspaceMetrics.gap,
                                     stackInset: TerminalZoomStack.peek * CGFloat(tab.stackDepth)).frames[session.id] else {
            // A saved command that is not beside the panel waits off screen at peek size.
            let frame = CGRect(x: size.width - 16 - drawerWidth, y: 16, width: drawerWidth, height: max(0, size.height - 32))
            return TerminalPlacement(frame: frame, isPeek: false, isVisible: false, isInPlace: false,
                                     isZoomed: false, isRaised: false, style: .floating)
        }
        // A pane keeps its place in its own tab while another tab is showing, so switching
        // tabs never resizes a terminal.
        let inPanel = tab.id == terminals.navigation.panelID
        return TerminalPlacement(
            frame: frame, isPeek: false,
            isVisible: inPanel && tab.shows(session.id), isInPlace: inPanel,
            isZoomed: tab.zoomedID == session.id, isRaised: tab.focusedID == session.id,
            style: terminals.isSplit ? .card : .merged
        )
    }

    private func terminalSurface(_ session: TerminalSession, placement: TerminalPlacement, in size: CGSize) -> some View {
        let frame = placement.frame
        let isPrimary = session.id == terminals.primary.id
        let onRestart: (() -> Void)? = isPrimary ? { terminals.restartPrimary() } : nil
        let zIndex: Double = placement.isPeek ? 1 : (placement.isRaised ? 0.3 : 0.25)
        let parkOffset: CGFloat = placement.isInPlace ? 0 : size.width - frame.minX + 48
        return TerminalDrawer(
            session: session,
            isVisible: placement.isVisible,
            isParked: isPalettePresented || isDrawerVisible,
            style: placement.style,
            isPreview: placement.isPeek,
            isFocused: session.id == terminals.active.id,
            isZoomed: placement.isZoomed,
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
            },
            onPane: { action in
                showTerminal(session)
                performPaneAction(action)
            },
            onTerminate: { Task { await terminals.terminate(session) } },
            onRestart: onRestart
        )
        // The stack is trailing-aligned and as tall as the window, so these paddings pin
        // the frame to its place in the workspace.
        .frame(width: frame.width, height: frame.height)
        .padding(.top, frame.minY)
        .padding(.bottom, max(0, size.height - frame.maxY))
        .padding(.trailing, max(0, size.width - frame.maxX))
        // Park just past the right edge (plus the shadow) rather than a window-width
        // away, with no fade: the peek reads as sliding in.
        .offset(x: parkOffset)
        // Panes under a zoomed one fade out, leaving the stack's edges to stand for them.
        .opacity(placement.isInPlace && !placement.isVisible ? 0 : 1)
        .allowsHitTesting(placement.isVisible)
        .accessibilityHidden(!placement.isVisible)
        .disabled(isPalettePresented)
        .zIndex(zIndex)
    }

    /// The frame of one peek in the column beside the panel.
    private func peekFrame(index: Int, count: Int, in size: CGSize, headerTop: CGFloat, width: CGFloat) -> CGRect {
        let gap = WorkspaceMetrics.gap
        let available = max(0, size.height - headerTop - WorkspaceMetrics.outerMargin)
        let height = max(0, (available - gap * CGFloat(count - 1)) / CGFloat(max(1, count)))
        return CGRect(x: size.width - WorkspaceMetrics.outerMargin - width,
                      y: headerTop + CGFloat(index) * (height + gap), width: width, height: height)
    }

    private static let peekAnimation = Animation.snappy(duration: 0.16)
    private static let zoomAnimation = Animation.snappy(duration: 0.18)

    private func peekTerminal(_ session: TerminalSession) {
        dismissPalettes()
        withAnimation(Self.peekAnimation) { terminals.peek(session) }
        // Only a shell preview arms Escape and Return: a command peek has no promote
        // target, and it is usually opened while you are typing somewhere else.
        let armable = terminals.isPeeked(session) && session.savedCommandID == nil
        armedPeekID = armable ? session.id : nil
        isPeekArmed = armable
    }

    private func peekTerminal(_ number: Int) {
        guard directoryURL != nil else { return }
        guard let session = terminals.tabSession(at: number - 1) else { return }
        peekTerminal(session)
    }

    /// Splits, zoom, and moving between panes, from a shortcut or a pane's header.
    private func performPaneAction(_ action: TerminalPaneAction) {
        guard directoryURL != nil, !isPalettePresented else { return }
        switch action {
        case let .split(axis):
            // A new surface replays this request when it attaches.
            terminals.split(axis).terminal.requestFocus()
        case .zoom: withAnimation(Self.zoomAnimation) { terminals.toggleZoom() }
        // Nothing moves but the headers' controls, which slide as they do on hover.
        case let .focus(dx, dy): withAnimation(TerminalDrawer.controlsAnimation) { terminals.focusPane(dx: dx, dy: dy) }
        case let .resize(dx, dy): terminals.resizePane(dx: dx, dy: dy)
        case .equalize: terminals.equalizePanes()
        case .close: closeActivePane()
        }
    }

    /// ⌘W: a peek goes back, and a pane closes. A shell at its prompt has nothing to lose,
    /// so only a pane that is running something asks first.
    private func closeActivePane() {
        let session = terminals.active
        if terminals.isPeeked(session) {
            closeTerminalSurface(session)
        } else if session.foreground?.isIdle == true || session.hasExited {
            Task { await terminals.terminate(session) }
        } else {
            session.needsCloseConfirmation = true
        }
    }

    /// Holding ⌘-number shows that terminal only while held. A terminal already on screen
    /// is left alone, so releasing never closes a peek the hold didn't open.
    private func beginHoldPeek(_ number: Int) -> Bool {
        guard directoryURL != nil else { return false }
        guard let session = terminals.tabSession(at: number - 1),
              terminals.tab(containing: session)?.id != terminals.navigation.panelID,
              !terminals.isPeeked(session) else { return false }
        peekTerminal(session)
        holdPeekID = session.id
        return terminals.isPeeked(session)
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
        if terminals.isPeeked(session) {
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

    private func selectTerminal(_ number: Int) {
        guard directoryURL != nil else { return }
        guard let session = terminals.tabSession(at: number - 1) else { return }
        showTerminal(session)
    }

    private func cycleTerminal(_ direction: Int) {
        guard directoryURL != nil else { return }
        guard let session = terminals.session(forNavigation: terminals.navigation.neighbor(in: direction)) else { return }
        showTerminal(session)
    }

    private func togglePrimaryTerminal() {
        guard directoryURL != nil,
              let session = terminals.session(forNavigation: terminals.navigation.toggleTarget) else { return }
        showTerminal(session)
    }

    /// The tab's close button: every pane of the tab goes.
    private func removeTab(_ session: TerminalSession) {
        Task { await terminals.terminateTab(containing: session) }
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

    private static let workspaceSpace = "workspace"
    private static let cardMoveAnimation = Animation.snappy(duration: 0.22)

    /// Every card, placed by column. One list for all columns, so a card that moves to
    /// another column keeps its view and whatever it was holding, such as a commit draft.
    private func cards(_ arrangement: WorkspaceArrangement, rootURL: URL, top: CGFloat, height: CGFloat,
                       size: CGSize) -> some View {
        WorkspaceCardsLayout(slots: arrangement.slots, top: top, height: height, spacing: WorkspaceMetrics.gap) {
            ForEach(layoutModel.layout.cards, id: \.self) { id in
                card(id, rootURL: rootURL)
                    .modifier(WorkspaceDraggedCard(drag: cardDrag, id: id))
                    // Measured outside the drag's offset, so this is the card's place in its
                    // column, not where the pointer has carried it.
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.workspaceSpace)) } action: {
                        cardDrag.cardFrames[id] = $0
                    }
                    .simultaneousGesture(cardDragGesture(id, arrangement: arrangement, top: top, height: height, size: size))
                    .workspaceCard(id)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// Dragging a card by its header moves it. The gesture sits beside the header's own
    /// buttons instead of over them, so a click still reaches them.
    private func cardDragGesture(_ id: WorkspaceCardID, arrangement: WorkspaceArrangement, top: CGFloat,
                                 height: CGFloat, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.workspaceSpace))
            .onChanged { value in
                if !cardDrag.isActive {
                    // Only the header band starts a move; the rest of a card scrolls and selects.
                    guard draggedCard == nil, let frame = cardDrag.cardFrames[id],
                          value.startLocation.y - frame.minY <= WorkspaceMetrics.bandHeight else { return }
                    draggedCard = id
                    cardDrag.begin(id)
                    NSCursor.closedHand.push()
                }
                guard cardDrag.card == id else { return }
                cardDrag.move(by: value.translation, target: layoutModel.layout.dropTarget(
                    for: id, at: value.location, arrangement: arrangement, cardFrames: cardDrag.cardFrames,
                    top: top, height: height, width: size.width, gap: WorkspaceMetrics.gap
                ))
            }
            .onEnded { _ in
                guard cardDrag.card == id else { return }
                NSCursor.pop()
                // One animation carries the card from under the pointer to its new place, or
                // back to where it came from.
                var dropped = false
                withAnimation(Self.cardMoveAnimation) {
                    if let target = cardDrag.end() {
                        layoutModel.update { $0.place(id, at: target.destination) }
                        dropped = true
                    }
                }
                if dropped { layoutModel.save() }
                // The cards stay above the terminals until the card has settled.
                Task {
                    try? await Task.sleep(for: .milliseconds(240))
                    if !cardDrag.isActive { draggedCard = nil }
                }
            }
    }

    /// What each card draws. The layout only knows a card by its ID and sizing.
    @ViewBuilder
    private func card(_ id: WorkspaceCardID, rootURL: URL) -> some View {
        switch id {
        case .commands:
            ProjectCommandsView(model: projectCommands, sessions: terminals, onSelect: showTerminal)
        case .files:
            FileTreeView(rootURL: rootURL, onOpenFile: open, onOpenProjects: presentProjects)
                .overlay(alignment: .bottomLeading) {
                    WorkspaceHelpButton(isPresented: $isHelpPresented)
                        .padding(12)
                }
        case .changes:
            GitSidebarView(
                rootURL: rootURL,
                topInset: 0,
                onOpenBranches: presentBranches,
                selectedDiff: selectedDiff,
                onSelectionsChange: { diffSelections = $0 },
                onOpenFile: open,
                onOpenDiff: { selection, selections in showDiff(selection, among: selections) },
                onOpenGuide: showGuide
            )
            .id(rootURL)
        case .history:
            GitHistoryCard(rootURL: rootURL, onOpenCommit: showCommit)
                .id(rootURL)
        case .usage:
            AgentUsagePanel(sessions: terminals)
        default:
            EmptyView()
        }
    }

    /// The handle in the gap between a card column and its neighbour toward the hub.
    private func columnDivider(_ slot: WorkspaceArrangement.Slot, availableWidth: CGFloat) -> some View {
        // Dragging toward the hub widens the column, whichever side it is on.
        let direction: CGFloat = slot.side == .leading ? 1 : -1
        return Color.clear
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
                    if dragStart == nil { dragStart = slot.width }
                    let width = (dragStart ?? slot.width) + direction * value.translation.width
                    layoutModel.update { $0.setWidth(width, ofColumn: slot.id) }
                }
                .onEnded { _ in
                    dragStart = nil
                    // Keep the width the window allowed, not one dragged past its limit.
                    layoutModel.update { $0.setWidth(slot.width, ofColumn: slot.id) }
                    layoutModel.save()
                })
            .accessibilityLabel("Resize column")
    }
}

private enum WorkspaceDrawer {
    case guide
    case terminal(UUID)
    case file(URL, line: Int?)
    case search
    case searchMatch(ProjectSearchMatch)
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
