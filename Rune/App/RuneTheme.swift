import AppKit
import GhosttyTerminal
import SwiftUI

/// Rune's colors: the terminal's, and every card and the window around them. Each theme
/// has a light and a dark version, and Rune switches between them when the system
/// appearance changes. An agent that matches the terminal's background, such as Claude
/// Code's `auto` theme, switches with it.
nonisolated enum RuneTheme: String, CaseIterable, Identifiable {
    case rune, xcode, github, catppuccin, rosePine, tokyoNight, gruvbox, solarized, flexoki, kanagawa

    static let preferenceKey = "theme"

    /// The theme saved in Settings, for code that cannot read the environment.
    static var current: Self {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .rune
    }

    var id: String { rawValue }

    /// The names of the light and the dark version.
    var names: (light: String, dark: String) {
        switch self {
        case .rune: ("Rune Light", "Rune Dark")
        case .xcode: ("Xcode Light", "Xcode Dark")
        case .github: ("GitHub Light", "GitHub Dark")
        case .catppuccin: ("Catppuccin Latte", "Catppuccin Mocha")
        case .rosePine: ("Rosé Pine Dawn", "Rosé Pine")
        case .tokyoNight: ("Tokyo Night Day", "Tokyo Night")
        case .gruvbox: ("Gruvbox Light", "Gruvbox Dark")
        case .solarized: ("Solarized Light", "Solarized Dark")
        case .flexoki: ("Flexoki Light", "Flexoki Dark")
        case .kanagawa: ("Kanagawa Lotus", "Kanagawa Wave")
        }
    }

    /// Nil for Rune's own theme, which keeps the system's colors.
    private var colors: (light: TerminalColors, dark: TerminalColors)? {
        switch self {
        case .rune: nil
        case .xcode: (.xcodeLight, .xcodeDark)
        case .github: (.githubLight, .githubDark)
        case .catppuccin: (.catppuccinLatte, .catppuccinMocha)
        case .rosePine: (.rosePineDawn, .rosePine)
        case .tokyoNight: (.tokyoNightDay, .tokyoNightNight)
        case .gruvbox: (.gruvboxLight, .gruvboxDark)
        case .solarized: (.solarizedLight, .solarizedDark)
        case .flexoki: (.flexokiLight, .flexokiDark)
        case .kanagawa: (.kanagawaLotus, .kanagawaWave)
        }
    }

    var terminalTheme: TerminalTheme {
        guard let colors else {
            return TerminalTheme(
                light: TerminalConfiguration(startingFrom: .alabaster) { builder in
                    builder.withBackground(TerminalSurface.lightHex)
                },
                dark: TerminalConfiguration(startingFrom: .afterglow) { builder in
                    builder.withBackground(TerminalSurface.darkHex)
                }
            )
        }
        return TerminalTheme(light: colors.light.configuration, dark: colors.dark.configuration)
    }

    /// The terminal's background. The terminal panel and every card fill with it.
    var surface: Color { Self.palettes[self]!.surface }
    /// The recessed background behind the cards.
    var chrome: Color { Self.palettes[self]!.chrome }
    /// Text. Secondary and tertiary text are lighter versions of it.
    var foreground: Color { Self.palettes[self]!.foreground }

    func color(_ role: ThemeColor.Role) -> Color { Self.palettes[self]!.roles[role]! }

    private struct Palette {
        let surface: Color
        let chrome: Color
        let foreground: Color
        let roles: [ThemeColor.Role: Color]
    }

    // Built once: views read these on every update.
    private static let palettes = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.makePalette()) })

    private func makePalette() -> Palette {
        guard let colors else {
            return Palette(
                surface: Self.adaptive(light: NSColor(hex: TerminalSurface.lightHex), dark: NSColor(hex: TerminalSurface.darkHex)),
                chrome: Self.adaptive(light: NSColor(white: 0.885, alpha: 1), dark: NSColor(white: 0.065, alpha: 1)),
                foreground: .primary,
                roles: [.accent: .accentColor, .red: .red, .orange: .orange, .yellow: .yellow,
                        .green: .green, .blue: .blue, .purple: .purple, .secondary: .secondary]
            )
        }
        func pair(_ value: (TerminalColors) -> String) -> Color {
            Self.adaptive(light: NSColor(hex: value(colors.light)), dark: NSColor(hex: value(colors.dark)))
        }
        // The ANSI palette has no orange. Most themes draw their yellow, index 3, warm.
        let indexes: [ThemeColor.Role: Int] = [.accent: 4, .red: 1, .orange: 3, .yellow: 11, .green: 2, .blue: 4, .purple: 5]
        var roles = indexes.mapValues { index in pair { $0.palette[index] } }
        roles[.secondary] = .secondary
        // Rune's own chrome is about 69% of its surface in dark and 94% in light.
        // Scaling each theme's background the same way keeps that depth.
        return Palette(
            surface: pair(\.background),
            chrome: Self.adaptive(light: NSColor(hex: colors.light.background).scaled(by: 0.944),
                                  dark: NSColor(hex: colors.dark.background).scaled(by: 0.69)),
            foreground: pair(\.foreground),
            roles: roles
        )
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// One version of a theme, as the theme lists show it.
nonisolated struct ThemeVariant: Hashable, Identifiable {
    let theme: RuneTheme
    let isDark: Bool

    /// Dark versions first, then light.
    static let all = [true, false].flatMap { isDark in RuneTheme.allCases.map { ThemeVariant(theme: $0, isDark: isDark) } }

    var id: String { theme.rawValue + (isDark ? ".dark" : ".light") }
    var name: String { isDark ? theme.names.dark : theme.names.light }
}

/// Which version of the theme Rune shows. Picking a version that differs from the system
/// appearance saves that Rune runs opposite to the system. If the system then switches,
/// Rune switches to the theme's other version, so the choice holds in both appearances.
@MainActor
final class ThemeAppearance: ObservableObject {
    static let shared = ThemeAppearance()
    static let invertsKey = "themeInvertsAppearance"

    @Published private(set) var variant: ThemeVariant
    private var systemIsDark = ThemeAppearance.readSystemIsDark()

    private init() {
        variant = ThemeVariant(theme: .current, isDark: systemIsDark != UserDefaults.standard.bool(forKey: Self.invertsKey))
        // NSApp.effectiveAppearance reports Rune's own appearance once Rune sets one, so it
        // cannot tell when the system switches. The global default and its notification can.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let shared = ThemeAppearance.shared
                shared.systemIsDark = Self.readSystemIsDark()
                shared.select(ThemeVariant(theme: shared.variant.theme,
                                           isDark: shared.systemIsDark != UserDefaults.standard.bool(forKey: Self.invertsKey)))
            }
        }
    }

    func select(_ variant: ThemeVariant) {
        let defaults = UserDefaults.standard
        defaults.set(variant.theme.rawValue, forKey: RuneTheme.preferenceKey)
        defaults.set(variant.isDark != systemIsDark, forKey: Self.invertsKey)
        self.variant = variant
        apply()
    }

    /// Nil follows the system, so Rune's windows switch together with the rest of the Mac.
    func apply() {
        let appearance = variant.isDark == systemIsDark ? nil : NSAppearance(named: variant.isDark ? .darkAqua : .aqua)
        if NSApp.appearance != appearance { NSApp.appearance = appearance }
    }

    private static func readSystemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
}

