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

    private static func isBoundary(_ character: UInt8) -> Bool {
        character == Character("/").asciiValue ||
            character == Character("-").asciiValue ||
            character == Character("_").asciiValue ||
            character == Character(".").asciiValue ||
            character == Character(" ").asciiValue
    }
}
