import SwiftUI

struct WorkspaceView: View {
    let directoryURL: URL?
    @State private var openDrawer: WorkspaceDrawer?
    @State private var isQuickOpenPresented = false
    @State private var isDrawerVisible = false
    @State private var drawerCleanupTask: Task<Void, Never>?

    private enum Layout {
        static let sidebarWidthRatio: CGFloat = 0.20
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
                            FileTreeView(rootURL: directoryURL, onOpenFile: open)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: geometry.size.width * Layout.sidebarWidthRatio)

                    Group {
                        if let directoryURL {
                            TerminalPane(workingDirectory: directoryURL)
                                .id(directoryURL)
                        } else {
                            WorkspacePlaceholder()
                        }
                    }
                    .frame(minWidth: 480)
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

                    Group {
                        if let directoryURL {
                            GitSidebarView(
                                rootURL: directoryURL,
                                onOpenFile: open,
                                onOpenDiff: { change, area in
                                    showDiff(change, area: area)
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
                    .frame(width: geometry.size.width * Layout.sidebarWidthRatio)
                }

                if let openDrawer, let directoryURL {
                    drawer(openDrawer, rootURL: directoryURL)
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

                if isQuickOpenPresented, let directoryURL {
                    QuickOpenPanel(
                        rootURL: directoryURL,
                        onOpen: open,
                        onClose: { isQuickOpenPresented = false }
                    )
                    .frame(width: min(600, geometry.size.width - 64), height: 420)
                    .padding(.top, 48)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .focusedSceneValue(\.presentQuickOpen) {
            presentQuickOpen()
        }
    }

    private func presentQuickOpen() {
        guard directoryURL != nil else { return }
        withAnimation(.snappy(duration: 0.18)) {
            isQuickOpenPresented = true
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

    private func showDiff(_ change: GitChange, area: GitChange.Area) {
        drawerCleanupTask?.cancel()
        withAnimation(.snappy(duration: 0.22)) {
            openDrawer = .diff(change, area)
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
                onClose: closeDrawer
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
        }
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
