import AppKit
import SwiftUI

/// The terminal's own background, shared by Ghostty's theme and the panel behind it
/// so the tab strip and the character grid sit on one continuous surface.
enum TerminalSurface {
    static let lightHex = "EFEFEF"
    static let darkHex = "181818"

    static let color = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(hex: isDark ? darkHex : lightHex)
    })
}

private extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
