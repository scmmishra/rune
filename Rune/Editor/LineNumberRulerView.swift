import AppKit

final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private let isDiff: Bool
    private var numbers = EditorLineNumbers("", isDiff: false)
    private var numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var columnWidth: CGFloat = 0
    private var hasLoaded = false
    private static let padding: CGFloat = 10
    private static let columnGap: CGFloat = 10

    init(scrollView: NSScrollView, textView: NSTextView, isDiff: Bool) {
        self.textView = textView
        self.isDiff = isDiff
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw),
            name: NSView.frameDidChangeNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isFlipped: Bool { true }

    func reload(font: NSFont) {
        guard let textView else { return }
        numbers = EditorLineNumbers(textView.string, isDiff: isDiff)
        numberFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize - 1, weight: .regular)
        columnWidth = ceil((String(repeating: "8", count: numbers.digits) as NSString)
            .size(withAttributes: [.font: numberFont]).width)
        let thickness = Self.padding * 2 + columnWidth * (isDiff ? 2 : 1) + (isDiff ? Self.columnGap : 0)
        // Resizing a ruler tiles the scroll view. Never do that from its drawing callback.
        if let scrollView, ruleThickness != thickness || !hasLoaded {
            let clip = scrollView.contentView
            var leftBounds = clip.bounds
            leftBounds.origin.x = -max(ruleThickness, thickness)
            let oldLeft = clip.constrainBoundsRect(leftBounds).minX
            let offset = hasLoaded ? clip.bounds.minX - oldLeft : 0
            ruleThickness = thickness
            scrollView.tile()
            let newLeft = clip.constrainBoundsRect(leftBounds).minX
            // Overlay rulers give the document a negative left scroll limit. Preserve
            // the code's horizontal position when the gutter first appears or grows.
            clip.scroll(to: NSPoint(x: newLeft + offset, y: clip.bounds.minY))
            scrollView.reflectScrolledClipView(clip)
        }
        hasLoaded = true
        needsDisplay = true
    }

    @objc func redraw() { needsDisplay = true }

    // AppKit owns the gutter independently of the document's horizontal scroll position.
    // Source: https://developer.apple.com/documentation/appkit/nsrulerview/drawhashmarksandlabels(in:)
    override func drawHashMarksAndLabels(in rect: NSRect) {
        // AppKit can supply a dirty rect wider than the ruler. Clip explicitly so
        // its background never paints over code while scrolling or resizing.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.textBackgroundColor.setFill()
        rect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        guard let textView, let layout = textView.layoutManager,
              let container = textView.textContainer, !numbers.rows.isEmpty else { return }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect
        // Include the left edge of long lines even when the code is scrolled horizontally.
        let layoutRect = NSRect(x: 0, y: visible.minY - origin.y,
                                width: max(textView.bounds.width, visible.width), height: visible.height)
        let glyphs = layout.glyphRange(forBoundingRect: layoutRect, in: container)
        let length = (textView.string as NSString).length
        let firstCharacter = glyphs.length > 0 ? layout.characterIndexForGlyph(at: glyphs.location) : length
        let firstRow = numbers.rowIndex(at: firstCharacter)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor
        ]

        for row in numbers.rows[firstRow...] {
            let fragment: NSRect
            let baseline: CGFloat
            if row.location == length {
                fragment = layout.extraLineFragmentRect
                baseline = (fragment.height + numberFont.ascender + numberFont.descender) / 2
            } else {
                let glyph = layout.glyphIndexForCharacter(at: row.location)
                fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                baseline = layout.location(forGlyphAt: glyph).y
            }
            let point = convert(NSPoint(x: origin.x, y: origin.y + fragment.minY), from: textView)
            if point.y > bounds.maxY { break }
            guard point.y + fragment.height >= rect.minY, point.y <= rect.maxY else { continue }
            let y = point.y + baseline - numberFont.ascender

            func draw(_ number: Int?, rightEdge: CGFloat) {
                guard let number else { return }
                let label = String(number) as NSString
                label.draw(at: NSPoint(x: rightEdge - label.size(withAttributes: attributes).width, y: y),
                           withAttributes: attributes)
            }
            if isDiff { draw(row.old, rightEdge: Self.padding + columnWidth) }
            draw(row.new, rightEdge: ruleThickness - Self.padding)
        }
    }
}
