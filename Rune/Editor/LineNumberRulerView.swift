import AppKit

final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lineCount: Int

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        lineCount = Self.countLines(in: textView.string)
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 38

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(redraw),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange),
            name: NSText.didChangeNotification,
            object: textView
        )
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        rect.fill()

        guard let textView,
              let scrollView else { return }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let lineHeight = textView.layoutManager?.defaultLineHeight(for: SyntaxHighlighter.editorFont)
            ?? ceil(SyntaxHighlighter.editorFont.ascender - SyntaxHighlighter.editorFont.descender)
        let visibleBounds = scrollView.contentView.bounds
        let topInset = textView.textContainerInset.height
        let firstLine = max(0, Int(floor((visibleBounds.minY - topInset) / lineHeight)))
        let visibleLineCount = Int(ceil(visibleBounds.height / lineHeight)) + 2
        let lastLine = min(lineCount - 1, firstLine + visibleLineCount)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]

        if firstLine <= lastLine {
            for lineIndex in firstLine...lastLine {
                let y = topInset + CGFloat(lineIndex) * lineHeight - visibleBounds.minY
                String(lineIndex + 1).draw(
                    in: NSRect(x: 4, y: y, width: ruleThickness - 10, height: lineHeight),
                    withAttributes: attributes
                )
            }
        }
    }

    func reload() {
        guard let textView else { return }
        lineCount = Self.countLines(in: textView.string)
        let digits = max(2, String(lineCount).count)
        ruleThickness = max(38, CGFloat(digits * 7 + 18))
        needsDisplay = true
    }

    @objc private func redraw() {
        needsDisplay = true
    }

    @objc private func textDidChange() {
        reload()
    }

    private static func countLines(in text: String) -> Int {
        text.reduce(into: 1) { count, character in
            if character == "\n" {
                count += 1
            }
        }
    }
}
