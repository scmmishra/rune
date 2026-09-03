import AppKit

enum SyntaxHighlighter {
    static let editorFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: editorFont,
            .foregroundColor: NSColor.labelColor
        ]
    }

    static func highlight(_ source: String, fileURL: URL) -> NSAttributedString {
        let output = NSMutableAttributedString(string: source, attributes: baseAttributes)
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let language = Language(fileURL: fileURL)

        apply(language.keywords, color: .systemPink, to: output, range: fullRange)
        apply(#"\b(?:true|false|null|nil|self|Self)\b"#, color: .systemPurple, to: output, range: fullRange)
        apply(#"\b(?:0x[\dA-Fa-f]+|\d+(?:\.\d+)?)\b"#, color: .systemOrange, to: output, range: fullRange)
        apply(language.strings, color: .systemRed, to: output, range: fullRange)
        apply(language.comments, options: [.anchorsMatchLines, .dotMatchesLineSeparators], color: .systemGray, to: output, range: fullRange)

        if language == .markup {
            apply(#"(?m)^#{1,6}\s.*$"#, color: .systemBlue, to: output, range: fullRange)
            apply(#"`[^`]+`"#, color: .systemRed, to: output, range: fullRange)
        }

        return output
    }

    private static func apply(
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

    private enum Language: Equatable {
        case cStyle
        case hashComments
        case structuredData
        case markup
        case plain

        init(fileURL: URL) {
            switch fileURL.pathExtension.lowercased() {
            case "swift", "js", "jsx", "ts", "tsx", "c", "h", "cpp", "hpp", "m", "mm", "java", "kt", "rs", "go", "css":
                self = .cStyle
            case "py", "rb", "sh", "bash", "zsh", "fish", "yml", "yaml", "toml":
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
}
