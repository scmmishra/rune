import SwiftUI

/// The shared surface for the workspace's three columns.
///
/// The terminal used to be the only panel, which left the sidebars reading as
/// margin around it. Giving all three the same surface makes alignment a
/// property of the containers instead of a negotiation between controls.
private struct WorkspacePanel: ViewModifier {
    let isVisible: Bool
    let radius: CGFloat
    var fill: Color = Color(nsColor: .textBackgroundColor)

    func body(content: Content) -> some View {
        content
            .background(isVisible ? fill : .clear)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.primary.opacity(isVisible ? 0.10 : 0), lineWidth: 1)
            }
    }
}

extension View {
    func workspacePanel(isVisible: Bool = true, fill: Color? = nil) -> some View {
        modifier(WorkspacePanel(
            isVisible: isVisible,
            radius: WorkspaceMetrics.panelRadius,
            fill: fill ?? Color(nsColor: .textBackgroundColor)
        ))
    }

    /// A group card stacked inside a sidebar column: the panel surface, one size down.
    func workspaceGroup(isVisible: Bool = true) -> some View {
        modifier(WorkspacePanel(isVisible: isVisible, radius: WorkspaceMetrics.groupRadius))
    }
}

/// Selection and hover fill for a sidebar row, matching the file tree and Git lists.
private struct SidebarRowBackground: ViewModifier {
    let isSelected: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                Color.primary.opacity(isSelected ? 0.08 : isHovered ? 0.04 : 0),
                in: RoundedRectangle(cornerRadius: WorkspaceMetrics.rowRadius, style: .continuous)
            )
            .onHover { isHovered = $0 }
    }
}

extension View {
    func sidebarRowBackground(isSelected: Bool = false) -> some View {
        modifier(SidebarRowBackground(isSelected: isSelected))
    }
}

/// Quiet chrome with a consistent hit target, without changing text styling.
struct WorkspaceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration)
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 5)
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(RoundedRectangle(cornerRadius: 5))
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(isEnabled ? (configuration.isPressed ? 0.12 : isHovered ? 0.06 : 0) : 0))
                }
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovered = $0 }
        }
    }
}

struct QuietProgressView: View {
    let isActive: Bool
    @State private var isVisible = false

    var body: some View {
        Group {
            if isVisible {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Loading")
            }
        }
        .task(id: isActive) {
            isVisible = false
            guard isActive else { return }
            // Fast refreshes should not flash a spinner; cancellation covers completion.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            isVisible = true
        }
    }
}
