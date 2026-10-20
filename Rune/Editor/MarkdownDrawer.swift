import SwiftUI

/// A Markdown page that is not a file, such as a plan an agent shows with
/// `rune_open_markdown`. Mermaid blocks render as diagrams, and path links open files.
struct MarkdownDrawer: View {
    let title: String
    let text: String
    let onOpenPath: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                Text(title)
                    .runeFont(size: 12, weight: .medium)
                    .lineLimit(1)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(WorkspaceButtonStyle())
                    .help("Close Preview (Esc)")
                    .accessibilityLabel("Close preview")
            }
            .runeFont(size: 11, weight: .semibold)
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider()

            MarkdownPreview(text: text, onOpenPath: onOpenPath)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
        .background { DrawerEscapeMonitor(onEscape: onClose) }
    }
}
