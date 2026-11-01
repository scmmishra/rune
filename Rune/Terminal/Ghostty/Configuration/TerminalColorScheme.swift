//
//  TerminalColorScheme.swift
//  libghostty-spm
//

import GhosttyKit

public nonisolated enum TerminalColorScheme: Sendable {
    case light
    case dark

    var ghosttyValue: ghostty_color_scheme_e {
        switch self {
        case .light: GHOSTTY_COLOR_SCHEME_LIGHT
        case .dark: GHOSTTY_COLOR_SCHEME_DARK
        }
    }
}
