import Foundation

/// Session order, stable number shortcuts, and the most recently used terminal.
nonisolated struct TerminalNavigation {
    let primaryID: UUID
    /// Where the keyboard is: the panel session, or one of the peeks.
    private(set) var activeID: UUID
    /// The session filling the terminal panel.
    private(set) var panelID: UUID
    /// Sessions open beside the panel, oldest first. They keep their tabs.
    private(set) var peekedIDs: [UUID] = []
    private(set) var sessionIDs: [UUID]
    private var recentIDs: [UUID]
    private var shortcutNumbers: [UUID: Int]

    init(primaryID: UUID) {
        self.primaryID = primaryID
        activeID = primaryID
        panelID = primaryID
        sessionIDs = [primaryID]
        recentIDs = [primaryID]
        shortcutNumbers = [:]
    }

    func shortcutNumber(for id: UUID) -> Int? { shortcutNumbers[id] }

    func sessionID(forShortcut number: Int) -> UUID? {
        shortcutNumbers.first { $0.value == number }?.key
    }

    mutating func add(_ id: UUID) {
        guard !sessionIDs.contains(id) else { return }
        sessionIDs.append(id)
        // Reuse vacant slots only for new sessions; never renumber surviving ones.
        shortcutNumbers[id] = (1...9).first { !shortcutNumbers.values.contains($0) }
    }

    func isPeeked(_ id: UUID) -> Bool { peekedIDs.contains(id) }

    /// Bring a session into the panel and focus it. A peeked session comes back in.
    mutating func select(_ id: UUID) {
        guard sessionIDs.contains(id) else { return }
        peekedIDs.removeAll { $0 == id }
        panelID = id
        guard activeID != id else { return }
        focus(id)
    }

    /// Open a session beside the panel, or close it if it is already there.
    /// The panel never empties: pushing its session out pulls in the next recent one.
    mutating func peek(_ id: UUID, limit: Int) {
        guard sessionIDs.contains(id) else { return }
        if peekedIDs.contains(id) {
            peekedIDs.removeAll { $0 == id }
            if activeID == id { focus(panelID) }
            return
        }
        if panelID == id {
            panelID = recentIDs.first { $0 != id && !peekedIDs.contains($0) }
                ?? sessionIDs.first { $0 != id && !peekedIDs.contains($0) }
                ?? primaryID
        }
        peekedIDs.append(id)
        // A terminal below a handful of rows is unreadable, so the oldest peek
        // gives way rather than dividing the column further.
        if peekedIDs.count > limit { peekedIDs.removeFirst() }
        // Opening a peek does not move the keyboard: you peek to watch something
        // while you keep working. Clicking into it is what gives it focus.
        if !sessionIDs.contains(activeID) { focus(panelID) }
    }

    /// Close one peek by identity, rather than whichever one has focus.
    mutating func closePeek(_ id: UUID) {
        guard peekedIDs.contains(id) else { return }
        peekedIDs.removeAll { $0 == id }
        if activeID == id { focus(panelID) }
    }

    /// Move focus between the panel and the peek column without changing either.
    mutating func focusNextSurface() {
        guard !peekedIDs.isEmpty else { return }
        if activeID == panelID {
            focus(peekedIDs.first ?? panelID)
        } else if let index = peekedIDs.firstIndex(of: activeID) {
            focus(index + 1 < peekedIDs.count ? peekedIDs[index + 1] : panelID)
        } else {
            focus(panelID)
        }
    }

    /// Move the keyboard to a session without changing where it is shown.
    mutating func focusOnly(_ id: UUID) {
        guard sessionIDs.contains(id), activeID != id else { return }
        focus(id)
    }

    private mutating func focus(_ id: UUID) {
        activeID = id
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
    }

    /// The most recently used session that is not already on screen, for ⌘D.
    func recentPeekCandidate(among candidates: Set<UUID>) -> UUID? {
        let hidden = { (id: UUID) in candidates.contains(id) && id != self.panelID && !self.peekedIDs.contains(id) }
        return recentIDs.first(where: hidden) ?? sessionIDs.first(where: hidden)
    }

    func neighbor(in direction: Int) -> UUID {
        let index = sessionIDs.firstIndex(of: activeID) ?? 0
        let offset = direction < 0 ? -1 : 1
        return sessionIDs[(index + offset + sessionIDs.count) % sessionIDs.count]
    }

    var toggleTarget: UUID {
        guard activeID == primaryID else { return primaryID }
        return recentIDs.first { $0 != primaryID } ?? sessionIDs.dropFirst().first ?? primaryID
    }

    mutating func remove(_ id: UUID) {
        guard id != primaryID else { return }
        sessionIDs.removeAll { $0 == id }
        shortcutNumbers[id] = nil
        recentIDs.removeAll { $0 == id }
        peekedIDs.removeAll { $0 == id }
        if panelID == id { panelID = recentIDs.first { !peekedIDs.contains($0) } ?? primaryID }
        if activeID == id { activeID = recentIDs.first ?? primaryID }
    }
}
