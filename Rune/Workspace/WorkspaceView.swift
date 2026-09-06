import AppKit
import SwiftUI

struct WorkspaceView: View {
    let directoryURL: URL?
    let onOpenProject: () -> Void
    let onOpenProjects: () -> Void
    @StateObject private var repository: GitSidebarModel

    init(directoryURL: URL?, onOpenProject: @escaping () -> Void, onOpenProjects: @escaping () -> Void) {
        self.directoryURL = directoryURL
        self.onOpenProject = onOpenProject
        self.onOpenProjects = onOpenProjects
        _repository = StateObject(wrappedValue: GitSidebarModel(
            rootURL: directoryURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ))
    }
    @State private var openDrawer: WorkspaceDrawer?
    @State private var isQuickOpenPresented = false
    @State private var isBranchPickerPresented = false
    @State private var isCommandPalettePresented = false
    @State private var isDrawerVisible = false
    @State private var drawerCleanupTask: Task<Void, Never>?
    @State private var diffSelections: [GitDiffSelection] = []
    @State private var fileSidebarWidth: CGFloat = 240
    @State private var gitSidebarWidth: CGFloat = 240
    @State private var dragStart: CGFloat?
    @State private var terminalFocusRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedDiff: GitDiffSelection? {
        guard isDrawerVisible, case let .diff(change, area) = openDrawer else { return nil }
        return GitDiffSelection(change: change, area: area)
    }

    private enum Layout {
        static let workspaceInset: CGFloat = 16
        static let workspaceCornerRadius: CGFloat = 14
        static let drawerCloseDuration = Duration.milliseconds(90)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    Group {
                        if let directoryURL {
                            FileTreeView(rootURL: directoryURL, onOpenFile: open, onOpenProjects: onOpenProjects)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: min(fileSidebarWidth, geometry.size.width * 0.28))
                    sidebarDivider(width: $fileSidebarWidth, direction: 1, availableWidth: geometry.size.width)

                    Group {
                        if let directoryURL {
                            TerminalPane(workingDirectory: directoryURL, focusRequest: terminalFocusRequest)
                                .id(directoryURL)
                        } else {
                            WorkspacePlaceholder()
                        }
                    }
                    .frame(minWidth: min(480, geometry.size.width * 0.40))
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: Layout.workspaceCornerRadius,
                            style: .continuous
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: Layout.workspaceCornerRadius,
                            style: .continuous
                        )
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    }
                    .padding(.vertical, Layout.workspaceInset)

                    sidebarDivider(width: $gitSidebarWidth, direction: -1, availableWidth: geometry.size.width)
                    Group {
                        if let directoryURL {
                            GitSidebarView(
                                rootURL: directoryURL,
                                onOpenBranches: {
                                    let shouldPresent = !isBranchPickerPresented
                                    isCommandPalettePresented = false
                                    isQuickOpenPresented = false
                                    isBranchPickerPresented = shouldPresent
                                },
                                selectedDiff: selectedDiff,
                                onSelectionsChange: { diffSelections = $0 },
                                onOpenFile: open,
                                onOpenDiff: { selection, selections in
                                    showDiff(selection, among: selections)
                                },
                                onOpenCommit: { commit in
                                    showCommit(commit)
                                }
                            )
                            .id(directoryURL)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: min(gitSidebarWidth, geometry.size.width * 0.28))
                }

                if let openDrawer, let directoryURL {
                    drawer(openDrawer, rootURL: directoryURL)
                    .disabled(isQuickOpenPresented || isBranchPickerPresented || isCommandPalettePresented)
                    .frame(
                        width: min(
                            max(480, geometry.size.width * 0.62),
                            geometry.size.width * 0.78
                        )
                    )
                    .padding(16)
                    .offset(x: isDrawerVisible ? 0 : geometry.size.width)
                    .opacity(isDrawerVisible ? 1 : 0)
                    .allowsHitTesting(isDrawerVisible)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(1)
                }

                if isQuickOpenPresented || isBranchPickerPresented || isCommandPalettePresented, let directoryURL {
                    Group {
                        if isCommandPalettePresented {
                            CommandPalette(
                                canSwitchBranch: repository.snapshot.isRepository && !repository.isBusy,
                                onClose: { isCommandPalettePresented = false },
                                onSelect: performCommand
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
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .transaction { if reduceMotion { $0.animation = nil } }
        .environmentObject(repository)
        .onAppear { if directoryURL != nil { repository.start() } }
        .onDisappear { repository.stop() }
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
        .focusedSceneValue(\.presentCommandPalette) {
            guard !repository.isSwitchingBranch else { return }
            let shouldPresent = !isCommandPalettePresented
            isQuickOpenPresented = false
            isBranchPickerPresented = false
            isCommandPalettePresented = shouldPresent
        }
    }

    private func presentQuickOpen() {
        guard directoryURL != nil, !repository.isSwitchingBranch else { return }
        isBranchPickerPresented = false
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
        case .reload: repository.reload()
        case .openProject: onOpenProject()
        case .switchBranch:
            guard repository.snapshot.isRepository, !repository.isBusy else { return }
            isBranchPickerPresented = true
        }
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
        case let .commit(commit):
            GitCommitDrawer(rootURL: rootURL, commit: commit, onClose: closeDrawer)
        }
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
            terminalFocusRequest += 1
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
            .gesture(DragGesture(minimumDistance: 1)
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
