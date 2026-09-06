import Foundation

nonisolated enum TerminalAgent: String, CaseIterable {
    case claude = "Claude Code"
    case codex = "Codex"
    case openCode = "OpenCode"
    case pi = "Pi"

    private static let titlePattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_./\\-])(claude(?: code)?|codex|opencode|pi)(?![\p{L}\p{N}_./\\-])"#,
        options: [.caseInsensitive]
    )

    static func detect(in title: String) -> TerminalAgent? {
        // Titles are only hints. Ignore names embedded in paths/words, and
        // ambiguous titles mentioning multiple agents rather than guessing.
        let matches = titlePattern.matches(in: title, range: NSRange(title.startIndex..., in: title))
        let agents = Set(matches.compactMap { match -> TerminalAgent? in
            guard let range = Range(match.range(at: 1), in: title) else { return nil }
            switch title[range].lowercased() {
            case "claude", "claude code": return .claude
            case "codex": return .codex
            case "opencode": return .openCode
            case "pi": return .pi
            default: return nil
            }
        })
        return agents.count == 1 ? agents.first : nil
    }
}
