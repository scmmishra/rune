import Foundation

/// Turns a panel command into arguments. `{{path}}` inserts a value as part of one argument,
/// never as shell text, so a reply containing `"; rm -rf ~` stays a single harmless argument.
/// `[[ … ]]` is an optional chunk, dropped whole when any value inside it is empty.
nonisolated enum PanelTemplate {
    private enum Token {
        case word(String)
        case open
        case close
    }

    static func arguments(_ command: String, context: PanelValue) throws -> [String] {
        var groups: [(arguments: [String], isMissing: Bool)] = [([], false)]
        for token in try tokens(command) {
            switch token {
            case .open: groups.append(([], false))
            case .close:
                guard groups.count > 1 else { throw PanelError("Unbalanced ]] in \(command)") }
                let group = groups.removeLast()
                if !group.isMissing { groups[groups.count - 1].arguments += group.arguments }
            case let .word(word):
                let (text, isMissing) = render(word, context: context)
                groups[groups.count - 1].arguments.append(text)
                if isMissing { groups[groups.count - 1].isMissing = true }
            }
        }
        guard groups.count == 1 else { throw PanelError("Unbalanced [[ in \(command)") }
        guard !groups[0].arguments.isEmpty else { throw PanelError("The command is empty.") }
        return groups[0].arguments
    }

    /// Fills `{{path}}` placeholders; reports whether any of them had no value.
    static func render(_ template: String, context: PanelValue) -> (text: String, isMissing: Bool) {
        var result = ""
        var isMissing = false
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                rest = rest[open.lowerBound...]
                break
            }
            let path = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = context.value(at: path)?.text ?? ""
            if value.isEmpty { isMissing = true }
            result += value
            rest = rest[close.upperBound...]
        }
        return (result + rest, isMissing)
    }

    /// Splits like a shell: whitespace separates words, quotes group them, backslash escapes.
    private static func tokens(_ command: String) throws -> [Token] {
        var tokens: [Token] = []
        var word: String?
        var quote: Character?
        let characters = Array(command)
        var index = 0
        func finish() {
            if let current = word { tokens.append(.word(current)) }
            word = nil
        }
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            index += 1
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"", let next {
                    word!.append(next)
                    index += 1
                } else {
                    word!.append(character)
                }
            } else if character.isWhitespace {
                finish()
            } else if character == "[", next == "[" {
                finish()
                tokens.append(.open)
                index += 1
            } else if character == "]", next == "]" {
                finish()
                tokens.append(.close)
                index += 1
            } else if character == "'" || character == "\"" {
                quote = character
                word = word ?? ""
            } else if character == "\\", let next {
                word = (word ?? "") + String(next)
                index += 1
            } else {
                word = (word ?? "") + String(character)
            }
        }
        guard quote == nil else { throw PanelError("Unterminated quote in \(command)") }
        finish()
        return tokens
    }

    /// The command as the user would type it, for confirmations.
    static func display(_ arguments: [String]) -> String {
        arguments.map { argument in
            argument.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:,@".contains($0) } && !argument.isEmpty
                ? argument : CommandExecution.quote(argument)
        }.joined(separator: " ")
    }
}

