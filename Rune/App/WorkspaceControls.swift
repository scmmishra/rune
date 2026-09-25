import AppKit
import SwiftUI

/// The recessed surface behind the workspace's cards.
enum WorkspaceChrome {
    static let color = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(white: isDark ? 0.065 : 0.885, alpha: 1)
    })

}

/// The one card surface in the workspace: the terminal panel and every sidebar section.
/// Sharing fill, radius and border is what makes the columns read as one set.
private struct WorkspacePanel: ViewModifier {
    let isVisible: Bool
    let radius: CGFloat
    let fill: Color
    let isRaised: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .clipShape(shape)
            // The shadow belongs to a static shape behind the content. Put on the
            // content, it would be recomputed from the terminal's pixels every frame.
            .background {
                if isVisible {
                    shape.fill(fill)
                        .shadow(color: .black.opacity(isRaised ? (colorScheme == .dark ? 0.45 : 0.10) : 0), radius: 10, y: 2)
                }
            }
            .overlay {
                shape.strokeBorder(Color.primary.opacity(isVisible ? (colorScheme == .dark ? 0.08 : 0.06) : 0), lineWidth: 1)
            }
    }
}

extension View {
    /// The terminal panel: the same card, lifted slightly as the workspace's focus.
    func workspacePanel(isVisible: Bool = true, fill: Color) -> some View {
        modifier(WorkspacePanel(isVisible: isVisible, radius: WorkspaceMetrics.panelRadius, fill: fill, isRaised: true))
    }

    /// A section card in a sidebar column.
    func workspaceGroup() -> some View {
        modifier(WorkspacePanel(isVisible: true, radius: WorkspaceMetrics.groupRadius,
                                fill: TerminalSurface.color, isRaised: false))
    }

    /// A section label on the chrome, shared by every sidebar section.
    func sidebarSectionLabel() -> some View {
        runeFont(size: 10, weight: .semibold)
            .tracking(0.6)
            .foregroundStyle(.secondary)
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
