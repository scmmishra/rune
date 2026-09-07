import Foundation

/// Session order, stable number shortcuts, and the most recently used terminal.
nonisolated struct TerminalNavigation {
    let primaryID: UUID
    private(set) var activeID: UUID
    private(set) var sessionIDs: [UUID]
    private var recentIDs: [UUID]
    private var shortcutNumbers: [UUID: Int]

    init(primaryID: UUID) {
        self.primaryID = primaryID
        activeID = primaryID
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

    mutating func select(_ id: UUID) {
        guard sessionIDs.contains(id), activeID != id else { return }
        activeID = id
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
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
        if activeID == id { activeID = recentIDs.first ?? primaryID }
    }
}
