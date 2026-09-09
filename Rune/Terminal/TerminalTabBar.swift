import SwiftUI

struct TerminalTabBar: View {
    @ObservedObject var sessions: TerminalSessions
    let onSelect: (TerminalSession) -> Void
    let onAdd: () -> Void
    let onClose: (TerminalSession) -> Void

    static let height: CGFloat = 38

    var body: some View {
        ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(Array(sessions.all.enumerated()), id: \.element.id) { index, session in
                            TerminalTab(
                                session: session,
                                isPrimary: session.id == sessions.primary.id,
                                shortcutNumber: index < 9 ? index + 1 : nil,
                                isSelected: session.id == sessions.navigation.activeID,
                                onSelect: { onSelect(session) },
                                onClose: { onClose(session) }
                            )
                            .id(session.id)
                        }
                        Button(action: onAdd) { Image(systemName: "plus").frame(width: 28, height: 28) }
                            .buttonStyle(WorkspaceButtonStyle())
                            .help("New Terminal (⇧⌘T)")
                            .accessibilityLabel("New terminal")
                    }
                }
                .scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(sessions.navigation.activeID) }
                .onChange(of: sessions.navigation.activeID) {
                    proxy.scrollTo(sessions.navigation.activeID)
                }
        }
        .frame(height: Self.height)
    }
}

private struct TerminalTab: View {
    private static let width: CGFloat = 160
    @ObservedObject var session: TerminalSession
    let isPrimary: Bool
    let shortcutNumber: Int?
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isConfirmingClose = false
    @State private var isRenaming = false
    @State private var draftName = ""

    private var title: String { isPrimary ? session.customName ?? "Terminal" : session.name }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    TerminalStatusDot(session: session)
                    Text(title).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
                .padding(.trailing, 2)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            Button { isConfirmingClose = true } label: {
                Image(systemName: "xmark").frame(width: 20, height: 24)
            }
            .padding(.trailing, 4)
            .accessibilityLabel("Close \(title)")
            .help("Close terminal…")
            .disabled(session.isStopping)
        }
        .runeFont(size: 11, weight: isSelected ? .medium : .regular)
        .buttonStyle(.plain)
        .frame(width: Self.width)
        .background(Color.primary.opacity(isSelected ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 6))
        .help(shortcutNumber.map { "\(title) (⌘\($0))" } ?? title)
        .contextMenu {
            if session.savedCommandID == nil {
                Button("Rename…") {
                    draftName = title
                    isRenaming = true
                }
            }
            Button("Close Terminal…", role: .destructive) { isConfirmingClose = true }
                .disabled(session.isStopping)
        }
        .onChange(of: session.needsCloseConfirmation) {
            if session.needsCloseConfirmation {
                isConfirmingClose = true
                session.needsCloseConfirmation = false
            }
        }
        .alert("Close \(title)?", isPresented: $isConfirmingClose) {
            Button("Cancel", role: .cancel) {}
            Button("Close Terminal", role: .destructive, action: onClose)
        } message: {
            Text(isPrimary
                 ? "This ends the terminal’s running processes and starts a fresh terminal in its place."
                 : "This ends the terminal’s running processes. Saved commands remain available in the sidebar.")
        }
        .alert("Rename Terminal", isPresented: $isRenaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { session.customName = name }
            }
        }
    }
}
