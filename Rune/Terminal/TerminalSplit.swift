import CoreGraphics
import Foundation

nonisolated enum TerminalSplitAxis: Equatable, Sendable {
    /// Panes side by side.
    case columns
    /// Panes stacked.
    case rows
}

/// What a pane shortcut asks for. Offsets are -1, 0 or 1 on each axis.
nonisolated enum TerminalPaneAction: Equatable, Sendable {
    case split(TerminalSplitAxis)
    case zoom
    case focus(dx: Int, dy: Int)
    case resize(dx: Int, dy: Int)
    case equalize
    case close
}

/// The gap between two panes, which drags to resize them.
nonisolated struct TerminalSplitDivider: Identifiable, Equatable, Sendable {
    let id: UUID
    let axis: TerminalSplitAxis
    let ratio: CGFloat
    let frame: CGRect
    /// The length the two sides share, so a drag distance converts to a ratio.
    let extent: CGFloat
}

/// A pane, or two nodes sharing a rectangle.
nonisolated indirect enum TerminalSplitNode: Equatable, Sendable {
    case pane(UUID)
    /// `ratio` is the first node's share of the room.
    case split(id: UUID, axis: TerminalSplitAxis, ratio: CGFloat, first: TerminalSplitNode, second: TerminalSplitNode)

    static let ratioRange: ClosedRange<CGFloat> = 0.1...0.9
    private static let resizeStep: CGFloat = 0.05

    /// Panes in reading order: left to right, top to bottom.
    var paneIDs: [UUID] {
        switch self {
        case let .pane(id): [id]
        case let .split(_, _, _, first, second): first.paneIDs + second.paneIDs
        }
    }

    func contains(_ paneID: UUID) -> Bool {
        switch self {
        case let .pane(id): id == paneID
        case let .split(_, _, _, first, second): first.contains(paneID) || second.contains(paneID)
        }
    }

    /// Puts a new pane after `paneID`, sharing its room equally.
    func splitting(_ paneID: UUID, axis: TerminalSplitAxis, adding newID: UUID) -> TerminalSplitNode {
        switch self {
        case let .pane(id):
            guard id == paneID else { return self }
            return .split(id: UUID(), axis: axis, ratio: 0.5, first: self, second: .pane(newID))
        case let .split(id, splitAxis, ratio, first, second):
            return .split(id: id, axis: splitAxis, ratio: ratio,
                          first: first.splitting(paneID, axis: axis, adding: newID),
                          second: second.splitting(paneID, axis: axis, adding: newID))
        }
    }

    /// Removes a pane; its sibling takes the room they shared. Nil when nothing is left.
    func removing(_ paneID: UUID) -> TerminalSplitNode? {
        switch self {
        case let .pane(id):
            return id == paneID ? nil : self
        case let .split(id, axis, ratio, first, second):
            guard let first = first.removing(paneID) else { return second }
            guard let second = second.removing(paneID) else { return first }
            return .split(id: id, axis: axis, ratio: ratio, first: first, second: second)
        }
    }

    func settingRatio(_ newRatio: CGFloat, ofSplit splitID: UUID) -> TerminalSplitNode {
        guard case let .split(id, axis, ratio, first, second) = self else { return self }
        if id == splitID {
            return .split(id: id, axis: axis, ratio: newRatio.clamped(to: Self.ratioRange), first: first, second: second)
        }
        return .split(id: id, axis: axis, ratio: ratio,
                      first: first.settingRatio(newRatio, ofSplit: splitID),
                      second: second.settingRatio(newRatio, ofSplit: splitID))
    }

    /// Moves the nearest divider around `paneID` on `axis` one step. Nil when the pane has
    /// no divider on that axis.
    func resizing(_ paneID: UUID, axis: TerminalSplitAxis, direction: Int) -> TerminalSplitNode? {
        guard case let .split(id, splitAxis, ratio, first, second) = self else { return nil }
        let inFirst = first.contains(paneID)
        guard inFirst || second.contains(paneID) else { return nil }
        // Deeper splits are nearer the pane, so they get the first chance.
        if let inner = (inFirst ? first : second).resizing(paneID, axis: axis, direction: direction) {
            return .split(id: id, axis: splitAxis, ratio: ratio,
                          first: inFirst ? inner : first, second: inFirst ? second : inner)
        }
        guard splitAxis == axis else { return nil }
        let moved = (ratio + CGFloat(direction) * Self.resizeStep).clamped(to: Self.ratioRange)
        return .split(id: id, axis: splitAxis, ratio: moved, first: first, second: second)
    }

    /// Gives every pane on a line the same share.
    func equalized() -> TerminalSplitNode { equalizedCounting().node }

    private func equalizedCounting() -> (node: TerminalSplitNode, columns: Int, rows: Int) {
        guard case let .split(id, axis, _, first, second) = self else { return (self, 1, 1) }
        let a = first.equalizedCounting()
        let b = second.equalizedCounting()
        switch axis {
        case .columns:
            let ratio = CGFloat(a.columns) / CGFloat(a.columns + b.columns)
            return (.split(id: id, axis: axis, ratio: ratio, first: a.node, second: b.node),
                    a.columns + b.columns, max(a.rows, b.rows))
        case .rows:
            let ratio = CGFloat(a.rows) / CGFloat(a.rows + b.rows)
            return (.split(id: id, axis: axis, ratio: ratio, first: a.node, second: b.node),
                    max(a.columns, b.columns), a.rows + b.rows)
        }
    }

    func layout(in rect: CGRect, gap: CGFloat) -> (frames: [UUID: CGRect], dividers: [TerminalSplitDivider]) {
        var frames: [UUID: CGRect] = [:]
        var dividers: [TerminalSplitDivider] = []
        place(in: rect, gap: gap, frames: &frames, dividers: &dividers)
        return (frames, dividers)
    }

    private func place(in rect: CGRect, gap: CGFloat, frames: inout [UUID: CGRect],
                       dividers: inout [TerminalSplitDivider]) {
        switch self {
        case let .pane(id):
            frames[id] = rect
        case let .split(id, axis, ratio, first, second):
            let length = axis == .columns ? rect.width : rect.height
            let extent = max(0, length - gap)
            // Whole points keep the terminal grids on pixel boundaries.
            let firstLength = (extent * ratio).rounded()
            let slices: (CGRect, CGRect, CGRect)
            switch axis {
            case .columns:
                slices = (CGRect(x: rect.minX, y: rect.minY, width: firstLength, height: rect.height),
                          CGRect(x: rect.minX + firstLength, y: rect.minY, width: gap, height: rect.height),
                          CGRect(x: rect.minX + firstLength + gap, y: rect.minY,
                                 width: extent - firstLength, height: rect.height))
            case .rows:
                slices = (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstLength),
                          CGRect(x: rect.minX, y: rect.minY + firstLength, width: rect.width, height: gap),
                          CGRect(x: rect.minX, y: rect.minY + firstLength + gap,
                                 width: rect.width, height: extent - firstLength))
            }
            first.place(in: slices.0, gap: gap, frames: &frames, dividers: &dividers)
            dividers.append(TerminalSplitDivider(id: id, axis: axis, ratio: ratio, frame: slices.1, extent: extent))
            second.place(in: slices.2, gap: gap, frames: &frames, dividers: &dividers)
        }
    }
}

