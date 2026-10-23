import Foundation

/// The MCP tools for the Commands card: list, save, delete, run, stop and restart saved
/// commands. They act on the same store as the card, so the card shows every change.
@MainActor
enum SavedCommandTools {
    static let names: Set<String> = [
        "rune_list_commands", "rune_save_command", "rune_delete_command",
        "rune_run_command", "rune_stop_command", "rune_restart_command",
    ]

    static func handle(_ tool: String, _ arguments: [String: JSONValue], model: ProjectCommands) async -> RuneControlReply {
        guard model.isLoaded else { return .failure("Saved commands have not loaded yet. Try again in a moment.") }
        if tool == "rune_list_commands" { return RuneControlReply(text: await list(model)) }
        if tool == "rune_save_command" { return await save(arguments, model: model) }
        guard let reference = arguments["name"]?.string, !reference.isEmpty else {
            return .failure("Name a saved command by the name or id that rune_list_commands lists.")
        }
        guard let command = find(reference, group: arguments["group"]?.string, in: model) else {
            return .failure("No single saved command is named \(reference). Call rune_list_commands to see them.")
        }
        let isRunning = model.session(for: command)?.isCommandRunning == true
        switch tool {
        case "rune_delete_command":
            if isRunning, !(await model.stop(command)) { return .failure(model.error ?? "Could not stop \(command.name).") }
            await model.delete(command)
            guard !model.commands.contains(where: { $0.id == command.id }) else {
                return .failure(model.error ?? "Could not delete \(command.name).")
            }
            return RuneControlReply(text: isRunning ? "Stopped and deleted \(command.name)." : "Deleted \(command.name).")
        case "rune_run_command":
            if isRunning, let session = model.session(for: command) {
                return RuneControlReply(text: "\(command.name) is already running in pane \(session.id.uuidString).")
            }
            guard let session = model.run(command) else { return .failure(model.error ?? "Could not run \(command.name).") }
            return RuneControlReply(text: "Started \(command.name) in pane \(session.id.uuidString). Read its output with rune_read_terminal.")
        case "rune_stop_command":
            guard isRunning else { return RuneControlReply(text: "\(command.name) is not running.") }
            guard await model.stop(command) else { return .failure(model.error ?? "Could not stop \(command.name).") }
            return RuneControlReply(text: "Stopped \(command.name).")
        case "rune_restart_command":
            guard let session = await model.restart(command) else {
                return .failure(model.error ?? "Could not restart \(command.name).")
            }
            return RuneControlReply(text: "Restarted \(command.name) in pane \(session.id.uuidString).")
        default:
            return .failure("Rune has no tool named \(tool).")
        }
    }

    /// A command by ID, or by name without regard to case. A group narrows the names.
    private static func find(_ reference: String, group: String?, in model: ProjectCommands) -> ProjectCommand? {
        if let id = UUID(uuidString: reference), let command = model.commands.first(where: { $0.id == id }) { return command }
        let matches = model.commands.filter { command in
            command.name.caseInsensitiveCompare(reference) == .orderedSame
                && (group.map { $0.isEmpty ? command.group == nil : command.group == $0 } ?? true)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Every saved command as JSON. A running one lists its pane and the TCP ports its
    /// processes listen on.
    private static func list(_ model: ProjectCommands) async -> String {
        var entries: [[String: Any]] = []
        for command in model.commands {
            var entry: [String: Any] = [
                "id": command.id.uuidString,
                "name": command.name,
                "command": command.command,
                "directory": command.workingDirectory,
                "auto_start": command.autoStart,
                "status": "Not started",
            ]
            if let group = command.group { entry["group"] = group }
            if let session = model.session(for: command) {
                entry["status"] = session.commandStatus
                entry["pane"] = session.id.uuidString
                if session.isCommandRunning, let root = session.rootProcess {
                    // Reads every process in the tree, so it stays off the main thread.
                    let sample = await Task.detached { TerminalProcessMonitor.resources(root: root) }.value
                    entry["ports"] = sample?.ports ?? []
                }
            }
            entries.append(entry)
        }
        let data = (try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Adds a command, or updates the one with the same name. Fields left out keep their value.
    private static func save(_ arguments: [String: JSONValue], model: ProjectCommands) async -> RuneControlReply {
        guard let name = arguments["name"]?.string?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return .failure("Give the command a name.")
        }
        let existing = find(name, group: nil, in: model)
        var command = existing ?? ProjectCommand(name: name, command: "")
        if let shell = arguments["command"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) {
            command.command = shell
        }
        guard !command.command.isEmpty else { return .failure("Give the shell command to run.") }
        if let newName = arguments["new_name"]?.string?.trimmingCharacters(in: .whitespaces), !newName.isEmpty {
            command.name = newName
        }
        if let directory = arguments["directory"]?.string, !directory.isEmpty { command.workingDirectory = directory }
        if let group = arguments["group"]?.string { command.group = group.isEmpty ? nil : group }
        if let autoStart = arguments["auto_start"]?.bool { command.autoStart = autoStart }

        let isTaken = model.commands.contains {
            $0.id != command.id && $0.name.caseInsensitiveCompare(command.name) == .orderedSame
        }
        if isTaken { return .failure("Another saved command is named \(command.name).") }
        var isDirectory: ObjCBool = false
        let directory = command.directory(relativeTo: model.root)
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure("No folder at \(directory.path).")
        }
        guard await model.upsert(command) else { return .failure(model.error ?? "Could not save \(command.name).") }

        guard let existing else { return RuneControlReply(text: "Saved \(command.name). Run it with rune_run_command.") }
        let changesProcess = existing.command != command.command || existing.workingDirectory != command.workingDirectory
        if changesProcess, model.session(for: command)?.isCommandRunning == true {
            return RuneControlReply(text: "Updated \(command.name). It still runs the old command until you restart it.")
        }
        return RuneControlReply(text: "Updated \(command.name).")
    }
}
