import AppKit
import SwiftUI

struct CodeEditorView: View {
    typealias Presentation = NativeCodeEditorView.Presentation
    @Binding var text: String
    let fileURL: URL
    var isEditable = true
    var presentation: Presentation = .source
    @State private var request = 0
    @State private var action = PreviewAction.find

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { perform(.find) } label: { Label("Find", systemImage: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command)
                Spacer()
                if presentation == .diff {
                    Button { perform(.previousHunk) } label: { Image(systemName: "chevron.up") }
                        .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                        .help("Previous Hunk (⌥⌘↑)")
                    Button { perform(.nextHunk) } label: { Image(systemName: "chevron.down") }
                        .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                        .help("Next Hunk (⌥⌘↓)")
                }
            }
            .buttonStyle(.plain)
            .runeFont(size: 11)
            .padding(.horizontal, 12)
            .frame(height: 28)
            NativeCodeEditorView(text: $text, fileURL: fileURL, isEditable: isEditable,
                                 presentation: presentation, request: request, action: action)
        }
    }

    private func perform(_ action: PreviewAction) {
        self.action = action
        request += 1
    }
}

enum PreviewAction { case find, previousHunk, nextHunk }

struct NativeCodeEditorView: NSViewRepresentable {
    enum Presentation {
        case source
        case diff
    }

    @Binding var text: String
    @Environment(\.runeTypography) private var typography
    let fileURL: URL
    var isEditable = true
    var presentation: Presentation = .source
    var request = 0
    var action = PreviewAction.find

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        // Syntax highlighting edits NSTextStorage directly, so keep the editor on one
        // predictable TextKit 1 stack instead of entering compatibility mode lazily.
        // The coordinator owns the storage for the lifetime of the represented view.
        // Source: https://developer.apple.com/documentation/appkit/nstextview/init(frame:textcontainer:)
        let textStorage = context.coordinator.textStorage
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        textContainer.widthTracksTextView = false

        let textView = RuneTextView(
            frame: NSRect(origin: .zero, size: scrollView.contentSize),
            textContainer: textContainer
        )
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindPanel = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        scrollView.documentView = textView

