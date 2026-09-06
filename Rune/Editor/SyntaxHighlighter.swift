import AppKit
import SwiftTreeSitter
import TreeSitterGo
import TreeSitterRuby
import TreeSitterSwift

nonisolated final class SyntaxHighlighter {
    static func baseAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
    }

    private let fileURL: URL
    private let font: NSFont
    private let treeSitterHighlighter: TreeSitterSyntaxHighlighter?

    init(fileURL: URL, font: NSFont) {
        self.fileURL = fileURL
        self.font = font
        treeSitterHighlighter = TreeSitterSyntaxHighlighter(fileURL: fileURL)
    }

    func highlight(_ source: String) -> NSAttributedString {
        let output = NSMutableAttributedString(
            string: source,
            attributes: Self.baseAttributes(font: font)
        )

        if treeSitterHighlighter?.apply(to: output, source: source) == true {
            return output
        }

        applyFallbackHighlighting(to: output, source: source)
        return output
    }

    private func applyFallbackHighlighting(
        to output: NSMutableAttributedString,
        source: String
    ) {
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        let language = FallbackLanguage(fileURL: fileURL)

        apply(language.keywords, color: .systemPink, to: output, range: fullRange)
        apply(#"\b(?:true|false|null|nil|self|Self)\b"#, color: .systemPurple, to: output, range: fullRange)
        apply(#"\b(?:0x[\dA-Fa-f]+|\d+(?:\.\d+)?)\b"#, color: .systemOrange, to: output, range: fullRange)
        apply(language.strings, color: .systemRed, to: output, range: fullRange)
        apply(
            language.comments,
            options: [.anchorsMatchLines, .dotMatchesLineSeparators],
            color: .systemGray,
            to: output,
            range: fullRange
        )

        if language == .markup {
            apply(#"(?m)^#{1,6}\s.*$"#, color: .systemBlue, to: output, range: fullRange)
            apply(#"`[^`]+`"#, color: .systemRed, to: output, range: fullRange)
        }
    }

    private func apply(
        _ pattern: String?,
        options: NSRegularExpression.Options = [],
        color: NSColor,
        to output: NSMutableAttributedString,
        range: NSRange
    ) {
        guard let pattern,
              let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return }

        for match in expression.matches(in: output.string, range: range) {
            output.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}

nonisolated enum DiffSyntaxHighlighter {
    static func highlight(_ source: String, font: NSFont) -> NSAttributedString {
        let output = NSMutableAttributedString(
            string: source,
            attributes: SyntaxHighlighter.baseAttributes(font: font)
        )
        let contents = source as NSString
        var location = 0

        while location < contents.length {
            let range = contents.lineRange(for: NSRange(location: location, length: 0))
            let line = contents.substring(with: range)
            let colors = colors(for: line)
            output.addAttribute(.foregroundColor, value: colors.foreground, range: range)
            if let background = colors.background {
                output.addAttribute(.backgroundColor, value: background, range: range)
            }
            location = NSMaxRange(range)
        }

        return output
    }

    private static func colors(for line: String) -> (foreground: NSColor, background: NSColor?) {
        if line.hasPrefix("@@") {
            return (.systemBlue, NSColor.systemBlue.withAlphaComponent(0.08))
        }
        if line.hasPrefix("+++") || line.hasPrefix("---") ||
            line.hasPrefix("diff ") || line.hasPrefix("index ") {
            return (.secondaryLabelColor, nil)
        }
        if line.hasPrefix("+") {
            return (.systemGreen, NSColor.systemGreen.withAlphaComponent(0.08))
        }
        if line.hasPrefix("-") {
            return (.systemRed, NSColor.systemRed.withAlphaComponent(0.08))
        }
        return (.labelColor, nil)
    }
}

nonisolated private final class TreeSitterSyntaxHighlighter {
    private let parser: Parser
    private let query: Query
    private var previousSource = ""
    private var previousTree: MutableTree?

    init?(fileURL: URL) {
        guard let configuration = TreeSitterLanguageRegistry.configuration(for: fileURL),
              let query = configuration.queries[.highlights] else { return nil }

        let parser = Parser()
        do {
            try parser.setLanguage(configuration.language)
        } catch {
            return nil
        }

        self.parser = parser
        self.query = query
    }

    func apply(to output: NSMutableAttributedString, source: String) -> Bool {
        if let previousTree {
            previousTree.edit(Self.edit(from: previousSource, to: source))
        }
        guard let tree = parser.parse(tree: previousTree, string: source) else {
            previousTree = nil
            return false
        }
        previousTree = tree
        previousSource = source

        // SwiftTreeSitter exposes query results as UTF-16 NSRanges, which match
        // NSTextStorage without manual byte-offset conversion.
        // Source: https://github.com/tree-sitter/swift-tree-sitter#range-translation
        let highlights = query
            .execute(in: tree)
            .resolve(with: .init(string: source))
            .highlights()

        for highlight in highlights {
            let range = highlight.range
            guard range.location != NSNotFound,
                  NSMaxRange(range) <= output.length,
                  let color = SyntaxColor.color(for: highlight.name) else { continue }

            output.addAttribute(.foregroundColor, value: color, range: range)
        }

        return true
    }

    private static func edit(from oldSource: String, to newSource: String) -> InputEdit {
        let old = Array(oldSource.utf16)
        let new = Array(newSource.utf16)
        var start = 0
        while start < min(old.count, new.count), old[start] == new[start] { start += 1 }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > start, newEnd > start, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        // The parser consumes UTF-16, so byte offsets and point columns use two bytes per code unit.
        func point(_ units: [UInt16], at end: Int) -> Point {
            var row = 0
            var lineStart = 0
            for index in 0..<end where units[index] == 10 {
                row += 1
                lineStart = index + 1
            }
            return Point(row: row, column: (end - lineStart) * 2)
        }
        return InputEdit(startByte: start * 2, oldEndByte: oldEnd * 2, newEndByte: newEnd * 2,
                         startPoint: point(old, at: start), oldEndPoint: point(old, at: oldEnd),
                         newEndPoint: point(new, at: newEnd))
    }
}

nonisolated private enum TreeSitterLanguageRegistry {
    static func configuration(for fileURL: URL) -> LanguageConfiguration? {
        switch fileURL.pathExtension.lowercased() {
        case "swift":
            try? LanguageConfiguration(tree_sitter_swift(), name: "Swift")
        case "rb", "rake", "gemspec":
            try? LanguageConfiguration(tree_sitter_ruby(), name: "Ruby")
        case "go":
            try? LanguageConfiguration(tree_sitter_go(), name: "Go")
        default:
            nil
        }
    }
}

nonisolated private enum SyntaxColor {
    static func color(for capture: String) -> NSColor? {
        if capture == "none" {
            return .labelColor
        }

        if capture.hasPrefix("variable.builtin") {
            return .systemPurple
        }

        guard let category = capture.split(separator: ".").first else { return nil }

        switch category {
        case "comment":
            return .systemGray
        case "keyword", "include", "preproc":
            return .systemPink
        case "string", "character":
            return .systemRed
        case "number", "float":
            return .systemOrange
        case "boolean", "constant":
            return .systemPurple
        case "function", "method":
            return .systemBlue
        case "type", "constructor":
            return .systemTeal
        case "property", "field", "attribute":
            return .systemCyan
        case "tag":
            return .systemPink
        case "label", "module", "namespace":
            return .systemIndigo
        case "markup":
            return .systemBlue
        case "operator", "punctuation":
            return .secondaryLabelColor
        case "error":
            return .systemRed
        default:
            return nil
        }
    }
}

nonisolated private enum FallbackLanguage: Equatable {
    case cStyle
    case hashComments
    case structuredData
    case markup
    case plain

    init(fileURL: URL) {
        switch fileURL.pathExtension.lowercased() {
        case "swift", "js", "jsx", "ts", "tsx", "c", "h", "cpp", "hpp", "m", "mm", "java", "kt", "rs", "go", "css":
            self = .cStyle
        case "py", "rb", "rake", "gemspec", "sh", "bash", "zsh", "fish", "yml", "yaml", "toml":
            self = .hashComments
        case "json", "jsonc", "plist":
            self = .structuredData
        case "md", "markdown":
            self = .markup
        default:
            self = .plain
        }
    }

    var keywords: String? {
        switch self {
        case .cStyle:
            #"\b(?:actor|async|await|break|case|catch|class|const|continue|default|defer|do|else|enum|extension|final|for|func|guard|if|import|in|interface|let|new|private|protocol|public|return|static|struct|switch|throw|throws|try|typealias|var|while)\b"#
        case .hashComments:
            #"\b(?:and|as|break|case|class|def|do|done|elif|else|elsif|end|except|export|fi|for|from|function|if|import|in|is|lambda|not|or|return|then|try|while|yield)\b"#
        case .structuredData, .markup, .plain:
            nil
        }
    }

    var strings: String? {
        switch self {
        case .cStyle, .hashComments, .structuredData:
            #"(?:\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*')"#
        case .markup, .plain:
            nil
        }
    }

    var comments: String? {
        switch self {
        case .cStyle:
            #"//.*$|/\*.*?\*/"#
        case .hashComments:
            #"#.*$"#
        case .structuredData, .markup, .plain:
            nil
        }
    }
}
