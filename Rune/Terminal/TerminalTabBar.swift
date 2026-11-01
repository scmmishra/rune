import AppKit
import SwiftUI

struct TerminalTabBar: View {
    @ObservedObject var sessions: TerminalSessions
    var showsShortcuts = false
    let onSelect: (TerminalSession) -> Void
    let onPeek: (TerminalSession) -> Void
    let onAdd: () -> Void
    let onClose: (TerminalSession) -> Void

    /// Total space the bar occupies inside the terminal panel, padding included.
    static let height: CGFloat = WorkspaceMetrics.bandHeight
    /// Even margin on all four sides of the tab row.
    private static let stripInset: CGFloat = (height - WorkspaceMetrics.headerHeight) / 2
    private static let barHeight: CGFloat = WorkspaceMetrics.headerHeight
    private static let tabSpacing: CGFloat = 4
    /// From one tab's place to the next. Tabs have a fixed width, so a drag's distance
    /// converts to a place in the row.
    private static let tabStep: CGFloat = TerminalTabItem.width + tabSpacing
    private static let tabMoveAnimation = Animation.snappy(duration: 0.18)

    /// The tab being dragged, with how far it has come and the place it would take. The
    /// tab row itself changes only on the drop, so a neighbour's move never fights the drag.
    @State private var draggedTabID: UUID?
    @State private var dragTravel: CGFloat = 0
    @State private var dragTarget = 0
    /// The dragged tab is on its way to its place, so the gesture no longer steers it.
    @State private var isDropping = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: Self.tabSpacing) {
                    ForEach(Array(sessions.tabs.enumerated()), id: \.element.id) { index, tab in
                        // A tab stands for its focused pane: its name, its status, and where
                        // selecting or peeking the tab goes.
                        if let session = sessions.session(tab.focusedID) {
                            TerminalTabItem(
                                session: session,
                                // A pane waiting in the background speaks for the whole tab.
                                status: sessions.waitingPane(in: tab) ?? session,
                                tiles: tab.tileIDs.compactMap { sessions.session($0) },
                                isOnlyTerminal: sessions.isOnlyTerminal(session),
                                isSplit: tab.isSplit,
                                shortcutNumber: index < 9 ? index + 1 : nil,
                                showsShortcut: showsShortcuts,
                                isSelected: tab.id == sessions.navigation.panelID,
                                isPeeked: sessions.navigation.isPeeked(tab.id),
                                isFocused: tab.id == sessions.navigation.activeID,
                                onSelect: { onSelect(session) },
                                onPeek: { onPeek(session) },
                                onClose: { onClose(session) },
                                closesWithoutConfirmation: {
                                    tab.paneIDs.compactMap { sessions.session($0) }.allSatisfy(\.closesWithoutConfirmation)
                                }
                            )
                            .id(tab.id)
                            .offset(x: tabOffset(at: index))
                            .zIndex(tab.id == draggedTabID ? 1 : 0)
                            // Beside the tab's button, so a click still selects it.
                            .simultaneousGesture(
                                // Global, because the tab moves under the pointer during the drag.
                                DragGesture(minimumDistance: 6, coordinateSpace: .global)
                                    .onChanged { dragTab(tab.id, from: index, by: $0.translation.width) }
                                    .onEnded { _ in dropTab(tab.id, from: index) }
                            )
                        }
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
        // A tab opened or closed during a drag leaves its places out of date.
        .onChange(of: sessions.tabs.map(\.id)) { resetTabDrag() }
    }

    /// How far a tab shows from its place: the dragged one with the pointer, and the tabs it
    /// has passed one place the other way.
    private func tabOffset(at index: Int) -> CGFloat {
        guard let draggedTabID, let start = sessions.tabs.firstIndex(where: { $0.id == draggedTabID }) else { return 0 }
        if index == start { return dragTravel }
        if start < index, index <= dragTarget { return -Self.tabStep }
        if dragTarget <= index, index < start { return Self.tabStep }
        return 0
    }

    private func dragTab(_ id: UUID, from start: Int, by distance: CGFloat) {
        guard !isDropping, draggedTabID == nil || draggedTabID == id else { return }
        let last = sessions.tabs.count - 1
        guard last > 0 else { return }
        if draggedTabID == nil {
            draggedTabID = id
            dragTarget = start
        }
        // Held to the row of tabs, so a tab cannot be dragged past either end.
        dragTravel = min(max(distance, -CGFloat(start) * Self.tabStep), CGFloat(last - start) * Self.tabStep)
        let target = start + Int((dragTravel / Self.tabStep).rounded())
        if target != dragTarget { withAnimation(Self.tabMoveAnimation) { dragTarget = target } }
    }

    private func dropTab(_ id: UUID, from start: Int) {
        guard draggedTabID == id, !isDropping else { return }
        isDropping = true
        let target = dragTarget
        withAnimation(Self.tabMoveAnimation) {
            dragTravel = CGFloat(target - start) * Self.tabStep
        } completion: {
            // Every tab already shows at its new place, so this changes nothing on screen.
            sessions.moveTab(id, to: target)
            resetTabDrag()
        }
    }

    private func resetTabDrag() {
        draggedTabID = nil
        dragTravel = 0
        isDropping = false
    }
}