        context.coordinator.render(
            text,
            in: textView,
            fileURL: fileURL,
            typography: typography
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        textView.isEditable = isEditable

        if context.coordinator.lastRequest != request {
            context.coordinator.lastRequest = request
            switch action {
            case .find:
                scrollView.window?.makeFirstResponder(textView)
                let item = NSMenuItem()
                item.tag = NSTextFinder.Action.showFindInterface.rawValue
                textView.performFindPanelAction(item)
            case .previousHunk, .nextHunk:
                let source = textView.string as NSString
                let expression = try? NSRegularExpression(pattern: "^@@", options: .anchorsMatchLines)
                let locations = expression?.matches(in: textView.string, range: NSRange(location: 0, length: source.length)).map { $0.range.location } ?? []
                let current = textView.selectedRange().location
                let target = action == .nextHunk
                    ? locations.first(where: { $0 > current }) ?? locations.last
                    : locations.last(where: { $0 < current }) ?? locations.first
                if let target {
                    let range = source.lineRange(for: NSRange(location: target, length: 0))
                    textView.setSelectedRange(NSRange(location: target, length: 0))
                    textView.scrollRangeToVisible(range)
                }
            }
        }

        if textView.string != text || context.coordinator.typography != typography {
            context.coordinator.render(
                text,
                in: textView,
                fileURL: fileURL,
                typography: typography
            )
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeCodeEditorView
        var lastRequest = 0
        var typography: RuneTypography
        let textStorage = NSTextStorage()
        private var isRendering = false
        private var syntaxHighlighter: SyntaxHighlighter?
        private var syntaxFileURL: URL?

        init(parent: NativeCodeEditorView) {
            self.parent = parent
            typography = parent.typography
            if parent.presentation == .source {
                syntaxFileURL = parent.fileURL
                syntaxHighlighter = SyntaxHighlighter(
                    fileURL: parent.fileURL,
                    font: parent.typography.nsFont(size: 12)
                )
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isRendering,
                  let textView = notification.object as? NSTextView else { return }

            parent.text = textView.string
            highlight(textView, fileURL: parent.fileURL, typography: typography)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? RuneTextView)?.refreshCurrentLineHighlight()
        }

        func render(
            _ text: String,
            in textView: NSTextView,
            fileURL: URL,
            typography: RuneTypography
        ) {
            isRendering = true
            if self.typography != typography {
                self.typography = typography
                syntaxHighlighter = nil
                syntaxFileURL = nil
            }
            textView.string = text
            highlight(textView, fileURL: fileURL, typography: typography)
            isRendering = false
        }

        private func highlight(
            _ textView: NSTextView,
            fileURL: URL,
            typography: RuneTypography
        ) {
            guard let textStorage = textView.textStorage else { return }

            let selectedRanges = textView.selectedRanges
            let font = typography.nsFont(size: 12)
            isRendering = true
            let highlightedText = switch parent.presentation {
            case .source:
                sourceHighlight(textView.string, fileURL: fileURL, font: font)
            case .diff:
                DiffSyntaxHighlighter.highlight(textView.string, font: font)
            }
            textStorage.setAttributedString(highlightedText)
            textView.selectedRanges = selectedRanges.map { value in
                let range = value.rangeValue
                let location = min(range.location, textStorage.length)
                let length = min(range.length, textStorage.length - location)
                return NSValue(range: NSRange(location: location, length: length))
            }
            textView.typingAttributes = SyntaxHighlighter.baseAttributes(font: font)
            (textView as? RuneTextView)?.refreshCurrentLineHighlight()
            isRendering = false
        }

        private func sourceHighlight(
            _ source: String,
            fileURL: URL,
            font: NSFont
        ) -> NSAttributedString {
            if let syntaxHighlighter, syntaxFileURL == fileURL {
                return syntaxHighlighter.highlight(source)
            }

            let syntaxHighlighter = SyntaxHighlighter(fileURL: fileURL, font: font)
            syntaxFileURL = fileURL
            self.syntaxHighlighter = syntaxHighlighter
            return syntaxHighlighter.highlight(source)
        }
    }
}

private final class RuneTextView: NSTextView {
    // Draw the active line outside NSTextStorage so cursor movement does not alter
    // syntax attributes or make the document appear edited.
    // Source: https://developer.apple.com/documentation/appkit/nstextview/drawbackground(in:)
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard isEditable,
              let lineRect = currentLineRect,
              lineRect.intersects(rect) else { return }
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        lineRect.fill()
    }

    func refreshCurrentLineHighlight() {
        setNeedsDisplay(visibleRect)
    }

    private var currentLineRect: NSRect? {
        guard let layoutManager,
              let textContainer else { return nil }

        let text = string as NSString
        let caretLocation = min(selectedRange().location, text.length)
        let caretLineRange = text.lineRange(
            for: NSRange(location: caretLocation, length: 0)
        )
        let fragmentRect: NSRect

        if caretLineRange.location == text.length {
            let extraLineRect = layoutManager.extraLineFragmentRect
            if extraLineRect.isEmpty {
                let usedRect = layoutManager.usedRect(for: textContainer)
                fragmentRect = NSRect(
                    x: 0,
                    y: usedRect.maxY,
                    width: bounds.width,
                    height: layoutManager.defaultLineHeight(
                        for: font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                    )
                )
            } else {
                fragmentRect = extraLineRect
            }
        } else {
            let characterIndex = min(caretLocation, text.length - 1)
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            fragmentRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil
            )
        }

        return NSRect(
            x: bounds.minX,
            y: textContainerOrigin.y + fragmentRect.minY,
            width: bounds.width,
            height: fragmentRect.height
        )
    }
}
