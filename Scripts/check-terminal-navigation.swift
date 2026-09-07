import AppKit

@main
struct TerminalNavigationChecks {
    static func main() {
        let primary = UUID()
        let first = UUID()
        let second = UUID()
        var navigation = TerminalNavigation(primaryID: primary)
        precondition(navigation.toggleTarget == primary)
        precondition(navigation.neighbor(in: -1) == primary)
        precondition(navigation.neighbor(in: 1) == primary)
        navigation.add(first)
        navigation.add(second)
        precondition(navigation.shortcutNumber(for: primary) == nil)
        precondition(navigation.sessionID(forShortcut: 1) == first)
        precondition(navigation.sessionID(forShortcut: 2) == second)
        precondition(navigation.toggleTarget == first)
        precondition(navigation.neighbor(in: -1) == second)
        navigation.select(first)
        precondition(navigation.neighbor(in: -1) == primary)
        precondition(navigation.neighbor(in: 1) == second)
        navigation.select(second)
        precondition(navigation.neighbor(in: 1) == primary)
        precondition(navigation.toggleTarget == primary)
        navigation.select(navigation.toggleTarget)
        precondition(navigation.toggleTarget == second, "Toggling from primary returns to last-used secondary")
        navigation.select(navigation.toggleTarget)
        navigation.select(first)
        navigation.select(first)
        navigation.remove(first)
        precondition(navigation.activeID == second, "Closing active terminal must return to the last used survivor")
        precondition(navigation.sessionID(forShortcut: 2) == second, "Closing a session must not renumber others")
        precondition(navigation.sessionID(forShortcut: 1) == nil)

        let replacement = UUID()
        navigation.add(replacement)
        precondition(navigation.sessionID(forShortcut: 1) == replacement)
        navigation.remove(replacement)
        precondition(navigation.activeID == second, "Closing inactive terminal must preserve selection")
        navigation.remove(primary)
        precondition(navigation.sessionIDs.contains(primary))
        navigation.select(UUID())
        precondition(navigation.activeID == second)
        navigation.remove(second)
        precondition(navigation.activeID == primary)

        let supporting = (0..<10).map { _ in UUID() }
        supporting.forEach { navigation.add($0) }
        precondition(navigation.shortcutNumber(for: supporting[8]) == 9)
        precondition(navigation.shortcutNumber(for: supporting[9]) == nil)
        navigation.select(supporting[9])
        precondition(navigation.neighbor(in: 1) == primary, "Unnumbered terminals must participate in cycling")
        navigation.remove(supporting[0])
        precondition(navigation.shortcutNumber(for: supporting[9]) == nil, "Existing sessions must not acquire different shortcuts")

        for type in [NSEvent.EventType.keyDown, .keyUp] {
            for number in 1...9 {
                precondition(TerminalShortcut.matching(event(type, 18, String(number), .command)) == .select(number))
            }
            precondition(TerminalShortcut.matching(event(type, 50, "`", .command)) == .togglePrimary)
            precondition(TerminalShortcut.matching(event(type, 50, "`", [.command, .shift])) == nil)
            let arrowFlags: NSEvent.ModifierFlags = [.command, .option, .function, .numericPad]
            precondition(TerminalShortcut.matching(event(type, 126, "\u{F700}", arrowFlags)) == .cycle(-1))
            precondition(TerminalShortcut.matching(event(type, 125, "\u{F701}", arrowFlags)) == .cycle(1))
            precondition(TerminalShortcut.matching(event(type, 123, "\u{F702}", arrowFlags)) == nil)
            precondition(TerminalShortcut.matching(event(type, 125, "\u{F701}", [.command, .option, .shift])) == nil)
            precondition(TerminalShortcut.matching(event(type, 125, "\u{F701}", [])) == nil)
            precondition(TerminalShortcut.matching(event(type, 53, "\u{1B}", [])) == nil)
            precondition(TerminalShortcut.matching(event(type, 18, "1", [.command, .control])) == nil)
            precondition(TerminalShortcut.matching(event(type, 29, "0", .command)) == nil)
        }
        print("Terminal navigation and shortcut checks passed")
    }

    private static func event(
        _ type: NSEvent.EventType, _ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers,
            timestamp: 1, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code
        )!
    }
}
