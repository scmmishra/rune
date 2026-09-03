import SwiftUI

struct WorkspaceView: View {
    let directoryURL: URL?

    private enum Layout {
        static let sidebarWidthRatio: CGFloat = 0.20
        static let workspaceInset: CGFloat = 16
        static let workspaceCornerRadius: CGFloat = 14
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Group {
                    if let directoryURL {
                        FileTreeView(rootURL: directoryURL)
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

                Color.clear
                    .frame(width: geometry.size.width * Layout.sidebarWidthRatio)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct WorkspacePlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color.primary
            .opacity(colorScheme == .dark ? 0.08 : 0.045)
            .accessibilityHidden(true)
    }
}