private struct TerminalTabItem: View {
    // Fixed-width tabs keep the row on a steady rhythm; the bar scrolls once they overflow.
    static let width: CGFloat = 140
    @ObservedObject var session: TerminalSession
    /// The pane whose state the tab's dot shows: one that is waiting, else the focused one.
    @ObservedObject var status: TerminalSession
    /// The tab's panes as tiles, the focused one first.
    let tiles: [TerminalSession]
    let isOnlyTerminal: Bool
    let isSplit: Bool
    let shortcutNumber: Int?
    let showsShortcut: Bool
    let isSelected: Bool
    let isPeeked: Bool
    let isFocused: Bool
    let onSelect: () -> Void
    let onPeek: () -> Void
    let onClose: () -> Void
    /// Asked when the close is clicked, so it reflects what the panes run at that moment.
    let closesWithoutConfirmation: () -> Bool
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isConfirmingClose = false
    @State private var isRenaming = false
    @State private var draftName = ""

    private var title: String { session.name }
    // The close affordance replaces the status dot on hover, so titles stay still.
    private var showsClose: Bool { isHovered && !session.isStopping }

    var body: some View {
        Button(action: { NSEvent.modifierFlags.contains(.option) ? onPeek() : onSelect() }) {
            HStack(spacing: 6) {
                TerminalProcessTileStack(sessions: tiles)
                Text(title)
                    .runeFont(size: 11, weight: isSelected || isPeeked ? .medium : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected || isPeeked ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Spacer(minLength: 0)
                // The status dot shares the trailing slot with the close button and shortcut badge.
                TerminalStatusDot(session: status)
                    .frame(width: 16, height: 16)
                    .opacity(showsClose || showsShortcut ? 0 : isSelected || status.needsAttention ? 1 : 0.55)
                    .saturation(isSelected || status.needsAttention ? 1 : 0.7)
            }
            .padding(.leading, 6)
            .padding(.trailing, 6)
            .frame(width: Self.width, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // One nudge when a terminal asks for you, and the dot stays amber until you visit.
        .phaseAnimator([0, -3, 3, -2, 0], trigger: status.attentionCount) { view, offset in
            view.offset(x: reduceMotion ? 0 : offset)
        } animation: { _ in .spring(duration: 0.09) }
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
            Button(action: requestClose) {
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
            .help(isSplit ? "Close tab…" : "Close terminal…")
            .disabled(session.isStopping)
        }
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.08 : isHovered ? 0.045 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    isPeeked ? AnyShapeStyle(ThemeColor.accent.opacity(isFocused ? 0.85 : 0.45))
                             : AnyShapeStyle(Color.primary.opacity(isSelected ? 0.08 : 0)),
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
            Button(isSplit ? "Close Tab…" : "Close Terminal…", role: .destructive, action: requestClose)
                .disabled(session.isStopping)
        }
        .alert(isSplit ? "Close this tab?" : "Close \(title)?", isPresented: $isConfirmingClose) {
            Button("Cancel", role: .cancel) {}
            Button(isSplit ? "Close Tab" : "Close Terminal", role: .destructive, action: onClose)
        } message: {
            Text(isSplit
                 ? "This ends the running processes in every pane of the tab."
                 : isOnlyTerminal
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

    private func requestClose() {
        if closesWithoutConfirmation() { onClose() } else { isConfirmingClose = true }
    }
}
