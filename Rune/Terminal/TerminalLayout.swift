import Foundation

enum TerminalLayout: String, CaseIterable {
    case slideovers
    case tabs

    static let preferenceKey = "terminalLayout"

    var title: String {
        switch self {
        case .slideovers: "Slideovers"
        case .tabs: "Tabs"
        }
    }

    var caption: String {
        switch self {
        case .slideovers: "Keep your main terminal in view"
        case .tabs: "Give each terminal the full space"
        }
    }
}
