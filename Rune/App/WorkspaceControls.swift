import SwiftUI

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
