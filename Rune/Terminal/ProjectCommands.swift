import Foundation
import Combine

@MainActor
final class ProjectCommands: ObservableObject {
    @Published private(set) var commands: [ProjectCommand] = []
    @Published private(set) var procfiles: [Procfile] = []
    @Published private(set) var isLoaded = false
    @Published private(set) var isSaving = false
    @Published private(set) var busyIDs: Set<UUID> = []
    @Published var error: String?
    let root: URL
    let sessions: TerminalSessions
    private let storage: ProjectCommandStorage
    private var isLoading = false

    init(root: URL, sessions: TerminalSessions) {
        self.root = root
        self.sessions = sessions
        storage = ProjectCommandStorage(root: root)
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
        do {
            let root = root
            procfiles = try await Task.detached { try Procfile.discover(in: root) }.value
        } catch { self.error = "Could not locate Procfiles: \(error.localizedDescription)" }
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

    func save(_ command: ProjectCommand) async -> Bool {
        var updated = commands
        if let index = updated.firstIndex(where: { $0.id == command.id }) { updated[index] = command }
        else { updated.append(command) }
        return await persist(updated)
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
        if await persist(commands.filter { $0.id != command.id }), let session = session(for: command) {
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

    func runAll() -> TerminalSession? {
        var first: TerminalSession?
        for command in commands {
            let session = run(command)
            if first == nil { first = session }
        }
        return first
    }

    func stopAll() async {
        let running = commands.filter { session(for: $0)?.isCommandRunning == true }
        await withTaskGroup(of: Void.self) { group in
            for command in running {
                group.addTask { _ = await self.stop(command) }
            }
        }
    }
}
