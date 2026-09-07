import SwiftUI

struct TerminalDrawer: View {
    @ObservedObject var session: TerminalSession
    let isVisible: Bool
    let isParked: Bool
    let onClose: () -> Void
    var onActivate: () -> Void = {}
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TerminalStatusDot(session: session)
                if isRenaming {
                    TextField("Terminal name", text: $draftName)
                        .textFieldStyle(.plain)
                        .runeFont(size: 12, weight: .medium)
                        .focused($isNameFocused)
                        .onSubmit { finishRenaming(returnFocus: true) }
                        .onExitCommand {
                            isRenaming = false
                            isNameFocused = false
                            if isVisible { session.terminal.requestFocus() }
                        }
                } else {
                    Text(session.name)
                        .runeFont(size: 12, weight: .medium)
                        .lineLimit(1)
                        .onTapGesture(count: 2, perform: beginRenaming)
                        .help("Double-click to rename terminal")
                        .accessibilityAction(named: "Rename terminal", beginRenaming)
                }
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
            TerminalPane(
                terminal: session.terminal,
                isVisible: isVisible,
                isActive: !isParked,
                onActivate: onActivate
            )
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
        .onChange(of: isNameFocused) {
            if !isNameFocused { finishRenaming() }
        }
        .onChange(of: isVisible) {
            if !isVisible { finishRenaming() }
        }
    }

    private func beginRenaming() {
        draftName = session.name
        isRenaming = true
        isNameFocused = true
    }

    private func finishRenaming(returnFocus: Bool = false) {
        guard isRenaming else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { session.customName = name }
        isRenaming = false
        isNameFocused = false
        if returnFocus && isVisible { session.terminal.requestFocus() }
    }
}
