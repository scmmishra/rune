import Foundation

/// A JSON-shaped value: what panel files parse into, and what commands print.
nonisolated enum PanelValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PanelValue])
    case object([String: PanelValue])

    init(json data: Data) throws {
        self.init(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init(any value: Any) {
        switch value {
        // NSNumber bridges both; check the Core Foundation type so `1` never reads as `true`.
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool(number.boolValue)
        case let number as NSNumber: self = .number(number.doubleValue)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map(PanelValue.init(any:)))
        case let object as [String: Any]: self = .object(object.mapValues(PanelValue.init(any:)))
        default: self = .null
        }
    }

    subscript(key: String) -> PanelValue? {
        if case let .object(object) = self { object[key] } else { nil }
    }

    /// Looks up a dotted path such as `meta.sender.name`; numeric parts index arrays.
    func value(at path: some StringProtocol) -> PanelValue? {
        var current = self
        for part in path.split(separator: ".") {
            switch current {
            case let .object(object): guard let next = object[String(part)] else { return nil }; current = next
            case let .array(array): guard let index = Int(part), array.indices.contains(index) else { return nil }; current = array[index]
            default: return nil
            }
        }
        return current
    }

    var string: String? {
        if case let .string(string) = self { string } else { nil }
    }

    var array: [PanelValue]? {
        if case let .array(array) = self { array } else { nil }
    }

    var bool: Bool? {
        if case let .bool(bool) = self { bool } else { nil }
    }

    /// The value as it reads in a command or title; empty for null and containers.
    var text: String {
        switch self {
        case .null, .array, .object: ""
        case let .bool(bool): bool ? "true" : "false"
        case let .number(number):
            number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case let .string(string): string
        }
    }
}

