import AppKit
import SwiftUI

struct RuneTypography: Equatable {
    static let defaultFamily = "System Monospaced"
    static let defaultSize = 12.0

    let family: String
    let baseSize: Double

    var resolvedFamily: String? {
        let requestedFamily = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requestedFamily.caseInsensitiveCompare(Self.defaultFamily) != .orderedSame else {
            return nil
        }
        return InstalledFontFamilies.byLowercasedName[requestedFamily.lowercased()]
    }

    func size(relativeTo defaultSize: CGFloat) -> CGFloat {
        let validBaseSize = min(max(baseSize, 8), 24)
        return defaultSize * CGFloat(validBaseSize / Self.defaultSize)
    }

    func font(size defaultSize: CGFloat, weight: Font.Weight = .regular) -> Font {
        let resolvedSize = size(relativeTo: defaultSize)
        guard let resolvedFamily else {
            return .system(size: resolvedSize, weight: weight, design: .monospaced)
        }
        return .custom(resolvedFamily, fixedSize: resolvedSize).weight(weight)
    }

    func nsFont(size defaultSize: CGFloat) -> NSFont {
        let resolvedSize = size(relativeTo: defaultSize)
        guard let resolvedFamily else {
            return .monospacedSystemFont(ofSize: resolvedSize, weight: .regular)
        }

        let descriptor = NSFontDescriptor(fontAttributes: [.family: resolvedFamily])
        return NSFont(descriptor: descriptor, size: resolvedSize)
            ?? .monospacedSystemFont(ofSize: resolvedSize, weight: .regular)
    }
}

private enum InstalledFontFamilies {
    static let byLowercasedName = Dictionary(
        NSFontManager.shared.availableFontFamilies.map { ($0.lowercased(), $0) },
        uniquingKeysWith: { first, _ in first }
    )
}

enum TypographyPreferenceKey {
    static let fontFamily = "fontFamily"
    static let fontSize = "fontSize"
}

private struct RuneTypographyKey: EnvironmentKey {
    static let defaultValue = RuneTypography(
        family: RuneTypography.defaultFamily,
        baseSize: RuneTypography.defaultSize
    )
}

extension EnvironmentValues {
    var runeTypography: RuneTypography {
        get { self[RuneTypographyKey.self] }
        set { self[RuneTypographyKey.self] = newValue }
    }
}

extension View {
    func runeFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(RuneFontModifier(size: size, weight: weight))
    }

    func runeTypographyPreferences() -> some View {
        modifier(RuneTypographyPreferencesModifier())
    }
}

private struct RuneFontModifier: ViewModifier {
    @Environment(\.runeTypography) private var typography
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content.font(typography.font(size: size, weight: weight))
    }
}

private struct RuneTypographyPreferencesModifier: ViewModifier {
    @AppStorage(TypographyPreferenceKey.fontFamily)
    private var fontFamily = RuneTypography.defaultFamily
    @AppStorage(TypographyPreferenceKey.fontSize)
    private var fontSize = RuneTypography.defaultSize

    private var typography: RuneTypography {
        RuneTypography(family: fontFamily, baseSize: fontSize)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.runeTypography, typography)
            .font(typography.font(size: RuneTypography.defaultSize))
    }
}
