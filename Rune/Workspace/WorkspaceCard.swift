import SwiftUI

/// Names a card. A string, so cards Rune does not ship can be named in a saved layout later.
nonisolated struct WorkspaceCardID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    static let commands = WorkspaceCardID(rawValue: "commands")
    static let files = WorkspaceCardID(rawValue: "files")
    static let changes = WorkspaceCardID(rawValue: "changes")
    static let history = WorkspaceCardID(rawValue: "history")
    static let usage = WorkspaceCardID(rawValue: "usage")

    init(rawValue: String) { self.rawValue = rawValue }

    // Saved as a bare string, so a layout file reads `"cards": ["commands", "files"]`.
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// How a card takes height in its column.
nonisolated enum WorkspaceCardSizing: Equatable, Sendable {
    /// The height of its content, such as Usage.
    case fixed
    /// A share of the height the fixed cards leave, by weight, and never less than
    /// `minHeight` while the column has the room.
    case fill(minHeight: CGFloat, weight: CGFloat)
}

/// What the layout needs to know about a card. What the card draws is the workspace's business.
nonisolated struct WorkspaceCardDefinition: Identifiable, Sendable {
    let id: WorkspaceCardID
    let title: String
    let sizing: WorkspaceCardSizing

    static let builtIn: [WorkspaceCardDefinition] = [
        WorkspaceCardDefinition(id: .commands, title: "Commands", sizing: .fixed),
        WorkspaceCardDefinition(id: .files, title: "Files", sizing: .fill(minHeight: 160, weight: 1)),
        // Changes gets twice History's share, so staging or committing never moves history.
        WorkspaceCardDefinition(id: .changes, title: "Changes", sizing: .fill(minHeight: 200, weight: 2)),
        WorkspaceCardDefinition(id: .history, title: "History", sizing: .fill(minHeight: 120, weight: 1)),
        WorkspaceCardDefinition(id: .usage, title: "Usage", sizing: .fixed),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: builtIn.map { ($0.id, $0) })

    static func definition(for id: WorkspaceCardID) -> WorkspaceCardDefinition? { byID[id] }
}

nonisolated private struct WorkspaceCardSizingKey: LayoutValueKey {
    static let defaultValue = WorkspaceCardSizing.fixed
}

extension View {
    func workspaceCardSizing(_ sizing: WorkspaceCardSizing) -> some View {
        layoutValue(key: WorkspaceCardSizingKey.self, value: sizing)
    }
}

/// Stacks a column's cards with no gaps to fill: fixed cards take the height of their
/// content, and fill cards share what is left. A column of only fixed cards leaves its
/// spare room at the bottom, since stretching a fixed card would break its design.
struct WorkspaceCardColumnLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizings = subviews.map { $0[WorkspaceCardSizingKey.self] }
        let available = max(0, bounds.height - spacing * CGFloat(max(0, subviews.count - 1)))
        // Measure fixed cards once per pass; that is the only measuring a resize costs.
        let natural = zip(subviews, sizings).map { subview, sizing -> CGFloat? in
            guard sizing == .fixed else { return nil }
            return subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
        }
        let heights = Self.heights(sizings: sizings, natural: natural, available: available)
        var y = bounds.minY
        for (subview, height) in zip(subviews, heights) {
            subview.place(at: CGPoint(x: bounds.minX, y: y),
                          proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
    }

    /// The height of each card. `natural` holds the content height of the fixed ones.
    nonisolated static func heights(sizings: [WorkspaceCardSizing], natural: [CGFloat?], available: CGFloat) -> [CGFloat] {
        var heights = natural.map { $0 ?? 0 }
        // Fixed cards come first, but may not push the column past its own height.
        var remaining = available
        for index in heights.indices where sizings[index] == .fixed {
            heights[index] = min(heights[index], remaining)
            remaining -= heights[index]
        }
        var fills: [(index: Int, minHeight: CGFloat, weight: CGFloat)] = sizings.enumerated().compactMap { index, sizing in
            guard case let .fill(minHeight, weight) = sizing else { return nil }
            return (index, minHeight, max(weight, 0.01))
        }
        // Without room for every minimum, share by weight alone rather than overflow.
        if fills.reduce(0, { $0 + $1.minHeight }) > remaining {
            let total = fills.reduce(0) { $0 + $1.weight }
            for fill in fills { heights[fill.index] = max(0, remaining) * fill.weight / total }
            return heights
        }
        // A card whose share falls below its minimum takes the minimum; the rest share again.
        while !fills.isEmpty {
            let total = fills.reduce(0) { $0 + $1.weight }
            guard let short = fills.firstIndex(where: { remaining * $0.weight / total < $0.minHeight }) else {
                for fill in fills { heights[fill.index] = remaining * fill.weight / total }
                break
            }
            heights[fills[short].index] = fills[short].minHeight
            remaining -= fills[short].minHeight
            fills.remove(at: short)
        }
        return heights
    }
}
