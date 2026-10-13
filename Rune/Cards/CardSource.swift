import Foundation

/// One row a source returns.
nonisolated struct CardItem: Identifiable, Equatable, Sendable {
    struct Badge: Equatable, Sendable {
        let text: String
        /// A colour name such as "green"; unknown names draw in grey.
        let tint: String?
    }

    let id: String
    let title: String
    var subtitle: String?
    var badge: Badge?
    var action: CardAction?
}

/// What happens when an item is clicked.
nonisolated enum CardAction: Equatable, Sendable {
    case open(URL)
    /// A path, with an optional `:line`, relative to the repository.
    case file(String)
    case set([String: String])
}

/// What a source printed.
nonisolated struct CardContent: Equatable, Sendable {
    var items: [CardItem] = []
    /// Shown when there are no items.
    var empty: String?
}

/// Runs a card's source and reads the JSON it prints.
nonisolated enum CardSourceRunner {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static let timeout: TimeInterval = 10
    /// Far more than a card can show; a source printing more than this has gone wrong.
    private static let outputLimit = 2_000_000

    /// Runs the source in the repository and returns its content. Blocks until the source
    /// exits or times out, so call it off the main thread.
    static func run(_ card: CustomCard, root: URL, branch: String, variables: [String: String]) throws -> CardContent {
        guard let source = card.source else { throw Failure(card.problem ?? "The card has no source.") }
        let process = Process()
        switch source {
        case let .script(script):
            // The script is one argument to bash, never text spliced into a command line.
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", script]
        case let .file(file):
            guard FileManager.default.isExecutableFile(atPath: file.path) else {
                throw Failure("\(file.lastPathComponent) is not an executable file.")
            }
            process.executableURL = file
        }
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = LoginEnvironment.path
        environment["RUNE_REPO"] = root.path
        environment["RUNE_BRANCH"] = branch
        for name in card.reads { environment["RUNE_VAR_" + name.uppercased()] = variables[name] ?? "" }
        process.environment = environment

        // Files, not pipes: a pipe fills and stalls the source, and a child the source left
        // running would hold a pipe open long after the source itself has exited.
        let scratch = FileManager.default.temporaryDirectory.appending(path: "rune-card-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outputFile = scratch.appending(path: "out")
        let errorFile = scratch.appending(path: "err")
        for file in [outputFile, errorFile] { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let output = try FileHandle(forWritingTo: outputFile)
        let errors = try FileHandle(forWritingTo: errorFile)
        defer {
            try? output.close()
            try? errors.close()
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            throw Failure("The source ran longer than \(Int(timeout)) seconds.")
        }

        let printed = try read(outputFile)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: try read(errorFile), as: UTF8.self)
                .split(whereSeparator: \.isNewline).first.map(String.init)
            throw Failure(message ?? "The source exited with status \(process.terminationStatus).")
        }
        return try parse(printed)
    }

    private static func read(_ file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try handle.read(upToCount: outputLimit) ?? Data()
    }

    static func parse(_ data: Data) throws -> CardContent {
        guard !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else {
            throw Failure("The source printed nothing.")
        }
        guard let value = try? JSONValue(json: data), let object = value.object else {
            throw Failure("The source did not print a JSON object.")
        }
        guard let rows = object["items"]?.array else { throw Failure("The output has no \"items\" list.") }
        var seen: Set<String> = []
        var content = CardContent(empty: object["empty"]?.string)
        for (index, row) in rows.enumerated() {
            // Numbers are accepted as IDs and titles; sources print them unquoted often enough.
            guard let id = row["id"].map(\.text), !id.isEmpty else { throw Failure("Item \(index + 1) has no id.") }
            guard let title = row["title"].map(\.text), !title.isEmpty else { throw Failure("Item \(id) has no title.") }
            guard seen.insert(id).inserted else { throw Failure("Two items share the id \(id).") }
            var item = CardItem(id: id, title: title)
            item.subtitle = row["subtitle"].map(\.text).flatMap { $0.isEmpty ? nil : $0 }
            if let badge = row["badge"], let text = (badge.string ?? badge["text"]?.text), !text.isEmpty {
                item.badge = CardItem.Badge(text: text, tint: badge["tint"]?.string)
            }
            if let action = row["action"] { item.action = try self.action(from: action, item: id) }
            content.items.append(item)
        }
        return content
    }

    private static func action(from value: JSONValue, item: String) throws -> CardAction {
        if let text = value["open"]?.string {
            // Only web links: an item must not be able to launch an arbitrary app or file.
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw Failure("Item \(item) opens \(text), which is not a web link.")
            }
            return .open(url)
        }
        if let path = value["file"]?.string, !path.isEmpty { return .file(path) }
        if let values = value["set"]?.object, !values.isEmpty {
            guard values.keys.allSatisfy(SpaceVariables.isValidName) else {
                throw Failure("Item \(item) sets a variable whose name is not letters, digits and underscores.")
            }
            return .set(values.mapValues(\.text))
        }
        throw Failure("Item \(item) has an action Rune does not know. Use open, file or set.")
    }
}

/// The search path of the user's login shell. An app started from the Dock gets only the
/// system's directories, where tools such as `gh` and `jq` are not.
nonisolated enum LoginEnvironment {
    private static let marker = "__RUNE_PATH__"

    /// Resolved once, on first use, by asking the login shell. Blocks for as long as the
    /// shell takes to start, so the first use must be off the main thread.
    static let path: String = {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        // Used when the shell cannot be asked: the usual homes of installed tools.
        let fallback = "/opt/homebrew/bin:/usr/local/bin:" + inherited
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Interactive as well as login: many setups extend PATH in the interactive startup file.
        // fish keeps PATH as a list, which has to be joined to read as one.
        let value = shell.hasSuffix("/fish") ? "(string join : $PATH)" : "\"$PATH\""
        process.arguments = ["-l", "-i", "-c", "printf '%s%s%s' \(marker) \(value) \(marker)"]
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return fallback }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard !process.isRunning else {
            process.terminate()
            return fallback
        }
        // Startup files may print around it, so the path is read from between two markers.
        let text = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3, !parts[1].isEmpty else { return fallback }
        return parts[1]
    }()
}
