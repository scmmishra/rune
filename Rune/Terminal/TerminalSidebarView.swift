import SwiftUI

struct TerminalSidebarView: View {
    @ObservedObject var sessions: TerminalSessions
    let selectedID: UUID?
    let onSelect: (TerminalSession) -> Void
    let onAdd: () -> Void
    let onRemove: (TerminalSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TERMINALS")
                    .runeFont(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onAdd) { Image(systemName: "plus") }
                    .buttonStyle(WorkspaceButtonStyle())
                    .help("New Terminal (⇧⌘T)")
                    .accessibilityLabel("New terminal")
            }
            .padding(.horizontal, 8)

            if !sessions.supporting.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(sessions.supporting) { session in
                            TerminalSessionRow(
                                session: session,
                                isSelected: selectedID == session.id,
                                onSelect: { onSelect(session) },
                                onRemove: { onRemove(session) }
                            )
                        }
                    }
                }
                .frame(height: min(CGFloat(sessions.supporting.count) * 30, 180))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

private struct TerminalSessionRow: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    @State private var isRenaming = false
    @State private var draftName = ""

    @State private var isConfirmingClose = false
    @State private var isClosing = false

    var body: some View {
        HStack(spacing: 6) {
            if isConfirmingClose {
                Text("Close \(session.name)?")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { isConfirmingClose = false } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Cancel")
                .accessibilityLabel("Cancel closing terminal")
            } else {
                Button(action: onSelect) {
                    HStack(spacing: 8) {
                        TerminalStatusDot(session: session)
                        Text(session.name).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }

            Button {
                if isConfirmingClose {
                    isClosing = true
                    onRemove()
                } else {
                    isConfirmingClose = true
                }
            } label: {
                Image(systemName: isConfirmingClose ? "trash.fill" : "xmark")
                    .foregroundStyle(isConfirmingClose ? Color.red : Color.secondary)
                    .frame(width: 18, height: 22)
                    .contentShape(Rectangle())
            }
            .help(isConfirmingClose ? "End processes and remove terminal" : "Close terminal…")
            .accessibilityLabel(isConfirmingClose ? "Confirm close terminal" : "Close terminal")
        }
        .runeFont(size: 11)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.red.opacity(isConfirmingClose ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 5))
        .background(Color.primary.opacity(isSelected && !isConfirmingClose ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 5))
        .buttonStyle(.plain)
        .disabled(isClosing)
        .contextMenu {
            Button("Rename…") {
                draftName = session.name
                isRenaming = true
            }
            if session.customName != nil {
                Button("Reset Name") { session.customName = nil }
            }
            Button("Close Terminal…", role: .destructive) { isConfirmingClose = true }
        }
        .onChange(of: session.needsCloseConfirmation) {
            if session.needsCloseConfirmation {
                isConfirmingClose = true
                session.needsCloseConfirmation = false
            }
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

struct TerminalStatusDot: View {
    @ObservedObject var session: TerminalSession

    private var status: String {
        if session.hasExited { return "Exited" }
        guard let process = session.processStatus else { return "Status unavailable" }
        if process.isIdle { return "Idle" }
        return process.isRunning ? "Running" : "Stopped"
    }

    var body: some View {
        Circle()
            .fill(session.processStatus?.isRunning == true && !session.hasExited ? Color.green : Color.secondary.opacity(0.45))
            .frame(width: 5, height: 5)
            .help(status)
            .accessibilityLabel(status)
    }
}
