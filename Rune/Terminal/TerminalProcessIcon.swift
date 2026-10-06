import SwiftUI

/// How a terminal's foreground process shows: its mark, and the colors of its tile in a tab.
nonisolated struct TerminalProcessTile: Equatable, Sendable {
    /// The brand mark's asset; nil draws the plain terminal glyph.
    var asset: String?
    let background: UInt32
    let foreground: UInt32

    /// Every shell, and any terminal Rune knows nothing about yet.
    static let shell = TerminalProcessTile(background: 0x1D2420, foreground: 0x5FD38D)

    private static let assetsByProcess = [
        "bun": "process-bun",
        "bunx": "process-bun",
        "cargo": "process-rust",
        "deno": "process-deno",
        "docker": "process-docker",
        "docker-compose": "process-docker",
        "emacs": "process-gnuemacs",
        "emacsclient": "process-gnuemacs",
        "git": "process-git",
        "go": "process-go",
        "gopls": "process-go",
        "helix": "process-helix",
        "htop": "process-htop",
        "hx": "process-helix",
        "ipython": "process-python",
        "irb": "process-ruby",
        "kotlin": "process-kotlin",
        "kotlinc": "process-kotlin",
        "lazygit": "process-git",
        "lua": "process-lua",
        "luajit": "process-lua",
        "mysql": "process-mysql",
        "node": "process-nodedotjs",
        "npm": "process-npm",
        "npx": "process-npm",
        "nvim": "process-neovim",
        "php": "process-php",
        "pnpm": "process-pnpm",
        "pnpx": "process-pnpm",
        "postgres": "process-postgresql",
        "psql": "process-postgresql",
        "python": "process-python",
        "redis-cli": "process-redis",
        "redis-server": "process-redis",
        "ruby": "process-ruby",
        "rustc": "process-rust",
        "rustup": "process-rust",
        "swift": "process-swift",
        "swift-build": "process-swift",
        "swift-frontend": "process-swift",
        "swiftc": "process-swift",
        "tig": "process-git",
        "tmux": "process-tmux",
        "vi": "process-vim",
        "vim": "process-vim",
        "xcodebuild": "process-swift",
        "yarn": "process-yarn",
    ]

    /// Tile background and mark color for each asset.
    private static let colorsByAsset: [String: (background: UInt32, foreground: UInt32)] = [
        "agent-claude": (0xD97757, 0xFFFFFF),
        "agent-codex": (0xF7F7F7, 0x1A1A1A),
        "process-bun": (0xFBF0DF, 0x3B2A20),
        "process-deno": (0x1B1B1B, 0xFFFFFF),
        "process-docker": (0x2496ED, 0xFFFFFF),
        "process-git": (0xF05032, 0xFFFFFF),
        "process-gnuemacs": (0x7F5AB6, 0xFFFFFF),
        "process-go": (0x00ADD8, 0xFFFFFF),
        "process-helix": (0x281733, 0xC7A3F5),
        "process-htop": (0x1F6F43, 0xA7F3C4),
        "process-kotlin": (0x7F52FF, 0xFFFFFF),
        "process-lua": (0x2C2D72, 0xFFFFFF),
        "process-mysql": (0x00758F, 0xFFFFFF),
        "process-neovim": (0x2B7A3D, 0xFFFFFF),
        "process-nodedotjs": (0x5FA04E, 0xFFFFFF),
        "process-npm": (0xCB3837, 0xFFFFFF),
        "process-php": (0x777BB4, 0xFFFFFF),
        "process-pnpm": (0xF69220, 0xFFFFFF),
        "process-postgresql": (0x336791, 0xFFFFFF),
        "process-python": (0xFFD43B, 0x3776AB),
        "process-redis": (0xD82C20, 0xFFFFFF),
        "process-ruby": (0xCC342D, 0xFFFFFF),
        "process-rust": (0x2B2B2B, 0xF4A261),
        "process-swift": (0xF05138, 0xFFFFFF),
        "process-tmux": (0x1BB91F, 0xFFFFFF),
        "process-vim": (0x019733, 0xFFFFFF),
        "process-yarn": (0x2C8EBB, 0xFFFFFF),
    ]

    private static let scriptRuntimes: Set<String> = ["node", "bun", "deno"]
    private static let fallbackBackgrounds: [UInt32] = [
        0x6D5BD0, 0x2F80ED, 0x0F9D8A, 0xD9822B, 0xC2417D, 0x3A7D44, 0x8A5A44, 0x4E5D94,
    ]

    static func process(_ process: String, arguments: [String], isShell: Bool) -> TerminalProcessTile {
        if isShell { return shell }
        let name = normalized(process)
        // npm, pnpm and yarn run as a runtime with their script as argv[1], such as
        // `node …/npm-cli.js`. Other arguments are not inspected.
        if scriptRuntimes.contains(name), arguments.count > 1 {
            var script = URL(fileURLWithPath: arguments[1]).deletingPathExtension().lastPathComponent.lowercased()
            if script.hasSuffix("-cli") { script.removeLast(4) }
            if !scriptRuntimes.contains(script), let asset = assetsByProcess[script] { return branded(asset) }
        }
        return assetsByProcess[name].map(branded) ?? unbranded(name)
    }

    /// An agent without a mark gets a tile of its own, never the mark of the runtime under it.
    static func agent(_ agent: TerminalAgent) -> TerminalProcessTile {
        agent.markAsset.map(branded) ?? unbranded(agent.rawValue)
    }

    private static func branded(_ asset: String) -> TerminalProcessTile {
        let colors = colorsByAsset[asset] ?? (shell.background, shell.foreground)
        return TerminalProcessTile(asset: asset, background: colors.background, foreground: colors.foreground)
    }

    /// Any other program keeps one color of its own, the same every time (FNV-1a).
    private static func unbranded(_ name: String) -> TerminalProcessTile {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let background = fallbackBackgrounds[Int(hash % UInt32(fallbackBackgrounds.count))]
        return TerminalProcessTile(background: background, foreground: 0xFFFFFF)
    }

    /// Versioned binaries such as `python3.12` and `lua5.4` share their tool's mark.
    private static func normalized(_ process: String) -> String {
        var name = Substring(process.lowercased())
        while let last = name.last, last.isNumber || last == "." { name.removeLast() }
        return String(name)
    }
}

