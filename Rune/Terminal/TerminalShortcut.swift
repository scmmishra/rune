import AppKit

nonisolated enum TerminalShortcut: Equatable {
    case select(Int)
    case cycle(Int)
    case togglePrimary

    static func matching(_ event: NSEvent) -> Self? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .command, event.charactersIgnoringModifiers == "`" {
            return .togglePrimary
        }
        if modifiers == .command,
           let characters = event.charactersIgnoringModifiers,
           let number = Int(characters), (1...9).contains(number) {
            return .select(number)
        }
        // Arrow events also carry function/numeric-pad flags. Only compare the
        // shortcut modifiers, and route before Ghostty's native key equivalents.
        if modifiers == [.command, .option] {
            switch event.keyCode {
            case 126: return .cycle(-1)
            case 125: return .cycle(1)
            default: break
            }
        }
        return nil
    }
}
