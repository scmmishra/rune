import SwiftUI

struct WorkspaceView: View {
    let directoryURL: URL?
    @State private var openFileURL: URL?
    @State private var openDiff: OpenGitDiff?
    @State private var isQuickOpenPresented = false

    private enum Layout {
        static let sidebarWidthRatio: CGFloat = 0.20
        static let workspaceInset: CGFloat = 16
        static let workspaceCornerRadius: CGFloat = 14
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    Group {
                        if let directoryURL {
                            FileTreeView(rootURL: directoryURL) { fileURL in
                                withAnimation(.snappy(duration: 0.22)) {
                                    openDiff = nil
                                    openFileURL = fileURL
                                }
                            }
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
                            GitSidebarView(rootURL: directoryURL) { change, area in
                                withAnimation(.snappy(duration: 0.22)) {
                                    openFileURL = nil
                                    openDiff = OpenGitDiff(change: change, area: area)
                                }
                            }
                                .id(directoryURL)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: geometry.size.width * Layout.sidebarWidthRatio)
                }

                if let openFileURL {
                    FileEditorDrawer(fileURL: openFileURL) {
                        withAnimation(.snappy(duration: 0.18)) {
                            self.openFileURL = nil
                        }
                    }
                    .frame(
                        width: min(
                            max(480, geometry.size.width * 0.62),
                            geometry.size.width * 0.78
                        )
                    )
                    .padding(16)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(1)
                }

                if let openDiff, let directoryURL {
                    GitDiffDrawer(
                        rootURL: directoryURL,
                        change: openDiff.change,
                        area: openDiff.area
                    ) {
                        withAnimation(.snappy(duration: 0.18)) {
                            self.openDiff = nil
                        }
                    }
                    .frame(
                        width: min(
                            max(480, geometry.size.width * 0.62),
                            geometry.size.width * 0.78
                        )
                    )
                    .padding(16)
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
        withAnimation(.snappy(duration: 0.22)) {
            openDiff = nil
            openFileURL = fileURL
        }
    }
}

private struct OpenGitDiff {
    let change: GitChange
    let area: GitChange.Area
}

private struct WorkspacePlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color.primary
            .opacity(colorScheme == .dark ? 0.08 : 0.045)
            .accessibilityHidden(true)
    }
}
