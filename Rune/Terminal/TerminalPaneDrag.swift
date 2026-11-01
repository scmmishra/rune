import SwiftUI

/// What a pane draws differently while a drag moves it.
struct TerminalPanePreview: Equatable {
    /// How much bigger or smaller the pane's slot is than the pane.
    var growth = CGSize.zero
    var isLifted = false
}

extension EnvironmentValues {
    @Entry var terminalPanePreview = TerminalPanePreview()
}

/// A pane's outline with its bottom and trailing edges moved by `growth`.
///
/// A drop resizes each terminal once, then panes slide to their places by transform, because
/// every resize makes an agent's TUI redraw. Until a pane arrives, this outline keeps the size
/// it had: a terminal that grew is cropped to it, and one that shrank has the room filled.
nonisolated struct TerminalPaneShape: InsettableShape {
    var top: CGFloat
    var bottom: CGFloat
    var growth = CGSize.zero
    private var inset: CGFloat = 0

    init(top: CGFloat, bottom: CGFloat, growth: CGSize = .zero) {
        self.top = top
        self.bottom = bottom
        self.growth = growth
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(growth.width, growth.height) }
        set { growth = CGSize(width: newValue.first, height: newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        let outline = CGRect(x: rect.minX, y: rect.minY, width: max(0, rect.width + growth.width),
                             height: max(0, rect.height + growth.height)).insetBy(dx: inset, dy: inset)
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom,
                                      topTrailingRadius: top, style: .continuous).path(in: outline)
    }

    func inset(by amount: CGFloat) -> TerminalPaneShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// One pane drag: the pane under the pointer, and where it would land.
///
/// Panes watch this object themselves, so the workspace's body does not run on every mouse
/// move. Nothing but the carried pane moves until the drop.
@MainActor
final class TerminalPaneDrag: ObservableObject {
    /// Where a pane shows while it settles, relative to its place in the layout.
    struct Slot: Equatable {
        var offset = CGSize.zero
        var growth = CGSize.zero
    }

    /// The carried pane's transform, drawn from its top leading corner.
    struct Carry: Equatable {
        var scale = CGSize(width: 1, height: 1)
        var offset = CGSize.zero
    }

    static let liftAnimation = Animation.snappy(duration: 0.18)
    static let settleAnimation = Animation.snappy(duration: 0.24)
    /// A carried pane never takes more than this part of the tab, so the landing highlight
    /// stays in sight around it.
    private static let carriedLimit: CGFloat = 0.3
    private static let liftScale: CGFloat = 0.92

    /// The pane being carried or settling into its place.
    @Published private(set) var pane: UUID?
    @Published private(set) var carry = Carry()
    @Published private(set) var slots: [UUID: Slot] = [:]
    /// Where the pane was picked up, which stays outlined until the drop.
    @Published private(set) var origin: CGRect?
    /// Where the pane would land. Nil when the drop would change nothing.
    @Published private(set) var landing: CGRect?
    private(set) var isActive = false

    private var tab: TerminalTab?
    private var area = CGRect.zero
    private var gap: CGFloat = 0
    private var frames: [UUID: CGRect] = [:]
    private var grab = CGPoint.zero
    private var scale: CGFloat = 1
    private var drop: TerminalPaneDrop?
    /// Where a cancelled drag started. Escape ends the drag with the button still down, and
    /// the same gesture keeps reporting moves that must not start a new drag.
    private var cancelledStart: CGPoint?

    /// False when this gesture was cancelled and has not ended yet.
    func canBegin(from start: CGPoint) -> Bool {
        if cancelledStart == start { return false }
        cancelledStart = nil
        return true
    }

    func begin(_ pane: UUID, tab: TerminalTab, area: CGRect, gap: CGFloat, grab: CGPoint, travel: CGSize) {
        let frames = tab.layout(in: area, gap: gap).frames
        guard let frame = frames[pane], frame.width > 0, frame.height > 0 else { return }
        self.pane = pane
        self.tab = tab
        self.area = area
        self.gap = gap
        self.frames = frames
        self.grab = grab
        scale = min(Self.liftScale, Self.carriedLimit * area.width / frame.width,
                    Self.carriedLimit * area.height / frame.height)
        isActive = true
        origin = frame
        withAnimation(Self.liftAnimation) { carry = carrying(by: travel, from: frame) }
    }

    func move(to point: CGPoint, travel: CGSize) {
        guard isActive, let pane, let tab, let frame = frames[pane] else { return }
        carry = carrying(by: travel, from: frame)
        let target = tab.drop(for: pane, at: point, in: area, gap: gap, headerHeight: TerminalDrawer.paneHeaderHeight)
        guard target != drop else { return }
        drop = target
        landing = landingFrames()?[pane]
    }

    /// Frames after the drop, or nil when the drop would change nothing.
    private func landingFrames() -> [UUID: CGRect]? {
        guard let pane, let tab, let drop,
              let landing = tab.frames(moving: pane, to: drop, in: area, gap: gap),
              landing != frames else { return nil }
        return landing
    }

    /// The carried pane is scaled about the grab point, so the header stays under the
    /// pointer, then held inside the tab.
    private func carrying(by travel: CGSize, from frame: CGRect) -> Carry {
        let width = frame.width * scale
        let height = frame.height * scale
        let x = grab.x + (frame.minX - grab.x) * scale + travel.width
        let y = grab.y + (frame.minY - grab.y) * scale + travel.height
        let clampedX = min(max(x, area.minX), max(area.minX, area.maxX - width))
        let clampedY = min(max(y, area.minY), max(area.minY, area.maxY - height))
        return Carry(scale: CGSize(width: scale, height: scale),
                     offset: CGSize(width: clampedX - frame.minX, height: clampedY - frame.minY))
    }

    /// Stops the drag and returns the drop to apply, if it changes anything.
    func finish() -> TerminalPaneDrop? {
        guard isActive else { return nil }
        isActive = false
        origin = nil
        landing = nil
        return landingFrames() == nil ? nil : drop
    }

    /// Re-expresses every pane against its new place, so nothing moves on screen yet. Call
    /// in the transaction that moves the pane.
    func land() {
        guard let pane, let frame = frames[pane], let landed = landingFrames(),
              let target = landed[pane], target.width > 0, target.height > 0 else { return }
        let x = frame.minX + carry.offset.width
        let y = frame.minY + carry.offset.height
        carry = Carry(scale: CGSize(width: frame.width * scale / target.width, height: frame.height * scale / target.height),
                      offset: CGSize(width: x - target.minX, height: y - target.minY))
        var slots: [UUID: Slot] = [:]
        for (id, place) in landed where id != pane {
            guard let start = frames[id] else { continue }
            slots[id] = Slot(offset: CGSize(width: start.minX - place.minX, height: start.minY - place.minY),
                             growth: CGSize(width: start.width - place.width, height: start.height - place.height))
        }
        self.slots = slots
    }

    /// Brings every pane to rest at its place in the layout.
    func settle() {
        slots = [:]
        carry = Carry()
    }

    /// Clears the finished drag once its pane has settled.
    func clear() {
        guard !isActive else { return }
        pane = nil
        tab = nil
        drop = nil
        frames = [:]
    }

    func cancel() {
        isActive = false
        origin = nil
        landing = nil
        drop = nil
        cancelledStart = grab
    }

    func gestureEnded() { cancelledStart = nil }
}

/// Moves a pane for a drag. The transforms and the shape are visual only, so they never
/// resize the terminal. They are always applied, because adding a modifier
/// partway through a drag would change the surface's identity and rebuild its PTY.
struct TerminalPaneDragEffect: ViewModifier {
    @ObservedObject var drag: TerminalPaneDrag
    let id: UUID

    func body(content: Content) -> some View {
        let isCarried = drag.pane == id
        let slot = drag.slots[id] ?? TerminalPaneDrag.Slot()
        content
            .environment(\.terminalPanePreview, TerminalPanePreview(growth: slot.growth, isLifted: isCarried))
            .scaleEffect(isCarried ? drag.carry.scale : CGSize(width: 1, height: 1), anchor: .topLeading)
            .offset(isCarried ? drag.carry.offset : slot.offset)
    }
}

/// What a pane drag draws over the hub: a hollow shell where the pane was picked up, and a
/// highlight where it would land.
struct TerminalPaneDragOverlay: View {
    @ObservedObject var drag: TerminalPaneDrag

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let origin = drag.origin {
                RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .frame(width: origin.width, height: origin.height)
                    .offset(x: origin.minX, y: origin.minY)
                    .transition(.opacity)
            }
            if let landing = drag.landing {
                RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.1))
                    .overlay {
                        RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.28), lineWidth: 1)
                    }
                    .frame(width: landing.width, height: landing.height)
                    .offset(x: landing.minX, y: landing.minY)
                    .transition(.opacity)
            }
        }
        // One animation for the highlight, so it glides between targets and fades at the ends.
        .animation(.snappy(duration: 0.12), value: drag.landing)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
