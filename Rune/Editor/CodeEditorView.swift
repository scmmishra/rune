import AppKit
import SwiftUI

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let fileURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        textView.delegate = context.coordinator
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

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false

        let lineNumberRuler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = lineNumberRuler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.render(text, in: textView, fileURL: fileURL)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self

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
            textStorage.setAttributedString(
                SyntaxHighlighter.highlight(textView.string, fileURL: fileURL)
            )
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