/// A status or accent color from the theme. Rune's own theme gives the system's colors.
struct ThemeColor: ShapeStyle {
    enum Role { case accent, red, orange, yellow, green, blue, purple, secondary }

    let role: Role
    var alpha = 1.0

    static let accent = ThemeColor(role: .accent)
    static let red = ThemeColor(role: .red)
    static let orange = ThemeColor(role: .orange)
    static let yellow = ThemeColor(role: .yellow)
    static let green = ThemeColor(role: .green)
    static let blue = ThemeColor(role: .blue)
    static let purple = ThemeColor(role: .purple)
    static let secondary = ThemeColor(role: .secondary)

    func opacity(_ value: Double) -> ThemeColor {
        ThemeColor(role: role, alpha: alpha * value)
    }

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.runeTheme.color(role).opacity(alpha)
    }
}

nonisolated private struct RuneThemeKey: EnvironmentKey {
    static let defaultValue = RuneTheme.rune
}

extension EnvironmentValues {
    nonisolated var runeTheme: RuneTheme {
        get { self[RuneThemeKey.self] }
        set { self[RuneThemeKey.self] = newValue }
    }
}

extension View {
    /// Applies the saved theme: its text color, and the theme for every view below.
    func runeThemePreference() -> some View {
        modifier(RuneThemePreferenceModifier())
    }
}

private struct RuneThemePreferenceModifier: ViewModifier {
    @AppStorage(RuneTheme.preferenceKey)
    private var theme = RuneTheme.rune

    func body(content: Content) -> some View {
        content
            .onAppear { ThemeAppearance.shared.apply() }
            .foregroundStyle(theme.foreground)
            .environment(\.runeTheme, theme)
    }
}

nonisolated private extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    func scaled(by factor: CGFloat) -> NSColor {
        NSColor(srgbRed: redComponent * factor, green: greenComponent * factor, blue: blueComponent * factor, alpha: 1)
    }
}
