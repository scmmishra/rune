import Combine
import CryptoKit
import Foundation

/// One column of cards, top to bottom.
nonisolated struct WorkspaceColumn: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var width: CGFloat
    var cards: [WorkspaceCardID]

    static let defaultWidth: CGFloat = 240
    static let minWidth: CGFloat = 160
}

/// How a space arranges its cards around the hub. The hub is not a column here: its place
/// is the seam between `leading` and `trailing`, so it always exists exactly once.
nonisolated struct WorkspaceLayout: Codable, Equatable, Sendable {
    /// Card columns left of the hub, left to right.
    var leading: [WorkspaceColumn]
    /// Card columns right of the hub, left to right.
    var trailing: [WorkspaceColumn]

    static let standard = WorkspaceLayout(
        leading: [WorkspaceColumn(width: WorkspaceColumn.defaultWidth, cards: [.commands, .files])],
        trailing: [WorkspaceColumn(width: WorkspaceColumn.defaultWidth, cards: [.changes, .history, .usage])]
    )

    enum Side: Equatable, Sendable { case leading, trailing }

    /// Where a card can be put.
    enum Destination: Equatable, Sendable {
        /// Into an existing column, before the card at `index`.
        case column(UUID, index: Int)
        /// Into a column of its own, before the column at `index` on that side of the hub.
        case newColumn(Side, index: Int)
    }

    var columns: [WorkspaceColumn] { leading + trailing }
    var cards: [WorkspaceCardID] { columns.flatMap(\.cards) }
    /// Built-in cards the layout leaves out.
    var hidden: [WorkspaceCardID] {
        let shown = Set(cards)
        return WorkspaceCardDefinition.builtIn.map(\.id).filter { !shown.contains($0) }
    }

    /// Moves a card, or shows a hidden one. A column left empty goes away.
    mutating func place(_ card: WorkspaceCardID, at destination: Destination) {
        switch destination {
        case let .column(id, index):
            // Taking the card out first shifts the cards after it up by one.
            let from = column(id)?.cards.firstIndex(of: card)
            let index = from.map { index > $0 ? index - 1 : index } ?? index
            removeCard(card)
            update(id) { $0.cards.insert(card, at: min(max(index, 0), $0.cards.count)) }
        case let .newColumn(side, index):
            removeCard(card)
            let column = WorkspaceColumn(width: WorkspaceColumn.defaultWidth, cards: [card])
            switch side {
            case .leading: leading.insert(column, at: min(max(index, 0), leading.count))
            case .trailing: trailing.insert(column, at: min(max(index, 0), trailing.count))
            }
        }
        pruneEmptyColumns()
    }

    mutating func hide(_ card: WorkspaceCardID) {
        removeCard(card)
        pruneEmptyColumns()
    }

    mutating func setWidth(_ width: CGFloat, ofColumn id: UUID) {
        update(id) { $0.width = max(WorkspaceColumn.minWidth, width) }
    }

    private func column(_ id: UUID) -> WorkspaceColumn? { columns.first { $0.id == id } }

    private mutating func update(_ id: UUID, _ change: (inout WorkspaceColumn) -> Void) {
        if let index = leading.firstIndex(where: { $0.id == id }) { change(&leading[index]) }
        if let index = trailing.firstIndex(where: { $0.id == id }) { change(&trailing[index]) }
    }

    private mutating func removeCard(_ card: WorkspaceCardID) {
        for index in leading.indices { leading[index].cards.removeAll { $0 == card } }
        for index in trailing.indices { trailing[index].cards.removeAll { $0 == card } }
    }

    private mutating func pruneEmptyColumns() {
        leading.removeAll(where: \.cards.isEmpty)
        trailing.removeAll(where: \.cards.isEmpty)
    }

    /// A layout that came from a file: no card twice, no card Rune cannot draw, no empty
    /// or duplicate column, and no width below the minimum.
    var normalized: WorkspaceLayout {
        var seenCards: Set<WorkspaceCardID> = []
        var seenColumns: Set<UUID> = []
        func clean(_ columns: [WorkspaceColumn]) -> [WorkspaceColumn] {
            columns.compactMap { column in
                guard seenColumns.insert(column.id).inserted else { return nil }
                var column = column
                column.cards = column.cards.filter {
                    WorkspaceCardDefinition.definition(for: $0) != nil && seenCards.insert($0).inserted
                }
                column.width = max(WorkspaceColumn.minWidth, column.width)
                return column.cards.isEmpty ? nil : column
            }
        }
        return WorkspaceLayout(leading: clean(leading), trailing: clean(trailing))
    }
}

/// A layout resolved against a window width: where each column and the hub sit.
nonisolated struct WorkspaceArrangement: Equatable, Sendable {
    struct Slot: Identifiable, Equatable, Sendable {
        let id: UUID
        let side: WorkspaceLayout.Side
        let cards: [WorkspaceCardID]
        let x: CGFloat
        let width: CGFloat
    }

    let slots: [Slot]
    let hubX: CGFloat
    let hubWidth: CGFloat
    /// Columns the window has no room for. The hub is never one of them.
    let collapsed: [UUID]
}

