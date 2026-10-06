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

nonisolated private struct WorkspaceCardIDKey: LayoutValueKey {
    static let defaultValue: WorkspaceCardID? = nil
}

extension View {
    /// Names the card for `WorkspaceCardsLayout`, which looks up its place and sizing by it.
    func workspaceCard(_ id: WorkspaceCardID) -> some View {
        layoutValue(key: WorkspaceCardIDKey.self, value: id)
    }
}

/// Places every card of the workspace, column by column. One layout holds them all, so a
/// card keeps its view, and its state, when it moves to another column.
///
/// Within a column there are no gaps to fill: fixed cards take the height of their content,
/// and fill cards share what is left. A column of only fixed cards leaves its spare room at
/// the bottom, since stretching a fixed card would break its design.
struct WorkspaceCardsLayout: Layout {
    var slots: [WorkspaceArrangement.Slot]
    /// The band the columns occupy, in the layout's own coordinates.
    var top: CGFloat
    var height: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var placed: Set<WorkspaceCardID> = []
        for slot in slots {
            let cards = slot.cards.compactMap { id in subviews.first { $0[WorkspaceCardIDKey.self] == id } }
            let sizings = slot.cards.map { WorkspaceCardDefinition.definition(for: $0)?.sizing ?? .fixed }
            guard cards.count == sizings.count else { continue }
            let available = max(0, height - spacing * CGFloat(max(0, cards.count - 1)))
            // Measure fixed cards once per pass; that is the only measuring a resize costs.
            let natural = zip(cards, sizings).map { card, sizing -> CGFloat? in
                guard sizing == .fixed else { return nil }
                return card.sizeThatFits(ProposedViewSize(width: slot.width, height: nil)).height
            }
            let heights = Self.heights(sizings: sizings, natural: natural, available: available)
            var y = bounds.minY + top
            for (card, cardHeight) in zip(cards, heights) {
                card.place(at: CGPoint(x: bounds.minX + slot.x, y: y),
                           proposal: ProposedViewSize(width: slot.width, height: cardHeight))
                y += cardHeight + spacing
            }
            placed.formUnion(slot.cards)
        }
        // Cards of a collapsed column stay alive off screen, ready for when it returns.
        for subview in subviews {
            guard let id = subview[WorkspaceCardIDKey.self], !placed.contains(id) else { continue }
            subview.place(at: CGPoint(x: bounds.minX - 10_000, y: bounds.minY), proposal: .zero)
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
