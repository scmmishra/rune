import SwiftUI

/// What a pane draws differently while another pane's drag moves it.
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
/// A drag moves panes without resizing their terminals, because a resize makes an agent's
/// TUI redraw. A pane heading for a smaller slot crops to it. In a bigger slot, the same
/// outline fills the extra room behind the terminal.
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

/// One pane drag: the pane under the pointer, and where the others would land.
///
/// Panes watch this object themselves, so the workspace's body does not run on every mouse
/// move. Terminals keep their sizes until the drop, which moves them once.
@MainActor
final class TerminalPaneDrag: ObservableObject {
    /// Where a pane sits during a drag, relative to its place in the layout.
    struct Slot: Equatable {
        var offset = CGSize.zero
        var growth = CGSize.zero
    }

    /// The carried pane's transform, drawn from its top leading corner.
    struct Carry: Equatable {
        var scale = CGSize(width: 1, height: 1)
        var offset = CGSize.zero
    }

    static let slideAnimation = Animation.snappy(duration: 0.22)
    static let settleAnimation = Animation.snappy(duration: 0.24)
    /// A carried pane never takes more than this part of the tab, so the panes making room
    /// stay in sight, and a tall pane can travel vertically inside the tab.
    private static let carriedLimit: CGFloat = 0.6
    private static let liftScale: CGFloat = 0.92
    /// A target has to hold this long, so panes stay put while the pointer passes over them.
    private static let dwell: Duration = .milliseconds(80)

    /// The pane being carried or settling into its place.
    @Published private(set) var pane: UUID?
    @Published private(set) var carry = Carry()
    @Published private(set) var slots: [UUID: Slot] = [:]
    private(set) var isActive = false

    private var tab: TerminalTab?
    private var area = CGRect.zero
    private var gap: CGFloat = 0
    private var frames: [UUID: CGRect] = [:]
    private var grab = CGPoint.zero
    private var scale: CGFloat = 1
    private var drop: TerminalPaneDrop?
    private var dwellTask: Task<Void, Never>?
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
        withAnimation(Self.slideAnimation) { carry = carrying(by: travel, from: frame) }
    }

    func move(to point: CGPoint, travel: CGSize) {
        guard isActive, let pane, let tab, let frame = frames[pane] else { return }
        carry = carrying(by: travel, from: frame)
        let target = tab.drop(for: pane, at: point, travel: travel, in: area, gap: gap)
        guard target != drop else { return }
        drop = target
        dwellTask?.cancel()
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dwell)
            guard !Task.isCancelled else { return }
            self?.showDrop()
        }
    }

    /// Slides the panes to where the current drop would put them.
    private func showDrop() {
        let landing = landingFrames()
        withAnimation(Self.slideAnimation) { slots = landing.map(makeSlots) ?? [:] }
    }

    /// Frames after the drop, or nil when the drop would change nothing.
    private func landingFrames() -> [UUID: CGRect]? {
        guard let pane, let tab, let drop,
              let landing = tab.frames(moving: pane, to: drop, in: area, gap: gap),
              landing != frames else { return nil }
        return landing
    }

    private func makeSlots(_ landing: [UUID: CGRect]) -> [UUID: Slot] {
        var slots: [UUID: Slot] = [:]
        for (id, target) in landing where id != pane {
            guard let frame = frames[id] else { continue }
            slots[id] = Slot(offset: CGSize(width: target.minX - frame.minX, height: target.minY - frame.minY),
                             growth: CGSize(width: target.width - frame.width, height: target.height - frame.height))
        }
        return slots
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
        dwellTask?.cancel()
        return landingFrames() == nil ? nil : drop
    }

    /// Re-expresses the carried pane against its new place, so it stays where it is on
    /// screen. Call in the transaction that moves the pane.
    func land() {
        guard let pane, let frame = frames[pane], let drop, let tab,
              let target = tab.frames(moving: pane, to: drop, in: area, gap: gap)?[pane],
              target.width > 0, target.height > 0 else { return }
        let x = frame.minX + carry.offset.width
        let y = frame.minY + carry.offset.height
        carry = Carry(scale: CGSize(width: frame.width * scale / target.width, height: frame.height * scale / target.height),
                      offset: CGSize(width: x - target.minX, height: y - target.minY))
        slots = [:]
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
        dwellTask?.cancel()
        drop = nil
        cancelledStart = grab
    }

    func gestureEnded() { cancelledStart = nil }
}

/// Moves a pane for a drag. The transforms and the shape are visual only, so the terminal
/// keeps its grid until the drop. They are always applied, because adding a modifier
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
