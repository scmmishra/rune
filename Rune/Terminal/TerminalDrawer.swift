import SwiftUI

struct TerminalDrawer: View {
    @ObservedObject var session: TerminalSession
    let isVisible: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TerminalStatusDot(session: session)
                Text(session.name)
                    .runeFont(size: 12, weight: .medium)
                    .lineLimit(1)
                if session.hasExited {
                    Text("Exited").runeFont(size: 11).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "chevron.right") }
                    .buttonStyle(WorkspaceButtonStyle())
                    .help("Hide Terminal (session keeps running)")
                    .accessibilityLabel("Hide terminal")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider()
            TerminalPane(terminal: session.terminal, isVisible: isVisible)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
    }
}
