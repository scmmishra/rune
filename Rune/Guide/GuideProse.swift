import SwiftUI

struct GuideProse: View {
    let text: String
    let references: [GuideSnapshot.Reference]
    let onOpenReference: (GuideSnapshot.Reference) -> Void
    @Environment(\.runeTypography) private var typography

    var body: some View {
        Text(styledText)
            .runeFont(size: 13)
            .lineSpacing(5)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "rune-brief", url.host == "reference",
                      let reference = references.first(where: { $0.id == url.lastPathComponent }) else {
                    return .discarded
                }
                onOpenReference(reference)
                return .handled
            })
    }

    private var styledText: AttributedString {
        var result = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        for run in result.runs {
            // Only captured reference IDs become links; never open agent-supplied URLs.
            result[run.range].link = nil
            if run.inlinePresentationIntent?.contains(.code) == true {
                result[run.range].foregroundColor = Color.blue.opacity(0.8)
                result[run.range].backgroundColor = Color.blue.opacity(0.06)
                result[run.range].font = .system(size: typography.size(relativeTo: 13), design: .monospaced)
            }
        }
        GuideReferenceLinks.apply(to: &result, validIDs: Set(references.map(\.id)))
        return result
    }
}

// Match rendered text so references also work inside parentheses, code spans, and older cached briefs.
enum GuideReferenceLinks {
    private static let pattern = try! NSRegularExpression(pattern: #"\bf[0-9]+(?:h[0-9]+)?\b"#)

    static func apply(to text: inout AttributedString, validIDs: Set<String>) {
        let plain = String(text.characters)
        for match in pattern.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let range = Range(match.range, in: plain) else { continue }
            let identifier = String(plain[range])
            guard validIDs.contains(identifier),
                  let start = AttributedString.Index(range.lowerBound, within: text),
                  let end = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[start..<end].link = URL(string: "rune-brief://reference/" + identifier)
            text[start..<end].foregroundColor = .accentColor
            text[start..<end].underlineStyle = .single
        }
    }
}
