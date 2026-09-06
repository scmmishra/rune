import SwiftUI

struct WorkspaceHelpButton: View {
    @Binding var isPresented: Bool
    @State private var isHovered = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "questionmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovered || isPresented ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle().fill(Color.primary.opacity(isHovered || isPresented ? 0.08 : 0))
                    Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Shortcuts and Help")
        .accessibilityLabel("Shortcuts and Help")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            WorkspaceHelpView()
                .onExitCommand { isPresented = false }
        }
    }
}

private struct WorkspaceHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Shortcuts & Help")
                    .runeFont(size: 14, weight: .semibold)

                VStack(spacing: 9) {
                    shortcut("Find a file", keys: "⌘P")
                    shortcut("Command palette", keys: "⇧⌘P")
                    shortcut("Switch project", keys: "⇧⌘O")
                    shortcut("Switch branch", keys: "⇧⌘B")
                    shortcut("Settings", keys: "⌘,")
                }

                Divider()

                VStack(alignment: .leading, spacing: 9) {
                    Text("In previews").runeFont(size: 11, weight: .semibold)
                    shortcut("Find text", keys: "⌘F")
                    shortcut("Save file", keys: "⌘S")
                    shortcut("Previous / next diff file", keys: "↑ / ↓")
                    shortcut("Previous / next hunk", keys: "⌥⌘↑ / ↓")
                    shortcut("Dismiss Find or preview", keys: "Esc")
                    Text("Diff file navigation works when the text editor is not focused.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Getting around").runeFont(size: 11, weight: .semibold)
                    Text("Click the project or branch name to switch. Choose Directory… opens any project folder.")
                    Text("In palettes, use ↑↓ to select and Return to open. Press Escape or click outside to dismiss.")
                    Text("Drag the edges beside the terminal to resize the sidebars. Rune remembers your layout.")
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .runeFont(size: 11)
            .padding(18)
        }
        .frame(width: 340, height: 480)
    }

    private func shortcut(_ title: String, keys: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            Text(keys)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}
