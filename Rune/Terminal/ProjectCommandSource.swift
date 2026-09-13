import Foundation

nonisolated struct ProjectCommandSource: Identifiable, Sendable {
    let id: String
    let name: String
    let commands: [ProjectCommand]
    let warnings: [String]

    static func discover(in root: URL) -> [ProjectCommandSource] {
        var sources: [ProjectCommandSource] = []
        do {
            sources = try Procfile.discover(in: root).map {
                ProjectCommandSource(id: $0.url.path, name: $0.url.lastPathComponent,
                                     commands: $0.commands, warnings: $0.warnings)
            }
        } catch {
            sources.append(ProjectCommandSource(id: "procfiles", name: "Procfiles", commands: [],
                                                warnings: [error.localizedDescription]))
        }
        if let mise = MiseTasks.discover(in: root) { sources.append(mise) }
        return sources
    }
}

nonisolated enum MiseTasks {
    private struct Entry: Decodable {
        let name: String
        let hide: Bool?
    }

    static func parse(_ data: Data) throws -> [ProjectCommand] {
        var names: Set<String> = []
        // mise treats `--` before the task as arguments for its default task, so exclude option-like names.
        return try JSONDecoder().decode([Entry].self, from: data)
            .filter {
                $0.hide != true && !$0.name.isEmpty && !$0.name.hasPrefix("-") &&
                    !$0.name.contains("\0") && names.insert($0.name).inserted
            }
            .sorted { $0.name < $1.name }
            .map { ProjectCommand(name: $0.name, command: "mise run " + CommandExecution.quote($0.name)) }
    }

    static func discover(in root: URL) -> ProjectCommandSource? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Finder-launched apps do not inherit the shell's PATH.
        let directories = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        guard let executable = directories.filter({ $0.hasPrefix("/") })
            .map({ URL(fileURLWithPath: $0).appendingPathComponent("mise") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return nil }

        do {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["tasks", "ls", "--json", "--local"]
            process.currentDirectoryURL = root
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            // A broken mise configuration must not leave discovery waiting indefinitely.
            let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
            defer { timeout.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return ProjectCommandSource(id: "mise", name: "mise", commands: [],
                    warnings: ["Could not list mise tasks. Run mise tasks ls in the project terminal to check configuration and trust."])
            }
            let commands = try parse(data)
            return commands.isEmpty ? nil : ProjectCommandSource(id: "mise", name: "mise", commands: commands, warnings: [])
        } catch {
            return ProjectCommandSource(id: "mise", name: "mise", commands: [], warnings: [error.localizedDescription])
        }
    }
}
