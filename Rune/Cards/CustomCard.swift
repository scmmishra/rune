import Foundation

/// A card the user defined: one TOML file in `~/.rune/cards`, named by its file.
nonisolated struct CustomCard: Identifiable, Equatable, Sendable {
    /// Where a card's content comes from.
    enum Source: Equatable, Sendable {
        /// Bash, written inline in the card file.
        case script(String)
        /// An executable, in any language.
        case file(URL)
    }

    let id: WorkspaceCardID
    let fileURL: URL
    var title: String
    /// How often the source runs again. Nil runs it only on demand.
    var refresh: Duration?
    var sizing = WorkspaceCardSizing.fill(minHeight: 120, weight: 1)
    /// The variables the source is bound to: it gets their values, and runs again when one changes.
    var reads: [String] = []
    var source: Source?
    /// Why the file could not be used; the card shows it in place of items.
    var problem: String?

    /// Cards live only in the home folder, so every card is one the user put there.
    static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".rune/cards") }

    /// A source that runs more often than this would keep a slow command running back to back.
    private static let shortestRefresh = 5.0

    var definition: WorkspaceCardDefinition { WorkspaceCardDefinition(id: id, title: title, sizing: sizing) }

    /// Every card file, by title. A file named like a built-in card is left out.
    static func loadAll() -> [CustomCard] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "toml" }
            .map(load)
            .filter { WorkspaceCardDefinition.builtIn(for: $0.id) == nil }
            .sorted { ($0.title.lowercased(), $0.id.rawValue) < ($1.title.lowercased(), $1.id.rawValue) }
    }

    static func load(_ fileURL: URL) -> CustomCard {
        let name = fileURL.deletingPathExtension().lastPathComponent
        var card = CustomCard(id: WorkspaceCardID(rawValue: name), fileURL: fileURL, title: name)
        do {
            let file = try TOMLParser.parse(try String(contentsOf: fileURL, encoding: .utf8))
            try card.apply(file)
        } catch {
            card.problem = error.localizedDescription
        }
        return card
    }

    private struct Invalid: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private mutating func apply(_ file: JSONValue) throws {
        if let value = file["title"] {
            guard let title = value.string, !title.isEmpty else { throw Invalid("title must be text.") }
            self.title = title
        }
        if let value = file["refresh"] {
            guard let seconds = value.number, seconds > 0 else { throw Invalid("refresh must be a number of seconds.") }
            refresh = .seconds(max(seconds, Self.shortestRefresh))
        }
        if let value = file["sizing"] {
            switch value.string {
            case "fixed": sizing = .fixed
            case "fill": break
            default: throw Invalid("sizing must be \"fixed\" or \"fill\".")
            }
        }
        if let value = file["reads"] {
            guard let names = value.array?.map(\.string), !names.contains(nil) else {
                throw Invalid("reads must be a list of variable names.")
            }
            reads = names.compactMap { $0 }
            if let bad = reads.first(where: { !SpaceVariables.isValidName($0) }) {
                throw Invalid("\(bad) is not a variable name. Use letters, digits and underscores.")
            }
        }
        guard let text = file["source"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw Invalid("source is missing. Give it a script, or the path of an executable.")
        }
        source = Self.source(from: text, relativeTo: fileURL.deletingLastPathComponent())
    }

    /// One line that starts like a path names an executable; anything else is a script.
    private static func source(from text: String, relativeTo directory: URL) -> Source {
        guard !text.contains(where: \.isNewline), !text.contains(" ") else { return .script(text) }
        if text.hasPrefix("~/") {
            return .file(FileManager.default.homeDirectoryForCurrentUser.appending(path: String(text.dropFirst(2))))
        }
        if text.hasPrefix("/") { return .file(URL(fileURLWithPath: text)) }
        if text.hasPrefix("./") || text.hasPrefix("../") { return .file(directory.appending(path: text).standardizedFileURL) }
        return .script(text)
    }
}

/// The custom cards on disk, shared by every window.
@MainActor
final class CustomCardCatalog: ObservableObject {
    static let shared = CustomCardCatalog()

    @Published private(set) var cards: [CustomCard] = []

    func card(_ id: WorkspaceCardID) -> CustomCard? { cards.first { $0.id == id } }

    /// Reads the card files again. Called when a window opens, when a palette opens, and
    /// from a card's own refresh button, so an edited file takes effect without a watcher.
    func reload() {
        let loaded = CustomCard.loadAll()
        if loaded != cards { cards = loaded }
    }
}

/// Named values of one window's space, such as the conversation picked in a list. A card's
/// action sets them; sources bound to them run again.
@MainActor
final class SpaceVariables: ObservableObject {
    @Published private(set) var values: [String: String] = [:]

    func set(_ changes: [String: String]) {
        let next = values.merging(changes.filter { Self.isValidName($0.key) }) { _, new in new }
        if next != values { values = next }
    }

    /// A name has to survive becoming an environment variable.
    nonisolated static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}
