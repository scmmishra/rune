import AppKit
import SwiftUI

extension URL {
    var isMarkdown: Bool {
        ["md", "markdown", "mdown", "mkd"].contains(pathExtension.lowercased())
    }
}

/// A read-only rendering of a Markdown file, with Mermaid code blocks drawn as diagrams.
struct MarkdownPreview: View {
    let text: String
    @State private var blocks: [MarkdownBlock] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(blocks) { block in
                    MarkdownBlockView(block: block)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            // Only web and mail links leave Rune; relative links have nowhere to go.
            guard ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
            return .systemAction
        })
        .task(id: text) {
            let text = text
            blocks = await Task.detached(priority: .userInitiated) { MarkdownDocument.blocks(from: text) }.value
        }
    }
}

nonisolated struct MarkdownBlock: Identifiable, Sendable {
    enum Kind: Sendable {
        case heading(Int)
        case paragraph
        case code(language: String?)
        case rule
        case table(rows: [[AttributedString]])
    }

    let id: Int
    var kind: Kind
    var text: AttributedString
    /// The bullet or number, on the first paragraph of a list item only.
    var marker: String?
    var listDepth = 0
    var quoteDepth = 0
}

/// Groups Foundation's CommonMark parse into blocks. Each block's runs share one
/// presentation intent, so no second Markdown parser is needed.
nonisolated enum MarkdownDocument {
    static func blocks(from source: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let document = try? AttributedString(markdown: source, options: options) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(source))]
        }

        var blocks: [MarkdownBlock] = []
        var markedItems: Set<Int> = []
        var table: (identity: Int, row: Int)?

        for (intent, range) in document.runs[\.presentationIntent] {
            guard let components = intent?.components, let block = components.first else { continue }
            let text = styled(AttributedString(document[range]))

            if case .tableCell = block.kind {
                let tableIdentity = components.first { if case .table = $0.kind { true } else { false } }?.identity ?? -1
                let rowIdentity = components.first {
                    switch $0.kind {
                    case .tableRow, .tableHeaderRow: true
                    default: false
                    }
                }?.identity ?? -1
                if let current = table, current.identity == tableIdentity,
                   case var .table(rows) = blocks.last?.kind {
                    if current.row == rowIdentity {
                        rows[rows.count - 1].append(text)
                    } else {
                        rows.append([text])
                    }
                    blocks[blocks.count - 1].kind = .table(rows: rows)
                } else {
                    blocks.append(MarkdownBlock(id: blocks.count, kind: .table(rows: [[text]]), text: text))
                }
                table = (tableIdentity, rowIdentity)
                continue
            }
            table = nil

            var item = MarkdownBlock(id: blocks.count, kind: .paragraph, text: text)
            item.quoteDepth = components.filter { $0.kind == .blockQuote }.count
            let listItems = components.enumerated().filter {
                if case .listItem = $0.element.kind { true } else { false }
            }
            item.listDepth = listItems.count
            if let (index, listItem) = listItems.first.map({ ($0.offset, $0.element) }),
               markedItems.insert(listItem.identity).inserted,
               case let .listItem(ordinal) = listItem.kind {
                let isOrdered = components.indices.contains(index + 1) && components[index + 1].kind == .orderedList
                item.marker = isOrdered ? "\(ordinal)." : (listItems.count > 1 ? "◦" : "•")
            }

            switch block.kind {
            case let .header(level): item.kind = .heading(level)
            case let .codeBlock(language):
                item.kind = .code(language: language?.lowercased())
                var code = String(text.characters)
                if code.hasSuffix("\n") { code.removeLast() }
                item.text = AttributedString(code)
            case .thematicBreak: item.kind = .rule
            default: item.kind = .paragraph
            }
            blocks.append(item)
        }
        return blocks
    }

    /// Inline code and links, styled to match Change Brief's prose.
    private static func styled(_ text: AttributedString) -> AttributedString {
        var text = text
        for run in text.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                text[run.range].foregroundColor = Color.blue.opacity(0.8)
                text[run.range].backgroundColor = Color.blue.opacity(0.06)
                text[run.range].font = .system(size: 12, design: .monospaced)
            }
            if run.link != nil {
                text[run.range].foregroundColor = .accentColor
            }
        }
        return text
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        content
            .padding(.leading, CGFloat(block.quoteDepth) * 14)
            .overlay(alignment: .leading) {
                if block.quoteDepth > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: 3)
                }
            }
            .foregroundStyle(block.quoteDepth > 0 ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case let .heading(level):
            VStack(alignment: .leading, spacing: 6) {
                Text(block.text)
                    .runeFont(size: [24, 19, 16, 14, 13, 13][min(level, 6) - 1], weight: .semibold)
                if level <= 2 { Divider() }
            }
            .padding(.top, level <= 2 ? 10 : 4)
        case .paragraph:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let marker = block.marker {
                    Text(marker)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 14, alignment: .trailing)
                }
                Text(block.text)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .runeFont(size: 13)
            // A list item's later paragraphs line up with its text, past the marker.
            .padding(.leading, block.listDepth == 0 ? 0 : CGFloat(block.listDepth - 1) * 20 + (block.marker == nil ? 20 : 0))
        case let .code(language):
            if language == "mermaid" {
                MarkdownDiagram(source: String(block.text.characters))
            } else {
                MarkdownCodeBlock(code: String(block.text.characters))
            }
        case .rule:
            Divider().padding(.vertical, 4)
        case let .table(rows):
            MarkdownTable(rows: rows)
        }
    }
}

private struct MarkdownCodeBlock: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(3)
                .fixedSize()
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.11), lineWidth: 1)
        }
    }
}

private struct MarkdownTable: View {
    let rows: [[AttributedString]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(rows[row].indices, id: \.self) { column in
                            Text(rows[row][column])
                                .runeFont(size: 12, weight: row == 0 ? .semibold : .regular)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(row == 0 ? Color.primary.opacity(0.04) : .clear)
                                .overlay { Rectangle().stroke(Color.primary.opacity(0.11), lineWidth: 0.5) }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.11), lineWidth: 1)
            }
        }
    }
}

private struct MarkdownDiagram: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    @State private var failure: String?

    // Diagrams are costly to lay out; keep them across re-renders and reopened files.
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    // Never enlarge a small diagram past its natural size.
                    .frame(maxWidth: image.size.width)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Diagram")
            } else if let failure {
                VStack(alignment: .leading, spacing: 6) {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .runeFont(size: 11)
                        .foregroundStyle(.secondary)
                    MarkdownCodeBlock(code: source)
                }
            } else {
                QuietProgressView(isActive: true).frame(height: 60).frame(maxWidth: .infinity)
            }
        }
        .task(id: "\(colorScheme):\(source)") {
            let dark = colorScheme == .dark
            let key = ((dark ? "dark:" : "light:") + source) as NSString
            if let cached = Self.images.object(forKey: key) {
                image = cached
                return
            }
            image = nil
            failure = nil
            let source = source
            let result: Result<NSImage?, Error> = await Task.detached(priority: .utility) {
                Result { try GuideDiagramRenderer.render(source: source, dark: dark, limits: .document) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case let .success(rendered?):
                Self.images.setObject(rendered, forKey: key, cost: Int(rendered.size.width * rendered.size.height * 16))
                image = rendered
            case .success(nil):
                failure = "This diagram could not be rendered."
            case let .failure(error):
                failure = error.localizedDescription
            }
        }
    }
}
