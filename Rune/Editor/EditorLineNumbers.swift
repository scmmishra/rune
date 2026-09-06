import Foundation

// UTF-16 offsets match TextKit's character indices, including Unicode and CRLF files.
nonisolated struct EditorLineNumbers {
    struct Row {
        let location: Int
        var old: Int?
        var new: Int?
    }

    let rows: [Row]
    let digits: Int

    init(_ text: String, isDiff: Bool) {
        let source = text as NSString
        var rows: [Row] = []
        var location = 0
        var oldLine = 0, newLine = 0
        var oldRemaining = 0, newRemaining = 0
        var largest = 1

        while location < source.length {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            var row = Row(location: location)
            if isDiff {
                let line = source.substring(with: range) as NSString
                if let match = Self.hunk.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)) {
                    func number(_ group: Int, fallback: Int = 1) -> Int {
                        let range = match.range(at: group)
                        return range.location == NSNotFound ? fallback : Int(line.substring(with: range)) ?? fallback
                    }
                    oldLine = number(1)
                    oldRemaining = number(2)
                    newLine = number(3)
                    newRemaining = number(4)
                } else if line.hasPrefix(" "), oldRemaining > 0, newRemaining > 0 {
                    row.old = oldLine; row.new = newLine
                    oldLine += 1; newLine += 1
                    oldRemaining -= 1; newRemaining -= 1
                } else if line.hasPrefix("-"), oldRemaining > 0 {
                    row.old = oldLine
                    oldLine += 1; oldRemaining -= 1
                } else if line.hasPrefix("+"), newRemaining > 0 {
                    row.new = newLine
                    newLine += 1; newRemaining -= 1
                } else if !line.hasPrefix("\\") {
                    oldRemaining = 0; newRemaining = 0
                }
            } else {
                row.new = rows.count + 1
            }
            largest = max(largest, row.old ?? 0, row.new ?? 0)
            rows.append(row)
            location = NSMaxRange(range)
        }

        // TextKit displays an extra insertion line after a final newline, or in an empty file.
        if !isDiff, source.length == 0 || source.lineRange(for: NSRange(location: source.length, length: 0)).length == 0 {
            rows.append(Row(location: source.length, new: rows.count + 1))
            largest = max(largest, rows.count)
        }
        self.rows = rows
        digits = max(2, String(largest).count)
    }

    func rowIndex(at location: Int) -> Int {
        var low = 0, high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].location <= location { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }

    private static let hunk = try! NSRegularExpression(pattern: "^@@ -(\\d+)(?:,(\\d+))? \\+(\\d+)(?:,(\\d+))? @@")
}
