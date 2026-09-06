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
            if presentation == .diff {
                HStack {
                    Spacer()
                    Button { perform(.previousHunk) } label: { Image(systemName: "chevron.up") }
                        .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                        .help("Previous Hunk (⌥⌘↑)")
                    Button { perform(.nextHunk) } label: { Image(systemName: "chevron.down") }
                        .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                        .help("Next Hunk (⌥⌘↓)")
                }
                .buttonStyle(WorkspaceButtonStyle())
                .runeFont(size: 11)
                .padding(.horizontal, 12)
                .frame(height: 28)
            }
            NativeCodeEditorView(text: $text, fileURL: fileURL, isEditable: isEditable,
                                 presentation: presentation, request: request, action: action)
        }
        .background {
            // Retain the preview-scoped shortcut without a visible toolbar control.
            Button("Find in Preview") { perform(.find) }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func perform(_ action: PreviewAction) {
        self.action = action
        request += 1
    }
}

enum PreviewAction { case find, previousHunk, nextHunk }

// Find is the innermost preview layer: Escape dismisses it before the drawer.
func dismissPreviewFindBar(in view: NSView?) -> Bool {
    guard let view else { return false }
    if let scroll = view as? NSScrollView, scroll.isFindBarVisible {
        scroll.isFindBarVisible = false
        scroll.window?.makeFirstResponder(scroll.documentView)
        return true
    }
    return view.subviews.contains { dismissPreviewFindBar(in: $0) }
}

// Only immutable copies cross the actor boundary; mutable parser state stays in the worker.
nonisolated struct HighlightedText: @unchecked Sendable {
    let value: NSAttributedString
}

private actor HighlightWorker {
    private var highlighter: SyntaxHighlighter?
    private var fileURL: URL?
    private var fontName = ""
    private var fontSize: CGFloat = 0

    func highlight(_ text: String, fileURL: URL, fontName: String, fontSize: CGFloat, isDiff: Bool) -> HighlightedText? {
        guard !Task.isCancelled else { return nil }
        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if isDiff {
            return HighlightedText(value: NSAttributedString(attributedString: DiffSyntaxHighlighter.highlight(text, font: font)))
        }
        if self.fileURL != fileURL || self.fontName != fontName || self.fontSize != fontSize {
            highlighter = SyntaxHighlighter(fileURL: fileURL, font: font)
            self.fileURL = fileURL
            self.fontName = fontName
            self.fontSize = fontSize
        }
        return HighlightedText(value: NSAttributedString(attributedString: highlighter!.highlight(text)))
    }
}

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

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.highlightTask?.cancel()
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
        private let worker = HighlightWorker()
        var highlightTask: Task<Void, Never>?

        init(parent: NativeCodeEditorView) {
            self.parent = parent
            typography = parent.typography
        }

        func textDidChange(_ notification: Notification) {
            guard !isRendering,
                  let textView = notification.object as? NSTextView else { return }

            parent.text = textView.string
            highlight(textView, fileURL: parent.fileURL, typography: typography, debounce: true)
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
            }
            textView.string = text
            textView.textStorage?.setAttributes(SyntaxHighlighter.baseAttributes(font: typography.nsFont(size: 12)),
                                               range: NSRange(location: 0, length: (text as NSString).length))
            highlight(textView, fileURL: fileURL, typography: typography)
            isRendering = false
        }

        private func highlight(
            _ textView: NSTextView,
            fileURL: URL,
            typography: RuneTypography,
            debounce: Bool = false
        ) {
            highlightTask?.cancel()
            let source = textView.string
            let font = typography.nsFont(size: 12)
            let isDiff = parent.presentation == .diff
            let worker = worker
            highlightTask = Task { [weak self, weak textView] in
                if debounce { try? await Task.sleep(for: .milliseconds(60)) }
                guard !Task.isCancelled else { return }
                let result = await worker.highlight(source, fileURL: fileURL, fontName: font.fontName,
                                                    fontSize: font.pointSize, isDiff: isDiff)
                guard !Task.isCancelled, let result, let self, let textView,
                      textView.string == source, let storage = textView.textStorage else { return }
                self.isRendering = true
                var changes: [(NSRange, [NSAttributedString.Key: Any])] = []
                result.value.enumerateAttributes(in: NSRange(location: 0, length: result.value.length)) { attributes, range, _ in
                    storage.enumerateAttributes(in: range) { existing, subrange, _ in
                        if !NSDictionary(dictionary: existing).isEqual(to: attributes) {
                            changes.append((subrange, attributes))
                        }
                    }
                }
                // Attribute-only edits preserve undo, selection, and layout outside changed runs.
                storage.beginEditing()
                for (range, attributes) in changes { storage.setAttributes(attributes, range: range) }
                storage.endEditing()
                textView.typingAttributes = SyntaxHighlighter.baseAttributes(font: font)
                self.isRendering = false
            }
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
