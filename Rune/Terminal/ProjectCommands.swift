import Foundation
import Combine

@MainActor
final class ProjectCommands: ObservableObject {
    @Published private(set) var commands: [ProjectCommand] = []
    @Published private(set) var sources: [ProjectCommandSource] = []
    @Published private(set) var isDiscovering = false
    @Published private(set) var isLoaded = false
    @Published private(set) var isSaving = false
    @Published private(set) var busyIDs: Set<UUID> = []
    @Published var error: String?
    /// Group names shown expanded in the sidebar, remembered per project across relaunches.
    @Published private(set) var expandedGroups: Set<String>
    let root: URL
    let sessions: TerminalSessions
    private let storage: ProjectCommandStorage
    private var isLoading = false

    init(root: URL, sessions: TerminalSessions) {
        self.root = root
        self.sessions = sessions
        storage = ProjectCommandStorage(root: root)
        expandedGroups = Set(UserDefaults.standard.stringArray(forKey: Self.expandedGroupsKey(for: root)) ?? [])
    }

    private static func expandedGroupsKey(for root: URL) -> String {
        "expandedCommandGroups:" + root.resolvingSymlinksInPath().standardizedFileURL.path
    }

    struct Group: Identifiable {
        let name: String
        let commands: [ProjectCommand]
        var id: String { name }
    }

    /// Groups in the order their first command was saved.
    var groups: [Group] {
        var order: [String] = []
        var members: [String: [ProjectCommand]] = [:]
        for command in commands {
            guard let group = command.group else { continue }
            if members[group] == nil { order.append(group) }
            members[group, default: []].append(command)
        }
        return order.map { Group(name: $0, commands: members[$0] ?? []) }
    }

    var ungrouped: [ProjectCommand] { commands.filter { $0.group == nil } }

    func members(of group: String) -> [ProjectCommand] { commands.filter { $0.group == group } }

    func setExpanded(_ group: String, _ isExpanded: Bool) {
        if isExpanded { expandedGroups.insert(group) } else { expandedGroups.remove(group) }
        UserDefaults.standard.set(expandedGroups.sorted(), forKey: Self.expandedGroupsKey(for: root))
    }