/// The subset of TOML panel files use: tables, arrays of tables, dotted headers, strings
/// (basic, literal, multi-line), numbers, booleans, arrays and inline tables.
nonisolated struct TOMLParser {
    struct Failure: LocalizedError {
        let line: Int
        let message: String
        var errorDescription: String? { "Line \(line): \(message)" }
    }

    private let characters: [Character]
    private var index = 0
    private var line = 1

    static func parse(_ source: String) throws -> PanelValue {
        var parser = TOMLParser(characters: Array(source))
        return try parser.document()
    }

    private init(characters: [Character]) {
        self.characters = characters
    }

    private mutating func document() throws -> PanelValue {
        var root = PanelValue.object([:])
        var table: [String] = []
        while true {
            skipWhitespace(newlines: true)
            guard let character = peek else { break }
            if character == "[" {
                let isArray = peek(offset: 1) == "["
                index += isArray ? 2 : 1
                skipWhitespace(newlines: false)
                let path = try key()
                skipWhitespace(newlines: false)
                guard take("]"), !isArray || take("]") else { throw fail("Expected ] to close the table header") }
                table = path
                try insert(isArray ? .array([.object([:])]) : .object([:]), at: path, in: &root, appending: isArray)
            } else {
                let path = try key()
                skipWhitespace(newlines: false)
                guard take("=") else { throw fail("Expected = after \(path.joined(separator: "."))") }
                skipWhitespace(newlines: false)
                try insert(try value(), at: table + path, in: &root, appending: false)
            }
            skipWhitespace(newlines: false)
            guard peek == nil || peek?.isNewline == true else { throw fail("Unexpected text after value") }
        }
        return root
    }

    /// Writes into the last element of any array of tables along the way, as TOML does.
    private func insert(_ value: PanelValue, at path: [String], in node: inout PanelValue, appending: Bool) throws {
        switch node {
        case var .array(elements):
            guard !elements.isEmpty else { throw fail("Cannot add to an empty array") }
            try insert(value, at: path, in: &elements[elements.count - 1], appending: appending)
            node = .array(elements)
        case var .object(object):
            let key = path[0]
            if path.count == 1 {
                switch (object[key], value) {
                case (nil, _): object[key] = value
                case let (.array(existing)?, .array(added)) where appending: object[key] = .array(existing + added)
                // A header naming a table that dotted keys already started.
                case (.object?, .object) where !appending: break
                default: throw fail("\(key) is defined twice")
                }
            } else {
                var child = object[key] ?? .object([:])
                try insert(value, at: Array(path.dropFirst()), in: &child, appending: appending)
                object[key] = child
            }
            node = .object(object)
        default:
            throw fail("\(path[0]) is not a table")
        }
    }

    private mutating func key() throws -> [String] {
        var parts: [String] = []
        repeat {
            skipWhitespace(newlines: false)
            if peek == "\"" || peek == "'" {
                parts.append(try stringValue())
            } else {
                let start = index
                while let character = peek, character.isLetter || character.isNumber || character == "_" || character == "-" { index += 1 }
                guard index > start else { throw fail("Expected a key") }
                parts.append(String(characters[start..<index]))
            }
            skipWhitespace(newlines: false)
        } while take(".")
        return parts
    }

    private mutating func value() throws -> PanelValue {
        switch peek {
        case "\"", "'": return .string(try stringValue())
        case "[":
            index += 1
            var elements: [PanelValue] = []
            while true {
                skipWhitespace(newlines: true)
                if take("]") { return .array(elements) }
                elements.append(try value())
                skipWhitespace(newlines: true)
                if take("]") { return .array(elements) }
                guard take(",") else { throw fail("Expected , or ] in array") }
            }
        case "{":
            index += 1
            var table = PanelValue.object([:])
            skipWhitespace(newlines: false)
            if take("}") { return table }
            while true {
                let path = try key()
                guard take("=") else { throw fail("Expected = in inline table") }
                skipWhitespace(newlines: false)
                try insert(try value(), at: path, in: &table, appending: false)
                skipWhitespace(newlines: false)
                if take("}") { return table }
                guard take(",") else { throw fail("Expected , or } in inline table") }
            }
        default:
            let start = index
            while let character = peek, !",]}\n#".contains(character), !character.isWhitespace { index += 1 }
            let word = String(characters[start..<index])
            if word == "true" { return .bool(true) }
            if word == "false" { return .bool(false) }
            if let number = Double(word.replacingOccurrences(of: "_", with: "")) { return .number(number) }
            throw fail(word.isEmpty ? "Expected a value" : "Unsupported value \(word)")
        }
    }

    private mutating func stringValue() throws -> String {
        let quote = characters[index]
        let isLiteral = quote == "'"
        let isMultiline = peek(offset: 1) == quote && peek(offset: 2) == quote
        index += isMultiline ? 3 : 1
        // Swift reads \r\n as one Character, so line breaks are matched with isNewline.
        // A newline right after the opening delimiter is not part of the string.
        if isMultiline, peek?.isNewline == true { index += 1; line += 1 }
        var result = ""
        while let character = peek {
            if character == quote {
                if !isMultiline { index += 1; return result }
                if peek(offset: 1) == quote, peek(offset: 2) == quote {
                    index += 3
                    return result
                }
            }
            if character.isNewline {
                guard isMultiline else { throw fail("Unterminated string") }
                line += 1
            }
            index += 1
            if character == "\\", !isLiteral {
                guard let escaped = peek else { break }
                index += 1
                switch escaped {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case _ where escaped.isNewline && isMultiline:
                    // A trailing backslash joins the next line, dropping its indentation.
                    line += 1
                    skipWhitespace(newlines: true)
                default: throw fail("Unsupported escape \\\(escaped)")
                }
            } else {
                result.append(character)
            }
        }
        throw fail("Unterminated string")
    }

    private mutating func skipWhitespace(newlines: Bool) {
        while let character = peek {
            if character == "#" {
                while let next = peek, !next.isNewline { index += 1 }
            } else if character.isNewline {
                guard newlines else { return }
                line += 1
                index += 1
            } else if character.isWhitespace {
                index += 1
            } else {
                return
            }
        }
    }

    private var peek: Character? { index < characters.count ? characters[index] : nil }

    private func peek(offset: Int) -> Character? {
        index + offset < characters.count ? characters[index + offset] : nil
    }

    private mutating func take(_ character: Character) -> Bool {
        guard peek == character else { return false }
        index += 1
        return true
    }

    private func fail(_ message: String) -> Failure { Failure(line: line, message: message) }
}
