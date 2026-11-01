import Foundation

/// Session order and the most recently used terminal.
nonisolated struct TerminalNavigation {
    /// Where the keyboard is: the panel session, or one of the peeks.
    private(set) var activeID: UUID
    /// The session filling the terminal panel.
    private(set) var panelID: UUID
    /// Sessions open beside the panel, oldest first. They keep their tabs.
    private(set) var peekedIDs: [UUID] = []
    private(set) var sessionIDs: [UUID]
    private var recentIDs: [UUID]

    init(firstID: UUID) {
        activeID = firstID
        panelID = firstID
        sessionIDs = [firstID]
        recentIDs = [firstID]
    }

    mutating func add(_ id: UUID) {
        guard !sessionIDs.contains(id) else { return }
        sessionIDs.append(id)
    }

    /// Puts tabs in `tabIDs` order, so cycling follows the tab row. Saved commands share the
    /// list, and each keeps its slot.
    mutating func orderTabs(_ tabIDs: [UUID]) {
        var next = tabIDs.makeIterator()
        sessionIDs = sessionIDs.map { tabIDs.contains($0) ? next.next() ?? $0 : $0 }
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
            // With nothing else to fill the panel, the session stays in it.
            guard let next = recentIDs.first(where: { $0 != id && !peekedIDs.contains($0) })
                ?? sessionIDs.first(where: { $0 != id && !peekedIDs.contains($0) }) else { return }
            panelID = next
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

    private mutating func focus(_ id: UUID) {
        activeID = id
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
    }

    /// The session before or after the active one.
    func neighbor(in direction: Int) -> UUID {
        let index = sessionIDs.firstIndex(of: activeID) ?? 0
        let offset = direction < 0 ? -1 : 1
        return sessionIDs[(index + offset + sessionIDs.count) % sessionIDs.count]
    }

    /// The session used before the active one.
    var toggleTarget: UUID {
        recentIDs.first { $0 != activeID } ?? sessionIDs.first { $0 != activeID } ?? activeID
    }

    /// The caller keeps one session open, so the panel always has something to show.
    mutating func remove(_ id: UUID) {
        sessionIDs.removeAll { $0 == id }
        recentIDs.removeAll { $0 == id }
        peekedIDs.removeAll { $0 == id }
        if panelID == id, let next = recentIDs.first(where: { !peekedIDs.contains($0) })
            ?? sessionIDs.first(where: { !peekedIDs.contains($0) }) ?? sessionIDs.first {
            panelID = next
            peekedIDs.removeAll { $0 == next }
        }
        if activeID == id { activeID = recentIDs.first ?? panelID }
    }
}
