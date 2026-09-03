import Foundation

enum FuzzyMatcher {
    static func score(_ query: String, in candidate: String) -> Int? {
        let queryCharacters = Array(query.lowercased())
        let candidateCharacters = Array(candidate.lowercased())

        guard !queryCharacters.isEmpty else { return 0 }

        var score = 0
        var searchIndex = 0
        var previousMatchIndex: Int?
        var firstMatchIndex: Int?

        for queryCharacter in queryCharacters {
            guard let matchIndex = candidateCharacters[searchIndex...]
                .firstIndex(of: queryCharacter) else { return nil }

            if firstMatchIndex == nil {
                firstMatchIndex = matchIndex
            }

            score += 10

            if let previousMatchIndex {
                let gap = matchIndex - previousMatchIndex - 1
                if gap == 0 {
                    score += 14
                } else {
                    score -= min(gap, 8)
                }
            }

            if matchIndex == 0 || isBoundary(candidateCharacters[matchIndex - 1]) {
                score += 12
            }

            previousMatchIndex = matchIndex
            searchIndex = matchIndex + 1
        }

        score += max(0, 12 - (firstMatchIndex ?? 0))
        score -= candidateCharacters.count / 20
        return score
    }

    static func pathScore(_ query: String, path: String) -> Int? {
        let pathScore = score(query, in: path)
        let filename = URL(fileURLWithPath: path).lastPathComponent
        let filenameScore = score(query, in: filename).map { $0 + 24 }

        return [pathScore, filenameScore].compactMap { $0 }.max()
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character == "/" || character == "-" || character == "_" ||
            character == "." || character == " "
    }
}
