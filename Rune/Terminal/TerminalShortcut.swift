import AppKit

nonisolated enum TerminalShortcut: Equatable {
    case select(Int)
    case peek(Int)
    case cycle(Int)
    case togglePrimary
    /// ⌘D: show the last-used terminal beside the panel, or close that peek again.
    case peekRecent

    static func matching(_ event: NSEvent) -> Self? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .command, event.charactersIgnoringModifiers == "`" {
            return .togglePrimary
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "d" {
            return .peekRecent
        }
        if let characters = event.charactersIgnoringModifiers,
           let number = Int(characters), (1...9).contains(number) {
            // Command opens a session in the panel; adding Option opens it beside.
            if modifiers == .command { return .select(number) }
            if modifiers == [.command, .option] { return .peek(number) }
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

/// Tells a ⌘-number tap from a hold. A tap switches terminals when the key comes back up;
/// holding past the threshold peeks until the key (or Command) is released. The caller owns
/// the timer and passes back the token from `press`, so a timer from an earlier press can
/// never fire a later one.
nonisolated struct TerminalHoldGesture {
    /// Taps last roughly 80–150 ms, so 200 ms still clears a slow tap while making the peek
    /// feel immediate, and it decides well before macOS starts repeating a held key.
    static let threshold: Duration = .milliseconds(200)

    enum Outcome: Equatable {
        case select(Int)
        case peek(Int)
        /// The held key was let go: put the peek away again.
        case endPeek
    }

    private enum State {
        case idle
        case pending(number: Int, keyCode: UInt16, token: Int)
        case holding(keyCode: UInt16)
    }

    private var state = State.idle
    private var nextToken = 0

    /// Starts a press and returns the token its hold timer must pass to `expire`.
    mutating func press(number: Int, keyCode: UInt16) -> Int {
        nextToken += 1
        state = .pending(number: number, keyCode: keyCode, token: nextToken)
        return nextToken
    }

    /// The number key came back up: a tap if it was quick, the end of a peek if it was held.
    mutating func release(keyCode: UInt16) -> Outcome? {
        switch state {
        case let .pending(number, code, _) where code == keyCode:
            state = .idle
            return .select(number)
        case let .holding(code) where code == keyCode:
            state = .idle
            return .endPeek
        default:
            return nil
        }
    }

    /// Command came up. macOS may withhold key-up events while Command is down, so this
    /// also settles a press whose key-up never arrived.
    mutating func releaseCommand() -> Outcome? {
        switch state {
        case let .pending(number, _, _):
            state = .idle
            return .select(number)
        case .holding:
            state = .idle
            return .endPeek
        case .idle:
            return nil
        }
    }

    /// The hold timer fired while the key was still down: a peek.
    mutating func expire(token: Int) -> Outcome? {
        guard case let .pending(number, keyCode, pendingToken) = state, pendingToken == token else { return nil }
        state = .holding(keyCode: keyCode)
        return .peek(number)
    }

    mutating func cancel() { state = .idle }
}