nonisolated extension WorkspaceLayout {
    /// The most of the window one card column may take.
    private static let maxColumnShare: CGFloat = 0.28
    /// The hub's guaranteed width, and its share of a window too narrow for that.
    private static let hubMinWidth: CGFloat = 480
    private static let hubMinShare: CGFloat = 0.40

    /// Places the columns and the hub across `width`. Card columns that would leave the hub
    /// less than its minimum collapse, outermost first, so the hub always stays whole.
    func arrangement(in width: CGFloat, margin: CGFloat, gap: CGFloat) -> WorkspaceArrangement {
        let maxColumn = max(WorkspaceColumn.minWidth, width * Self.maxColumnShare)
        let hubMin = min(Self.hubMinWidth, width * Self.hubMinShare)
        func fitted(_ column: WorkspaceColumn) -> CGFloat { min(max(column.width, WorkspaceColumn.minWidth), maxColumn) }

        var leading = leading
        var trailing = trailing
        var collapsed: [UUID] = []
        func used() -> CGFloat { (leading + trailing).reduce(margin * 2) { $0 + fitted($1) + gap } }
        while used() + hubMin > width, !(leading.isEmpty && trailing.isEmpty) {
            // The side holding more columns gives one up; the far right goes first on a tie.
            if leading.count > trailing.count {
                collapsed.append(leading.removeFirst().id)
            } else {
                collapsed.append(trailing.removeLast().id)
            }
        }

        var slots: [WorkspaceArrangement.Slot] = []
        var x = margin
        for column in leading {
            slots.append(.init(id: column.id, side: .leading, cards: column.cards, x: x, width: fitted(column)))
            x += fitted(column) + gap
        }
        let hubX = x
        let trailingWidth = trailing.reduce(0) { $0 + fitted($1) + gap }
        let hubWidth = max(0, width - margin - hubX - trailingWidth)
        x = hubX + hubWidth + gap
        for column in trailing {
            slots.append(.init(id: column.id, side: .trailing, cards: column.cards, x: x, width: fitted(column)))
            x += fitted(column) + gap
        }
        return WorkspaceArrangement(slots: slots, hubX: hubX, hubWidth: hubWidth, collapsed: collapsed)
    }
}

/// Where a dragged card would land, and the line that shows it.
nonisolated struct WorkspaceDropTarget: Equatable, Sendable {
    let destination: WorkspaceLayout.Destination
    let marker: CGRect
}

nonisolated extension WorkspaceLayout {
    /// How close to a column's side edge a drop makes a new column beside it.
    private static let edgeZone: CGFloat = 28
    private static let markerThickness: CGFloat = 2

    /// The drop a pointer position stands for. Nil when it would leave the card where it is.
    ///
    /// The middle of a column drops into it, between the cards nearest the pointer. A
    /// column's side edges, either half of the hub, and the window's margins make a new column.
    func dropTarget(for card: WorkspaceCardID, at point: CGPoint, arrangement: WorkspaceArrangement,
                    cardFrames: [WorkspaceCardID: CGRect], top: CGFloat, height: CGFloat,
                    width: CGFloat, gap: CGFloat) -> WorkspaceDropTarget? {
        func newColumn(_ side: Side, _ index: Int, x: CGFloat) -> WorkspaceDropTarget? {
            // A card alone in its column gains nothing from a new column beside that one.
            let columns = side == .leading ? leading : trailing
            if let own = columns.firstIndex(where: { $0.cards == [card] }), index == own || index == own + 1 { return nil }
            let marker = CGRect(x: x - Self.markerThickness / 2, y: top, width: Self.markerThickness, height: height)
            return WorkspaceDropTarget(destination: .newColumn(side, index: index), marker: marker)
        }

        if let slot = arrangement.slots.first(where: { point.x >= $0.x - gap / 2 && point.x < $0.x + $0.width + gap / 2 }) {
            let columns = slot.side == .leading ? leading : trailing
            guard let columnIndex = columns.firstIndex(where: { $0.id == slot.id }) else { return nil }
            if point.x < slot.x + Self.edgeZone { return newColumn(slot.side, columnIndex, x: slot.x - gap / 2) }
            if point.x > slot.x + slot.width - Self.edgeZone {
                return newColumn(slot.side, columnIndex + 1, x: slot.x + slot.width + gap / 2)
            }
            // Into the column, before the first card whose middle is below the pointer.
            let frames = slot.cards.map { cardFrames[$0] ?? .zero }
            let index = frames.firstIndex { point.y < $0.midY } ?? slot.cards.count
            if let own = slot.cards.firstIndex(of: card), index == own || index == own + 1 { return nil }
            let y = index < frames.count ? frames[index].minY - gap / 2 : (frames.last?.maxY ?? top) + gap / 2
            let marker = CGRect(x: slot.x, y: y - Self.markerThickness / 2, width: slot.width, height: Self.markerThickness)
            return WorkspaceDropTarget(destination: .column(slot.id, index: index), marker: marker)
        }
        if point.x >= arrangement.hubX, point.x < arrangement.hubX + arrangement.hubWidth {
            // Either half of the hub makes a column right beside it.
            return point.x < arrangement.hubX + arrangement.hubWidth / 2
                ? newColumn(.leading, leading.count, x: arrangement.hubX - gap / 2)
                : newColumn(.trailing, 0, x: arrangement.hubX + arrangement.hubWidth + gap / 2)
        }
        return point.x < arrangement.hubX
            ? newColumn(.leading, 0, x: gap / 2)
            : newColumn(.trailing, trailing.count, x: width - gap / 2)
    }
}

