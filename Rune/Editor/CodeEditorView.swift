import AppKit
import SwiftUI

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let fileURL: URL
    let onChange: () -> Void
    let onSave: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = RuneTextView()
        textView.delegate = context.coordinator
        textView.onSave = onSave
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindPanel = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        let lineNumberRuler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = lineNumberRuler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.render(text, in: textView, fileURL: fileURL)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? RuneTextView else { return }
        context.coordinator.parent = self
        textView.onSave = onSave

        if textView.string != text {
            context.coordinator.render(text, in: textView, fileURL: fileURL)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        private var isRendering = false

        init(parent: CodeEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isRendering,
                  let textView = notification.object as? NSTextView else { return }

            parent.text = textView.string
            parent.onChange()
            highlight(textView, fileURL: parent.fileURL)
        }

        func render(_ text: String, in textView: NSTextView, fileURL: URL) {
            isRendering = true
            textView.string = text
            highlight(textView, fileURL: fileURL)
            isRendering = false
        }

        private func highlight(_ textView: NSTextView, fileURL: URL) {
            guard let textStorage = textView.textStorage else { return }
            let selectedRanges = textView.selectedRanges
            isRendering = true
            textStorage.setAttributedString(SyntaxHighlighter.highlight(textView.string, fileURL: fileURL))
            textView.selectedRanges = selectedRanges.map { value in
                let range = value.rangeValue
                let location = min(range.location, textStorage.length)
                let length = min(range.length, textStorage.length - location)
                return NSValue(range: NSRange(location: location, length: length))
            }
            textView.typingAttributes = SyntaxHighlighter.baseAttributes
            (textView.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?.reload()
            isRendering = false
        }
    }
}

private final class RuneTextView: NSTextView {
    var onSave: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "s" {
            onSave?()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