/// Runs panel commands directly, without a shell, and maps their output with jq.
nonisolated enum PanelRunner {
    // Finder-launched apps do not inherit the shell's PATH.
    private static let searchPath: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").components(separatedBy: ":")
        var seen: Set<String> = []
        return ([home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] + inherited)
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }()

    static func executable(named name: String) -> URL? {
        if name.contains("/") {
            let url = URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        return searchPath.map { URL(fileURLWithPath: $0).appending(path: name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func run(_ arguments: [String], in directory: URL, input: Data? = nil) async throws -> Data {
        guard let name = arguments.first else { throw PanelError("The command is empty.") }
        guard let executable = executable(named: name) else {
            throw PanelError("\(name) was not found. Install it, or check that it is on your PATH.")
        }
        let process = ProcessHandle()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try process.run(executable, Array(arguments.dropFirst()), in: directory, input: input)
            }.value
        } onCancel: {
            process.terminate()
        }
    }

    /// Runs one jq program over a command's output, so a whole fetch maps in one process.
    static func jq(_ program: String, input: Data, in directory: URL) async throws -> PanelValue {
        // jq ships with macOS 15 and later; prefer it over whichever build is on PATH.
        let jq = FileManager.default.isExecutableFile(atPath: "/usr/bin/jq") ? "/usr/bin/jq" : "jq"
        let output = try await run([jq, "-c", Self.prelude + program], in: directory, input: input)
        return try PanelValue(json: output)
    }

    // MARK: jq programs

    /// Helpers every mapping can use. `relative` formats Unix times and ISO 8601 dates.
    private static let prelude = """
    def _s: if . == null then null elif type == "string" then . else tostring end;
    def relative: (if type == "number" then (if . > 100000000000 then . / 1000 else . end)
        elif type == "string" then (try (sub("\\\\.[0-9]+"; "") | fromdateiso8601) catch null)
        else null end) as $t
      | if $t == null then . else (now - $t) as $d
        | if $d < 60 then "now" elif $d < 3600 then "\\($d / 60 | floor)m"
          elif $d < 86400 then "\\($d / 3600 | floor)h" elif $d < 604800 then "\\($d / 86400 | floor)d"
          else ($t | strftime("%b %d")) end end;

    """

    /// The first value an expression yields, as text; null when it fails or yields nothing.
    private static func field(_ expression: String?) -> String {
        guard let expression else { return "null" }
        return "((try ([\(expression)][0]) catch null) | _s)"
    }

    private static func flag(_ expression: String?, default value: Bool = false) -> String {
        guard let expression else { return value ? "true" : "false" }
        return "((try ([\(expression)][0]) catch null) == true)"
    }

    static func listProgram(_ view: PanelViewSpec, openedActions: [PanelAction]) -> String {
        guard let item = view.item else { return "{items: [], done: true}" }
        // Each badge carries the index of its rule, so its tint can be looked up.
        let badges = item.badges.enumerated().map { index, badge in
            "(if \(flag(badge.when, default: true)) then [(try (\(badge.text)) catch empty) | _s | select(. != null and . != \"\") | {text: ., rule: \(index)}] else [] end)"
        }
        let actions = openedActions.map { flag($0.when, default: true) }
        return """
        {items: [(\(view.each)) | {
          id: \(field(item.id)), title: \(field(item.title)), subtitle: \(field(item.subtitle)),
          trailing: \(field(item.trailing)), unread: \(flag(item.unread)),
          badges: ([\(badges.joined(separator: ", "))] | add // []),
          actions: [\(actions.joined(separator: ", "))], raw: .
        }], done: \(view.pagination.map { flag($0.until, default: true) } ?? "true")}
        """
    }

    static func routeProgram(_ expression: String) -> String { field(expression) }

    /// A detail view's body, plus its `item` and which actions apply to that item.
    static func detailProgram(_ view: PanelViewSpec) -> String {
        let body = view.body.map(bodyProgram) ?? "null"
        guard let item = view.itemExpression else { return "{body: (\(body)), item: null, actions: []}" }
        let actions = view.actions.map { "($item | \(flag($0.when, default: true)))" }
        return "(try ([\(item)][0]) catch null) as $item | {body: (\(body)), item: $item, actions: [\(actions.joined(separator: ", "))]}"
    }

    private static func bodyProgram(_ body: PanelViewSpec.Body) -> String {
        switch body.kind {
        case .markdown: field(body.text)
        case .thread:
            """
            [(\(body.each)) | {author: \(field(body.author)), text: \(field(body.text)), time: \(field(body.time)),
              side: \(field(body.side)), muted: \(flag(body.muted))}]
            """
        }
    }

    static func optionsProgram(_ source: PanelInput.Source) -> String {
        "[(\(source.each)) | {label: \(field(source.label)), value: \(field(source.value))}]"
    }
}

/// Owns one child process so cancellation can reach it from another task.
nonisolated private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func terminate() {
        lock.withLock {
            isCancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }

    func run(_ executable: URL, _ arguments: [String], in directory: URL, input: Data?) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin

        try lock.withLock {
            guard !isCancelled else { throw CancellationError() }
            try process.run()
            self.process = process
        }
        // A hung command must not leave the panel loading forever.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        defer { timeout.cancel() }

        // Feed input and drain stderr on their own threads so neither pipe can fill and stall.
        if let input {
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        nonisolated(unsafe) var errorData = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()

        if lock.withLock({ isCancelled }) { throw CancellationError() }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let name = executable.lastPathComponent
            let details = String(decoding: errorData.suffix(800), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationReason == .uncaughtSignal { throw PanelError("\(name) took too long and was stopped.") }
            throw PanelError("\(name) exited with status \(process.terminationStatus)." + (details.isEmpty ? "" : "\n\(details)"))
        }
        return data
    }
}
