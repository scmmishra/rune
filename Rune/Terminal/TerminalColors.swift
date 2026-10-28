import GhosttyTerminal

/// One terminal color scheme. Every value is a hex color without the leading `#`.
nonisolated struct TerminalColors {
    let background: String
    let foreground: String
    let cursor: String
    let cursorText: String
    let selectionBackground: String
    let selectionForeground: String
    /// The 16 ANSI colors, in order.
    let palette: [String]

    var configuration: TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withBackground(background)
            builder.withForeground(foreground)
            builder.withCursorColor(cursor)
            builder.withCursorText(cursorText)
            builder.withSelectionBackground(selectionBackground)
            builder.withSelectionForeground(selectionForeground)
            for (index, color) in palette.enumerated() {
                builder.withPalette(index, color: "#\(color)")
            }
        }
    }
}

/// Copied from libghostty-spm's GhosttyTheme catalog, which takes them from
/// iTerm2-Color-Schemes (MIT). Rune ships only these, so it does not link the
/// whole 485-theme catalog.
nonisolated extension TerminalColors {
    /// Xcode Light
    static let xcodeLight = TerminalColors(
        background: "ffffff",
        foreground: "262626",
        cursor: "262626",
        cursorText: "ffffff",
        selectionBackground: "b4d8fd",
        selectionForeground: "262626",
        palette: ["b4d8fd", "d12f1b", "3e8087", "78492a", "0f68a0", "ad3da4", "804fb8", "262626", "8a99a6", "d12f1b", "23575c", "78492a", "0b4f79", "ad3da4", "4b21b0", "262626"]
    )

    /// Xcode Dark
    static let xcodeDark = TerminalColors(
        background: "292a30",
        foreground: "dfdfe0",
        cursor: "dfdfe0",
        cursorText: "292a30",
        selectionBackground: "414453",
        selectionForeground: "dfdfe0",
        palette: ["414453", "ff8170", "78c2b3", "d9c97c", "4eb0cc", "ff7ab2", "b281eb", "dfdfe0", "7f8c98", "ff8170", "acf2e4", "ffa14f", "6bdfff", "ff7ab2", "dabaff", "dfdfe0"]
    )

    /// GitHub Light Default
    static let githubLight = TerminalColors(
        background: "ffffff",
        foreground: "1f2328",
        cursor: "0969da",
        cursorText: "3c9cff",
        selectionBackground: "1f2328",
        selectionForeground: "ffffff",
        palette: ["24292f", "cf222e", "116329", "4d2d00", "0969da", "8250df", "1b7c83", "6e7781", "57606a", "a40e26", "1a7f37", "633c01", "218bff", "a475f9", "3192aa", "8c959f"]
    )

    /// GitHub Dark Default
    static let githubDark = TerminalColors(
        background: "0d1117",
        foreground: "e6edf3",
        cursor: "2f81f7",
        cursorText: "6fc1ff",
        selectionBackground: "e6edf3",
        selectionForeground: "0d1117",
        palette: ["484f58", "ff7b72", "3fb950", "d29922", "58a6ff", "bc8cff", "39c5cf", "b1bac4", "6e7681", "ffa198", "56d364", "e3b341", "79c0ff", "d2a8ff", "56d4dd", "ffffff"]
    )

    /// Catppuccin Latte
    static let catppuccinLatte = TerminalColors(
        background: "eff1f5",
        foreground: "4c4f69",
        cursor: "dc8a78",
        cursorText: "eff1f5",
        selectionBackground: "acb0be",
        selectionForeground: "4c4f69",
        palette: ["5c5f77", "d20f39", "40a02b", "df8e1d", "1e66f5", "ea76cb", "179299", "acb0be", "6c6f85", "de293e", "49af3d", "eea02d", "456eff", "fe85d8", "2d9fa8", "bcc0cc"]
    )

    /// Catppuccin Mocha
    static let catppuccinMocha = TerminalColors(
        background: "1e1e2e",
        foreground: "cdd6f4",
        cursor: "f5e0dc",
        cursorText: "1e1e2e",
        selectionBackground: "585b70",
        selectionForeground: "cdd6f4",
        palette: ["45475a", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "f5c2e7", "94e2d5", "a6adc8", "585b70", "f37799", "89d88b", "ebd391", "74a8fc", "f2aede", "6bd7ca", "bac2de"]
    )

    /// Rose Pine Dawn
    static let rosePineDawn = TerminalColors(
        background: "faf4ed",
        foreground: "575279",
        cursor: "575279",
        cursorText: "faf4ed",
        selectionBackground: "dfdad9",
        selectionForeground: "575279",
        palette: ["f2e9e1", "b4637a", "286983", "ea9d34", "56949f", "907aa9", "d7827e", "575279", "9893a5", "b4637a", "286983", "ea9d34", "56949f", "907aa9", "d7827e", "575279"]
    )

    /// Rose Pine
    static let rosePine = TerminalColors(
        background: "191724",
        foreground: "e0def4",
        cursor: "e0def4",
        cursorText: "191724",
        selectionBackground: "403d52",
        selectionForeground: "e0def4",
        palette: ["26233a", "eb6f92", "31748f", "f6c177", "9ccfd8", "c4a7e7", "ebbcba", "e0def4", "6e6a86", "eb6f92", "31748f", "f6c177", "9ccfd8", "c4a7e7", "ebbcba", "e0def4"]
    )

    /// TokyoNight Day
    static let tokyoNightDay = TerminalColors(
        background: "e1e2e7",
        foreground: "3760bf",
        cursor: "3760bf",
        cursorText: "e1e2e7",
        selectionBackground: "99a7df",
        selectionForeground: "3760bf",
        palette: ["e9e9ed", "f52a65", "587539", "8c6c3e", "2e7de9", "9854f1", "007197", "6172b0", "a1a6c5", "f52a65", "587539", "8c6c3e", "2e7de9", "9854f1", "007197", "3760bf"]
    )

    /// TokyoNight Night
    static let tokyoNightNight = TerminalColors(
        background: "1a1b26",
        foreground: "c0caf5",
        cursor: "c0caf5",
        cursorText: "1a1b26",
        selectionBackground: "283457",
        selectionForeground: "c0caf5",
        palette: ["15161e", "f7768e", "9ece6a", "e0af68", "7aa2f7", "bb9af7", "7dcfff", "a9b1d6", "414868", "f7768e", "9ece6a", "e0af68", "7aa2f7", "bb9af7", "7dcfff", "c0caf5"]
    )

    /// Gruvbox Light
    static let gruvboxLight = TerminalColors(
        background: "fbf1c7",
        foreground: "3c3836",
        cursor: "3c3836",
        cursorText: "fbf1c7",
        selectionBackground: "3c3836",
        selectionForeground: "fbf1c7",
        palette: ["fbf1c7", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "7c6f64", "928374", "9d0006", "79740e", "b57614", "076678", "8f3f71", "427b58", "3c3836"]
    )

    /// Gruvbox Dark
    static let gruvboxDark = TerminalColors(
        background: "282828",
        foreground: "ebdbb2",
        cursor: "ebdbb2",
        cursorText: "282828",
        selectionBackground: "665c54",
        selectionForeground: "ebdbb2",
        palette: ["282828", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "a89984", "928374", "fb4934", "b8bb26", "fabd2f", "83a598", "d3869b", "8ec07c", "ebdbb2"]
    )

    /// iTerm2 Solarized Light
    static let solarizedLight = TerminalColors(
        background: "fdf6e3",
        foreground: "657b83",
        cursor: "657b83",
        cursorText: "eee8d5",
        selectionBackground: "eee8d5",
        selectionForeground: "586e75",
        palette: ["073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "bbb5a2", "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3"]
    )

    /// iTerm2 Solarized Dark
    static let solarizedDark = TerminalColors(
        background: "002b36",
        foreground: "839496",
        cursor: "839496",
        cursorText: "073642",
        selectionBackground: "073642",
        selectionForeground: "93a1a1",
        palette: ["073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5", "335e69", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3"]
    )

    /// Flexoki Light
    static let flexokiLight = TerminalColors(
        background: "fffcf0",
        foreground: "100f0f",
        cursor: "100f0f",
        cursorText: "fffcf0",
        selectionBackground: "cecdc3",
        selectionForeground: "100f0f",
        palette: ["100f0f", "af3029", "66800b", "ad8301", "205ea6", "a02f6f", "24837b", "6f6e69", "b7b5ac", "d14d41", "879a39", "d0a215", "4385be", "ce5d97", "3aa99f", "cecdc3"]
    )

    /// Flexoki Dark
    static let flexokiDark = TerminalColors(
        background: "100f0f",
        foreground: "cecdc3",
        cursor: "cecdc3",
        cursorText: "100f0f",
        selectionBackground: "403e3c",
        selectionForeground: "cecdc3",
        palette: ["100f0f", "d14d41", "879a39", "d0a215", "4385be", "ce5d97", "3aa99f", "878580", "575653", "af3029", "66800b", "ad8301", "205ea6", "a02f6f", "24837b", "cecdc3"]
    )

    /// Kanagawa Lotus
    static let kanagawaLotus = TerminalColors(
        background: "f2ecbc",
        foreground: "545464",
        cursor: "43436c",
        cursorText: "f2ecbc",
        selectionBackground: "545464",
        selectionForeground: "f2ecbc",
        palette: ["1f1f28", "c84053", "6f894e", "77713f", "4d699b", "b35b79", "597b75", "545464", "8a8980", "d7474b", "6e915f", "836f4a", "6693bf", "624c83", "5e857a", "43436c"]
    )

    /// Kanagawa Wave
    static let kanagawaWave = TerminalColors(
        background: "1f1f28",
        foreground: "dcd7ba",
        cursor: "dcd7ba",
        cursorText: "1f1f28",
        selectionBackground: "dcd7ba",
        selectionForeground: "1f1f28",
        palette: ["090618", "c34043", "76946a", "c0a36e", "7e9cd8", "957fb8", "6a9589", "c8c093", "727169", "e82424", "98bb6c", "e6c384", "7fb4ca", "938aa9", "7aa89f", "dcd7ba"]
    )
}
