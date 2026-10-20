import GhosttyKit
import GhosttyTerminal

extension TerminalSession {
    /// The last `lines` lines of the terminal, scrollback included, with soft-wrapped rows
    /// joined into one line. Nil while the terminal has no surface.
    func recentText(lines: Int) -> String? {
        guard let surface = Self.rawSurface(of: terminal.surface) else { return nil }
        // The whole screen, history included: a range given in viewport rows would miss
        // output that scrolled off, which is most of what an agent asks for.
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let start = text.text, text.text_len > 0 else { return "" }
        let bytes = UnsafeRawBufferPointer(start: start, count: Int(text.text_len))
        var all = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n")
        // The rows below the prompt are blank until something is printed there.
        while all.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { all.removeLast() }
        return all.suffix(max(1, lines)).joined(separator: "\n")
    }

    /// libghostty-spm 1.5.2 keeps `TerminalSurface.rawValue` internal and offers no public
    /// way to read a surface's text, so the handle is read from its one stored property.
    /// The package is pinned to that exact version. A new version must be checked here.
    private static func rawSurface(of surface: GhosttyTerminal.TerminalSurface?) -> ghostty_surface_t? {
        guard let surface else { return nil }
        let value = Mirror(reflecting: surface).children.first { $0.label == "surface" }?.value
        return value as? ghostty_surface_t
    }
}
