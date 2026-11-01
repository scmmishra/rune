import SwiftUI

struct WorkspaceHelpButton: View {
    @Binding var isPresented: Bool
    @State private var isHovered = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(isHovered || isPresented ? .primary : .tertiary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Shortcuts & Help")
                    .runeFont(size: 14, weight: .semibold)

                VStack(spacing: 9) {
                    shortcut("Find a file", keys: "⌘P")
                    shortcut("Search in project", keys: "⇧⌘F")
                    shortcut("Command palette", keys: "⇧⌘P")
                    shortcut("Switch project", keys: "⇧⌘O")
                    shortcut("Switch branch", keys: "⇧⌘B")
                    shortcut("New terminal", keys: "⇧⌘T")
                    shortcut("Last terminal", keys: "⌘`")
                    shortcut("Switch terminal", keys: "⌘1–9")
                    shortcut("Previous / next terminal", keys: "⇧⌘[ / ]")
                    shortcut("Peek a terminal", keys: "Hold ⌘1–9")
                    shortcut("Open the peek", keys: "↩")
                    shortcut("Split right / down", keys: "⌘D / ⇧⌘D")
                    shortcut("Focus a pane", keys: "⌥⌘ arrows")
                    shortcut("Zoom the pane", keys: "⇧⌘↩")
                    shortcut("Resize / equalize panes", keys: "⌃⌘ arrows / ⌃⌘=")
                    shortcut("Close the pane", keys: "⌘W")
                    shortcut("Settings", keys: "⌘,")
                }

                Divider()

                VStack(alignment: .leading, spacing: 9) {
                    Text("In previews").runeFont(size: 11, weight: .semibold)
                    shortcut("Find text", keys: "⌘F")
                    shortcut("Save file", keys: "⌘S")
                    shortcut("Previous / next diff file", keys: "↑ / ↓")
                    shortcut("Previous / next hunk", keys: "⌥⌘↑ / ↓")
                    shortcut("Previous / next search result", keys: "⌥⌘↑ / ↓")
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
                    Text("Peeking shows a terminal beside the panel without leaving what you're doing. Tap ⌘ and a number to switch; hold it to peek until you let go, and press Return while holding to open it in the panel. ⌥⌘1–9 and ⌥-clicking a tab peek too.")
                    Text("⌘D splits the focused terminal into two columns and ⇧⌘D into two rows. The new pane starts in the project folder. Drag the gap between panes to resize them, or double-click it to make them equal. Drag a pane by its header to move it, and the other panes make room. ⇧⌘↩ zooms the focused pane over the others, and again to put it back.")
                    Text("Hold Command to see terminal shortcuts. Switch to any terminal by name in the command palette. In terminals, ⇧⌘[ and ⇧⌘] cycle tabs and Escape goes to the running application. In diff previews, ⌥⌘↑↓ navigates hunks.")
                    Text("⌘` switches between your two most recent terminals. A window always has a terminal: closing the last one opens a fresh shell.")
                    Text("Dismiss a preview with its header button or “Dismiss Terminal Preview” in the command palette. It keeps running. Close a tab to end its processes, or exit the shell to remove it. Right-click a tab to rename it.")
                    Text("Drag the edges beside the terminal to resize the sidebars. Drag the gap between two cards to change their heights, or double-click it to reset them. Rune remembers your layout.")
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Button("Replay Welcome…") { openWindow(id: "onboarding") }
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