/// One tab of the terminal panel: panes in a tree of splits.
nonisolated struct TerminalTab: Identifiable, Equatable, Sendable {
    /// Stable for the tab's life, whichever panes come and go. Navigation knows a tab by it.
    let id: UUID
    private(set) var root: TerminalSplitNode
    private(set) var focusedID: UUID
    /// The pane filling the tab over the others, when one does.
    private(set) var zoomedID: UUID?
    /// Panes by when they last had focus, latest first: closing one returns to the one before.
    private var recentIDs: [UUID]

    init(id: UUID, paneID: UUID) {
        self.id = id
        root = .pane(paneID)
        focusedID = paneID
        recentIDs = [paneID]
    }

    var paneIDs: [UUID] { root.paneIDs }
    var isSplit: Bool { if case .split = root { true } else { false } }
    func contains(_ paneID: UUID) -> Bool { root.contains(paneID) }

    /// The focused pane's tile leads; at most two more show behind it.
    var tileIDs: [UUID] { [focusedID] + paneIDs.filter { $0 != focusedID }.prefix(2) }

    /// How many cards show stacked under the zoomed pane.
    var stackDepth: Int { zoomedID == nil ? 0 : min(2, paneIDs.count - 1) }

    /// Whether a pane is on screen while its tab is: zoom hides the others.
    func shows(_ paneID: UUID) -> Bool { zoomedID == nil || zoomedID == paneID }

    mutating func focus(_ paneID: UUID) {
        guard contains(paneID) else { return }
        focusedID = paneID
        recentIDs.removeAll { $0 == paneID }
        recentIDs.insert(paneID, at: 0)
        // Focus moving to a pane under the zoomed one has to show it.
        if let zoomedID, zoomedID != paneID { self.zoomedID = nil }
    }

    mutating func split(_ axis: TerminalSplitAxis, adding newID: UUID) {
        root = root.splitting(focusedID, axis: axis, adding: newID)
        zoomedID = nil
        focus(newID)
    }

    /// Returns false when `paneID` is the tab's only pane, which the caller closes with the tab.
    mutating func close(_ paneID: UUID) -> Bool {
        guard isSplit, let remaining = root.removing(paneID) else { return false }
        root = remaining
        recentIDs.removeAll { $0 == paneID }
        if zoomedID == paneID { zoomedID = nil }
        if focusedID == paneID { focusedID = recentIDs.first ?? remaining.paneIDs[0] }
        return true
    }

    mutating func toggleZoom() {
        zoomedID = zoomedID == nil && isSplit ? focusedID : nil
    }

    mutating func setRatio(_ ratio: CGFloat, ofSplit splitID: UUID) {
        root = root.settingRatio(ratio, ofSplit: splitID)
    }

    mutating func resize(dx: Int, dy: Int) {
        guard let resized = root.resizing(focusedID, axis: dx != 0 ? .columns : .rows,
                                          direction: dx != 0 ? dx : dy) else { return }
        root = resized
    }

    mutating func equalize() { root = root.equalized() }

    /// Where each pane sits. A zoomed pane takes the area, less `stackInset` at the top for
    /// the edges of the cards under it; the rest keep their places underneath, so their
    /// terminals are not resized while hidden.
    func layout(in area: CGRect, gap: CGFloat, stackInset: CGFloat = 0)
        -> (frames: [UUID: CGRect], dividers: [TerminalSplitDivider]) {
        var layout = root.layout(in: area, gap: gap)
        if let zoomedID {
            let inset = min(stackInset, area.height)
            layout.frames[zoomedID] = CGRect(x: area.minX, y: area.minY + inset,
                                             width: area.width, height: area.height - inset)
            layout.dividers = []
        }
        return layout
    }

    /// The pane next to the focused one toward (dx, dy): the nearest, then the one most in
    /// line with the focused pane's centre.
    func neighbor(dx: Int, dy: Int) -> UUID? {
        guard zoomedID == nil else { return nil }
        let frames = root.layout(in: CGRect(x: 0, y: 0, width: 1000, height: 1000), gap: 0).frames
        guard let from = frames[focusedID] else { return nil }
        var best: (id: UUID, score: CGFloat)?
        for (id, frame) in frames where id != focusedID {
            let distance: CGFloat
            let overlap: CGFloat
            let offset: CGFloat
            if dx != 0 {
                distance = dx > 0 ? frame.minX - from.maxX : from.minX - frame.maxX
                overlap = min(frame.maxY, from.maxY) - max(frame.minY, from.minY)
                offset = abs(frame.midY - from.midY)
            } else {
                distance = dy > 0 ? frame.minY - from.maxY : from.minY - frame.maxY
                overlap = min(frame.maxX, from.maxX) - max(frame.minX, from.minX)
                offset = abs(frame.midX - from.midX)
            }
            guard distance > -1, overlap > 0 else { continue }
            let score = distance * 4 + offset
            if best == nil || score < best!.score { best = (id, score) }
        }
        return best?.id
    }
}

private nonisolated extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
