import Foundation

nonisolated enum FuzzyMatcher {
    static func pathScore(
        _ normalizedQuery: [UInt8],
        path: String,
        filename: String
    ) -> Int? {
        let pathScore = score(normalizedQuery, in: path.utf8)
        let filenameScore = score(normalizedQuery, in: filename.utf8).map { $0 + 24 }

        return [pathScore, filenameScore].compactMap { $0 }.max()
    }

    private static func score(
        _ query: [UInt8],
        in candidate: String.UTF8View
    ) -> Int? {
        guard !query.isEmpty else { return 0 }

        var score = 0
        var queryIndex = 0
        var candidateIndex = 0
        var previousMatchIndex: Int?
        var firstMatchIndex: Int?
        var previousCharacter: UInt8?

        for character in candidate {
            defer {
                previousCharacter = character
                candidateIndex += 1
            }

            guard character == query[queryIndex] else { continue }

            if firstMatchIndex == nil {
                firstMatchIndex = candidateIndex
            }

            score += 10

            if let previousMatchIndex {
                let gap = candidateIndex - previousMatchIndex - 1
                if gap == 0 {
                    score += 14
                } else {
                    score -= min(gap, 8)
                }
            }

            if candidateIndex == 0 || previousCharacter.map(isBoundary) == true {
                score += 12
            }

            previousMatchIndex = candidateIndex
            queryIndex += 1

            if queryIndex == query.count {
                score += max(0, 12 - (firstMatchIndex ?? 0))
                score -= candidate.count / 20
                return score
            }
        }

        return nil
    }

    /// True when the query is a substring of the candidate or spells prefixes of successive words
    /// ("opchat" in "open project chatwoot"), unlike a scattered hit such as "chat" in "check for updates".
    static func isCoherent(_ normalizedQuery: [UInt8], in candidate: String) -> Bool {
        guard !normalizedQuery.isEmpty else { return true }
        if candidate.contains(String(decoding: normalizedQuery, as: UTF8.self)) { return true }
        let words = candidate.utf8.split { $0 < 128 && !isAlphanumeric($0) }.map(Array.init)
        return matchesWordPrefixes(normalizedQuery.filter { $0 != 32 }[...], words[...])
    }

    private static func matchesWordPrefixes(_ query: ArraySlice<UInt8>, _ words: ArraySlice<[UInt8]>) -> Bool {
        guard let first = query.first else { return true }
        for (offset, word) in zip(words.indices, words) where word.first == first {
            var length = 0
            while length < min(word.count, query.count), word[length] == query[query.startIndex + length] {
                length += 1
                if matchesWordPrefixes(query.dropFirst(length), words[(offset + 1)...]) { return true }
            }
        }
        return false
    }

    private static func isAlphanumeric(_ character: UInt8) -> Bool {
        (48...57).contains(character) || (97...122).contains(character) || (65...90).contains(character)
    }

    private static func isBoundary(_ character: UInt8) -> Bool {
        character == Character("/").asciiValue ||
            character == Character("-").asciiValue ||
            character == Character("_").asciiValue ||
            character == Character(".").asciiValue ||
            character == Character(" ").asciiValue
    }
}