/// A card drag in progress. The workspace holds it without observing it, so the pointer's
/// every move redraws only the dragged card and the overlay, not the whole window.
@MainActor
final class WorkspaceCardDrag: ObservableObject {
    @Published private(set) var card: WorkspaceCardID?
    /// How far the pointer has carried the card from where it was picked up.
    @Published private(set) var translation = CGSize.zero
    /// Where the card was picked up, which stays outlined until it is dropped.
    @Published private(set) var origin: CGRect?
    @Published private(set) var target: WorkspaceDropTarget?
    /// Where each card sits in its column, kept current by the cards themselves.
    var cardFrames: [WorkspaceCardID: CGRect] = [:]

    var isActive: Bool { card != nil }

    func begin(_ card: WorkspaceCardID) {
        self.card = card
        origin = cardFrames[card]
    }

    func move(by translation: CGSize, target: WorkspaceDropTarget?) {
        self.translation = translation
        if self.target != target { self.target = target }
    }

    /// Ends the drag and returns where the card was dropped, if anywhere.
    func end() -> WorkspaceDropTarget? {
        defer {
            card = nil
            translation = .zero
            origin = nil
            target = nil
        }
        return target
    }
}

/// Reads and writes a space's configuration. A file in the repository wins over the one in
/// the home folder, so a team can share one arrangement.
nonisolated enum WorkspaceLayoutStore {
    private struct SpaceFile: Codable {
        var version = 1
        var layout: WorkspaceLayout
    }

    static func repositoryFile(for root: URL) -> URL { root.appending(path: ".rune/space.json") }

    /// `~/.rune/spaces/<folder>-<hash>.json`: the folder name to recognise it by, and a hash
    /// of the full path to keep two checkouts of one name apart.
    static func homeFile(for root: URL) -> URL {
        let path = root.resolvingSymlinksInPath().standardizedFileURL.path
        let hash = SHA256.hash(data: Data(path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".rune/spaces/\(root.lastPathComponent)-\(hash).json")
    }

    static func isSavedInRepository(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: repositoryFile(for: root).path)
    }

    static func load(for root: URL) -> WorkspaceLayout {
        for file in [repositoryFile(for: root), homeFile(for: root)] {
            guard let data = try? Data(contentsOf: file),
                  let space = try? JSONDecoder().decode(SpaceFile.self, from: data) else { continue }
            let layout = space.layout.normalized
            // A file that names no card Rune knows would leave only the hub.
            if !layout.cards.isEmpty { return layout }
        }
        return migratedStandard(for: root)
    }

    /// Saves to whichever file `load` reads: the repository's if it has one, else the home folder's.
    static func save(_ layout: WorkspaceLayout, for root: URL) {
        try? write(layout, to: isSavedInRepository(root) ? repositoryFile(for: root) : homeFile(for: root))
    }

    static func saveToRepository(_ layout: WorkspaceLayout, for root: URL) throws {
        try write(layout, to: repositoryFile(for: root))
    }

    private static func write(_ layout: WorkspaceLayout, to file: URL) throws {
        let encoder = JSONEncoder()
        // Stable, readable output: the repository's copy is reviewed in diffs.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(SpaceFile(layout: layout)).write(to: file, options: .atomic)
    }

    /// The standard layout, at the sidebar widths saved before layouts were files.
    private static func migratedStandard(for root: URL) -> WorkspaceLayout {
        var layout = WorkspaceLayout.standard
        if let widths = UserDefaults.standard.array(forKey: "sidebarWidths:" + root.path) as? [Double], widths.count == 2 {
            layout.setWidth(CGFloat(widths[0]), ofColumn: layout.leading[0].id)
            layout.setWidth(CGFloat(widths[1]), ofColumn: layout.trailing[0].id)
        }
        return layout
    }
}

/// The layout of one workspace window, loaded once and saved as it changes.
@MainActor
final class WorkspaceLayoutModel: ObservableObject {
    @Published private(set) var layout: WorkspaceLayout
    private let root: URL?

    init(root: URL?) {
        self.root = root
        layout = root.map(WorkspaceLayoutStore.load) ?? .standard
    }

    /// Changes the layout without saving, for the steps of a drag.
    func update(_ change: (inout WorkspaceLayout) -> Void) { change(&layout) }

    func save() {
        guard let root else { return }
        let layout = layout
        Task.detached(priority: .utility) { WorkspaceLayoutStore.save(layout, for: root) }
    }

    /// Writes the layout into the repository, where it then wins over the home folder's copy.
    func saveToRepository() throws {
        guard let root else { return }
        try WorkspaceLayoutStore.saveToRepository(layout, for: root)
    }
}