    func load() async {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let storage = storage
            commands = try await Task.detached { try storage.load() }.value
            guard !Task.isCancelled else { return }
            isLoaded = true
            for command in commands where command.autoStart { _ = run(command) }
        } catch { self.error = "Could not load saved commands: \(error.localizedDescription)" }
        await discover()
    }

    func discover() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        defer { isDiscovering = false }
        let root = root
        sources = await Task.detached { ProjectCommandSource.discover(in: root) }.value
    }

    func resetUnreadableStorage() async {
        guard !isLoaded, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let storage = storage
            try await Task.detached { try storage.resetKeepingBackup() }.value
            commands = []
            isLoaded = true
            error = nil
        } catch { self.error = "Could not reset saved commands: \(error.localizedDescription)" }
    }

    func session(for command: ProjectCommand) -> TerminalSession? {
        sessions.supporting.first { $0.savedCommandID == command.id }
    }

    var allCommandsRunning: Bool {
        !commands.isEmpty && commands.allSatisfy { session(for: $0)?.isCommandRunning == true }
    }

    /// Replaces `replacing` with `processes` in place. Several processes save as a group named
    /// `name`; a single one saves as a plain command under that name.
    func save(name: String, processes: [ProjectCommand], replacing: Set<UUID>) async -> Bool {
        let previousGroup = commands.first { replacing.contains($0.id) }?.group
        let saved = processes.map { process in
            var process = process
            process.group = processes.count > 1 ? name : nil
            if processes.count == 1 { process.name = name }
            return process
        }
        var updated = commands
        let index = updated.firstIndex { replacing.contains($0.id) } ?? updated.endIndex
        updated.removeAll { replacing.contains($0.id) }
        updated.insert(contentsOf: saved, at: min(index, updated.endIndex))
        guard await persist(updated) else { return false }
        // Processes dropped from the group take their idle terminals with them.
        let kept = Set(saved.map(\.id))
        for id in replacing.subtracting(kept) {
            if let session = sessions.supporting.first(where: { $0.savedCommandID == id }) { sessions.remove(session) }
        }
        if let previousGroup, previousGroup != name, expandedGroups.contains(previousGroup) {
            setExpanded(previousGroup, false)
            if processes.count > 1 { setExpanded(name, true) }
        }
        return true
    }

    func deleteGroup(_ group: String) async {
        let members = members(of: group)
        guard members.allSatisfy({ session(for: $0)?.isCommandRunning != true && !busyIDs.contains($0.id) }) else { return }
        guard await persist(commands.filter { $0.group != group }) else { return }
        for member in members {
            if let session = session(for: member) { sessions.remove(session) }
        }
        setExpanded(group, false)
    }

    func importCommands(_ selected: [ProjectCommand]) async -> Bool {
        let existingNames = Set(commands.map(\.name))
        guard selected.allSatisfy({ !existingNames.contains($0.name) }) else {
            error = "A command with that name is already saved. Edit it or choose a different name before importing."
            return false
        }
        return await persist(commands + selected)
    }

    func delete(_ command: ProjectCommand) async {
        guard session(for: command)?.isCommandRunning != true, !busyIDs.contains(command.id) else { return }
        var remaining = commands.filter { $0.id != command.id }
        // A group of one is just a command; let the last member stand on its own.
        if let group = command.group, remaining.filter({ $0.group == group }).count == 1,
           let index = remaining.firstIndex(where: { $0.group == group }) {
            remaining[index].group = nil
        }
        if await persist(remaining), let session = session(for: command) {
            sessions.remove(session)
        }
    }

    private func persist(_ updated: [ProjectCommand]) async -> Bool {
        guard isLoaded, !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let storage = storage
            try await Task.detached { try storage.save(updated) }.value
            commands = updated
            return true
        } catch {
            self.error = "Could not save commands: \(error.localizedDescription)"
            return false
        }
    }

    func run(_ command: ProjectCommand) -> TerminalSession? {
        guard !busyIDs.contains(command.id), !isSaving else { return nil }
        guard let command = commands.first(where: { $0.id == command.id }) else { return nil }
        if let session = session(for: command), session.isCommandRunning { return session }
        let directory = command.directory(relativeTo: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = "Working directory does not exist: \(directory.path)"
            return nil
        }
        do {
            let execution = try CommandExecution(command: command.command)
            if let previous = session(for: command) { sessions.remove(previous) }
            return sessions.add(command: command, directory: directory, execution: execution)
        } catch {
            self.error = "Could not run \(command.name): \(error.localizedDescription)"
            return nil
        }
    }

    func stop(_ command: ProjectCommand) async -> Bool {
        guard !busyIDs.contains(command.id), let session = session(for: command) else { return false }
        busyIDs.insert(command.id)
        defer { busyIDs.remove(command.id) }
        let stopped = await session.stopCommand()
        if !stopped { error = "Could not stop \(command.name). Terminal cleanup could not be confirmed." }
        return stopped
    }

    func restart(_ command: ProjectCommand) async -> TerminalSession? {
        if session(for: command)?.isCommandRunning == true, !(await stop(command)) { return nil }
        return run(command)
    }

    func runAll(_ commands: [ProjectCommand]? = nil) -> TerminalSession? {
        var first: TerminalSession?
        for command in commands ?? self.commands {
            let session = run(command)
            if first == nil { first = session }
        }
        return first
    }

    func stopAll(_ commands: [ProjectCommand]? = nil) async {
        let running = (commands ?? self.commands).filter { session(for: $0)?.isCommandRunning == true }
        await withTaskGroup(of: Void.self) { group in
            for command in running {
                group.addTask { _ = await self.stop(command) }
            }
        }
    }
}
