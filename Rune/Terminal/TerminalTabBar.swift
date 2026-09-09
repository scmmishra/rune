import AppKit
import SwiftUI

struct TerminalTabBar: View {
    @ObservedObject var sessions: TerminalSessions
    var showsShortcuts = false
    let onSelect: (TerminalSession) -> Void
    let onPeek: (TerminalSession) -> Void
    let onAdd: () -> Void
    let onClose: (TerminalSession) -> Void

    /// Total space the bar occupies inside the terminal panel, padding included, so
    /// tabbed sessions can be offset by exactly what the primary pane is.
    static let height: CGFloat = stripInset * 2 + WorkspaceMetrics.headerHeight
    /// Even margin on all four sides of the tab row.
    private static let stripInset: CGFloat = 6
    private static let barHeight: CGFloat = WorkspaceMetrics.headerHeight

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(Array(sessions.all.enumerated()), id: \.element.id) { index, session in
                        TerminalTab(
                            session: session,
                            isPrimary: session.id == sessions.primary.id,
                            shortcutNumber: index < 9 ? index + 1 : nil,
                            showsShortcut: showsShortcuts,
                            isSelected: session.id == sessions.navigation.panelID,
                            isPeeked: sessions.navigation.isPeeked(session.id),
                            isFocused: session.id == sessions.navigation.activeID,
                            onSelect: { onSelect(session) },
                            onPeek: { onPeek(session) },
                            onClose: { onClose(session) }
                        )
                        .id(session.id)
                    }
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                            .runeFont(size: 11)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(WorkspaceButtonStyle())
                    .help("New Terminal (⇧⌘T)")
                    .accessibilityLabel("New terminal")
                    .padding(.leading, 2)
                }
                .padding(.horizontal, 2)
                .frame(height: Self.barHeight)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(sessions.navigation.activeID) }
            .onChange(of: sessions.navigation.activeID) {
                proxy.scrollTo(sessions.navigation.activeID)
            }
        }
        .frame(height: Self.barHeight)
        .padding(Self.stripInset)
        // The strip reads as the panel's chrome rather than as part of the terminal
        // grid below it, without nesting a container inside a character grid.
        .background(Color.primary.opacity(0.03))
    }
}

private struct TerminalTab: View {
    // Fixed-width tabs keep the row on a steady rhythm; the bar scrolls once they overflow.
    private static let width: CGFloat = 140
    @ObservedObject var session: TerminalSession
    let isPrimary: Bool
    let shortcutNumber: Int?
    let showsShortcut: Bool
    let isSelected: Bool
    let isPeeked: Bool
    let isFocused: Bool
    let onSelect: () -> Void
    let onPeek: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false
    @State private var isConfirmingClose = false
    @State private var isRenaming = false
    @State private var draftName = ""

    private var title: String { isPrimary ? session.customName ?? "Terminal" : session.name }
    // The close affordance only appears on hover, so the slot stays reserved to keep titles still.
    private var showsClose: Bool { isHovered && !session.isStopping }

    var body: some View {
        Button(action: { NSEvent.modifierFlags.contains(.option) ? onPeek() : onSelect() }) {
            HStack(spacing: 6) {
                TerminalStatusDot(session: session)
                    .opacity(isSelected || isHovered ? 1 : 0.55)
                    .saturation(isSelected || isHovered ? 1 : 0.7)
                Text(title)
                    .runeFont(size: 11, weight: isSelected || isPeeked ? .medium : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected || isPeeked ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Spacer(minLength: 0)
                Color.clear.frame(width: 16, height: 16)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(width: Self.width, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .overlay(alignment: .trailing) {
            if let shortcutNumber, showsShortcut {
                Text("\(shortcutNumber)")
                    .runeFont(size: 9, weight: .semibold)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(.trailing, 5)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .trailing) {
            Button { isConfirmingClose = true } label: {
                Image(systemName: "xmark")
                    .runeFont(size: 9, weight: .medium)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .opacity(showsClose && !showsShortcut ? 1 : 0)
            .allowsHitTesting(showsClose)
            .accessibilityLabel("Close \(title)")
            .accessibilityHidden(!showsClose)
            .help("Close terminal…")
            .disabled(session.isStopping)
        }
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.09 : isHovered ? 0.055 : 0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    isPeeked ? Color.accentColor.opacity(isFocused ? 0.85 : 0.45)
                             : Color.primary.opacity(isSelected ? 0.12 : 0.05),
                    lineWidth: isPeeked ? 1.5 : 1
                )
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isPeeked)
        .animation(.easeOut(duration: 0.12), value: showsShortcut)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(shortcutNumber.map { "\(title) (⌘\($0), peek beside with ⌥⌘\($0))" } ?? title)
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
