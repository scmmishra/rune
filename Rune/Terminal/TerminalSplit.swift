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

/// The gap between two neighbouring nodes of a split, which drags to resize them.
nonisolated struct TerminalSplitDivider: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let splitID: UUID
        /// The divider follows the split's child at this index.
        let index: Int
    }

    let id: ID
    let axis: TerminalSplitAxis
    /// The first neighbour's share of the room the two neighbours share.
    let ratio: CGFloat
    let frame: CGRect
    /// The length the two neighbours share, so a drag distance converts to a ratio.
    let extent: CGFloat
}

/// One node of a split, with its part of the split's length.
nonisolated struct TerminalSplitChild: Equatable, Sendable {
    var node: TerminalSplitNode
    /// The shares of a split's children add up to 1.
    var share: CGFloat
}

/// A pane, or nodes side by side or stacked, sharing a rectangle.
///
/// A split never holds a split on its own axis. The panes of one row are siblings of one
/// split, so a row of three is 1:1:1 rather than one half and two quarters, and a divider
/// resizes only the two panes beside it.
nonisolated enum TerminalSplitNode: Equatable, Sendable {
    case pane(UUID)
    case split(id: UUID, axis: TerminalSplitAxis, children: [TerminalSplitChild])

    /// Two neighbours each keep at least this part of the room they share.
    static let ratioRange: ClosedRange<CGFloat> = 0.1...0.9
    private static let resizeStep: CGFloat = 0.05

    /// Panes in reading order: left to right, top to bottom.
    var paneIDs: [UUID] {
        switch self {
        case let .pane(id): [id]
        case let .split(_, _, children): children.flatMap(\.node.paneIDs)
        }
    }

    func contains(_ paneID: UUID) -> Bool {
        switch self {
        case let .pane(id): id == paneID
        case let .split(_, _, children): children.contains { $0.node.contains(paneID) }
        }
    }

    /// Puts a new pane after `paneID`. Along the axis of the split that holds the pane, the
    /// new pane joins that row or column with an equal share, and the others shrink in
    /// proportion, so sizes set by hand keep their relation. Across it, the pane's own room
    /// is halved.
    func splitting(_ paneID: UUID, axis: TerminalSplitAxis, adding newID: UUID) -> TerminalSplitNode {
        switch self {
        case let .pane(id):
            guard id == paneID else { return self }
            return .split(id: UUID(), axis: axis, children: [
                TerminalSplitChild(node: self, share: 0.5),
                TerminalSplitChild(node: .pane(newID), share: 0.5),
            ])
        case let .split(id, splitAxis, children):
            if splitAxis == axis, let index = children.firstIndex(where: { $0.node == .pane(paneID) }) {
                let count = CGFloat(children.count)
                var resized = children.map { TerminalSplitChild(node: $0.node, share: $0.share * count / (count + 1)) }
                resized.insert(TerminalSplitChild(node: .pane(newID), share: 1 / (count + 1)), at: index + 1)
                return .split(id: id, axis: splitAxis, children: resized)
            }
            return .split(id: id, axis: splitAxis, children: children.map {
                TerminalSplitChild(node: $0.node.splitting(paneID, axis: axis, adding: newID), share: $0.share)
            })
        }
    }

    /// Removes a pane. The rest of its row or column take back its room in proportion, and
    /// a split left with one node becomes that node. Nil when nothing is left.
    func removing(_ paneID: UUID) -> TerminalSplitNode? {
        switch self {
        case let .pane(id):
            return id == paneID ? nil : self
        case let .split(id, axis, children):
            guard contains(paneID) else { return self }
            var remaining: [TerminalSplitChild] = []
            for child in children {
                guard let node = child.node.removing(paneID) else { continue }
                // A nested split that collapsed to one on this split's axis joins its siblings
                // here, so a row never holds a row.
                if case let .split(_, nestedAxis, nested) = node, nestedAxis == axis {
                    remaining += nested.map { TerminalSplitChild(node: $0.node, share: $0.share * child.share) }
                } else {
                    remaining.append(TerminalSplitChild(node: node, share: child.share))
                }
            }
            if remaining.count <= 1 { return remaining.first?.node }
            let total = remaining.reduce(0) { $0 + $1.share }
            return .split(id: id, axis: axis, children: remaining.map {
                TerminalSplitChild(node: $0.node, share: $0.share / total)
            })
        }
    }

    /// Sets the first neighbour's share of the room the divider's two neighbours share.
    func settingRatio(_ ratio: CGFloat, of dividerID: TerminalSplitDivider.ID) -> TerminalSplitNode {
        guard case let .split(id, axis, children) = self else { return self }
        guard id == dividerID.splitID else {
            return .split(id: id, axis: axis, children: children.map {
                TerminalSplitChild(node: $0.node.settingRatio(ratio, of: dividerID), share: $0.share)
            })
        }
        let index = dividerID.index
        guard children.indices.contains(index + 1) else { return self }
        var resized = children
        let pair = children[index].share + children[index + 1].share
        let clamped = ratio.clamped(to: Self.ratioRange)
        resized[index].share = pair * clamped
        resized[index + 1].share = pair * (1 - clamped)
        return .split(id: id, axis: axis, children: resized)
    }

    /// Moves the nearest divider beside `paneID` on `axis` one step: the one after it, or the
    /// one before it at the end of a row. Nil when the pane has no divider on that axis.
    func resizing(_ paneID: UUID, axis: TerminalSplitAxis, direction: Int) -> TerminalSplitNode? {
        guard case let .split(id, splitAxis, children) = self,
              let index = children.firstIndex(where: { $0.node.contains(paneID) }) else { return nil }
        // Deeper splits are nearer the pane, so they get the first chance.
        if let inner = children[index].node.resizing(paneID, axis: axis, direction: direction) {
            var updated = children
            updated[index].node = inner
            return .split(id: id, axis: splitAxis, children: updated)
        }
        guard splitAxis == axis else { return nil }
        let dividerIndex = min(index, children.count - 2)
        let pair = children[dividerIndex].share + children[dividerIndex + 1].share
        let ratio = children[dividerIndex].share / pair + CGFloat(direction) * Self.resizeStep
        return settingRatio(ratio, of: TerminalSplitDivider.ID(splitID: id, index: dividerIndex))
    }

    /// Gives every pane on a line the same share.
    func equalized() -> TerminalSplitNode { equalizedCounting().node }

    private func equalizedCounting() -> (node: TerminalSplitNode, columns: Int, rows: Int) {
        guard case let .split(id, axis, children) = self else { return (self, 1, 1) }
        let counted = children.map { $0.node.equalizedCounting() }
        let along = counted.map { axis == .columns ? $0.columns : $0.rows }
        let total = along.reduce(0, +)
        let node = TerminalSplitNode.split(id: id, axis: axis, children: zip(counted, along).map {
            TerminalSplitChild(node: $0.node, share: CGFloat($1) / CGFloat(total))
        })
        let columns = axis == .columns ? total : counted.map(\.columns).max() ?? 1
        let rows = axis == .rows ? total : counted.map(\.rows).max() ?? 1
        return (node, columns, rows)
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
        case let .split(id, axis, children):
            let length = axis == .columns ? rect.width : rect.height
            let extent = max(0, length - gap * CGFloat(children.count - 1))
            var start: CGFloat = 0
            var cumulative: CGFloat = 0
            for (index, child) in children.enumerated() {
                cumulative += child.share
                // Whole points keep the terminal grids on pixel boundaries. Rounding the running
                // total rather than each length keeps the last node flush with the edge.
                let end = index == children.count - 1 ? extent : (extent * cumulative).rounded()
                let offset = start + gap * CGFloat(index)
                child.node.place(in: Self.slice(of: rect, axis: axis, at: offset, length: end - start),
                                 gap: gap, frames: &frames, dividers: &dividers)
                if index + 1 < children.count {
                    let pair = child.share + children[index + 1].share
                    dividers.append(TerminalSplitDivider(
                        id: TerminalSplitDivider.ID(splitID: id, index: index), axis: axis,
                        ratio: child.share / pair,
                        frame: Self.slice(of: rect, axis: axis, at: offset + end - start, length: gap),
                        extent: extent * pair
                    ))
                }
                start = end
            }
        }
    }

    private static func slice(of rect: CGRect, axis: TerminalSplitAxis, at offset: CGFloat, length: CGFloat) -> CGRect {
        switch axis {
        case .columns: CGRect(x: rect.minX + offset, y: rect.minY, width: length, height: rect.height)
        case .rows: CGRect(x: rect.minX, y: rect.minY + offset, width: rect.width, height: length)
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

    mutating func setRatio(_ ratio: CGFloat, of dividerID: TerminalSplitDivider.ID) {
        root = root.settingRatio(ratio, of: dividerID)
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