/// The process's mark in the color of the surrounding text, for pane headers.
struct TerminalProcessIconView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        session.processTile.image(fallback: Image(systemName: "terminal"))
            .resizable()
            .scaledToFit()
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }
}

/// A tab's panes as tiles: the first in front with its mark, the rest peeking out behind it.
struct TerminalProcessTileStack: View {
    let sessions: [TerminalSession]
    /// How far each tile behind shows past the one before it.
    private static let step: CGFloat = 5

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(sessions.enumerated().reversed()), id: \.element.id) { index, session in
                TerminalProcessTileView(session: session, showsMark: index == 0)
                    // Tiles further back are a little shorter, so the stack reads as receding.
                    .scaleEffect(y: 1 - CGFloat(index) * 0.1)
                    .offset(x: CGFloat(index) * Self.step)
            }
        }
        .frame(width: TerminalProcessTileView.size.width + CGFloat(max(0, sessions.count - 1)) * Self.step,
               alignment: .leading)
        .animation(.easeOut(duration: 0.12), value: sessions.map(\.id))
    }
}

/// The process's mark on a tile in its brand colors, for tabs.
struct TerminalProcessTileView: View {
    static let size = CGSize(width: 20, height: 16)
    @ObservedObject var session: TerminalSession
    var showsMark = true

    /// A soft highlight across the top half, as if lit from above.
    private static let glare = LinearGradient(
        stops: [.init(color: .white.opacity(0.16), location: 0),
                .init(color: .white.opacity(0.04), location: 0.5),
                .init(color: .clear, location: 0.6)],
        startPoint: .top, endPoint: .bottom
    )
    /// Darkens the lower edge so the tile reads as curved.
    private static let shade = LinearGradient(
        stops: [.init(color: .clear, location: 0.5), .init(color: .black.opacity(0.07), location: 1)],
        startPoint: .top, endPoint: .bottom
    )
    /// A bright upper rim that fades out toward the bottom.
    private static let rim = LinearGradient(
        colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom
    )

    var body: some View {
        let tile = session.processTile
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        // A bare prompt, since the tile already draws the box that the SF Symbol has built in.
        tile.image(fallback: Image("process-prompt"))
            .resizable()
            .scaledToFit()
            .frame(width: 10, height: 10)
            .foregroundStyle(Color(hex: tile.foreground))
            .opacity(showsMark ? 1 : 0)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(Color(hex: tile.background), in: shape)
            // Glass is drawn with gradients, not `glassEffect`: a tab bar of live glass layers
            // would cost more than these small static tiles are worth.
            .overlay { shape.fill(Self.glare).blendMode(.plusLighter) }
            .overlay { shape.fill(Self.shade) }
            .overlay { shape.strokeBorder(Self.rim, lineWidth: 0.5).blendMode(.plusLighter) }
            // A hairline keeps light tiles visible on a light tab and dark tiles on a dark one.
            .overlay { shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.1), radius: 0.5, y: 0.5)
            .accessibilityHidden(true)
    }
}

private extension TerminalProcessTile {
    func image(fallback: Image) -> Image { asset.map { Image($0) } ?? fallback }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
