import SwiftUI

/// What the editor opens on: a plain command, a whole group, or a new blank command.
struct CommandDraft: Identifiable {
    let id = UUID()
    var name: String
    var processes: [ProjectCommand]
    /// Saved commands this draft replaces; empty when adding.
    let original: Set<UUID>

    static var new: CommandDraft { CommandDraft(name: "", processes: [ProjectCommand(name: "", command: "")], original: []) }

    init(name: String, processes: [ProjectCommand], original: Set<UUID>) {
        self.name = name
        self.processes = processes
        self.original = original
    }

    init(editing command: ProjectCommand, in model: ProjectCommands) {
        if let group = command.group {
            let members = model.members(of: group)
            self.init(name: group, processes: members, original: Set(members.map(\.id)))
        } else {
            self.init(name: command.name, processes: [command], original: [command.id])
        }
    }
}

struct CommandEditor: View {
    @ObservedObject var model: ProjectCommands
    @State var draft: CommandDraft
    @Environment(\.dismiss) private var dismiss

    private var isGroup: Bool { draft.processes.count > 1 }
    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var validation: String? {
        if trimmedName.isEmpty { return "Enter a name." }
        let others = model.commands.filter { !draft.original.contains($0.id) }
        let takenNames = Set(others.map(\.name))
        let takenGroups = Set(others.compactMap(\.group))
        if takenGroups.contains(trimmedName) || (isGroup ? takenNames.contains(trimmedName) : false) {
            return "A group or command with this name already exists."
        }
        var seen: Set<String> = []
        for process in draft.processes {
            let name = isGroup ? process.name.trimmingCharacters(in: .whitespacesAndNewlines) : trimmedName
            if isGroup && name.isEmpty { return "Name every process." }
            if process.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a command for every process." }
            if process.command.contains("\0") { return "A command contains an invalid character." }
            if takenNames.contains(name) || takenGroups.contains(name) || !seen.insert(name).inserted {
                return "A command named \(name) already exists."
            }
        }
        return nil
    }

    private func isRunning(_ process: ProjectCommand) -> Bool {
        model.session(for: process)?.isCommandRunning == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.original.isEmpty ? "Add Command" : isGroup ? "Edit Group" : "Edit Command")
                .runeFont(size: 16, weight: .semibold)
            // Stacked labels keep the form inside the sheet at larger font sizes.
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isGroup ? "Group name" : "Name")
                    TextField("Name", text: $draft.name).labelsHidden()
                }
                processList
                Button("Add Process", systemImage: "plus", action: addProcess)
                    .buttonStyle(.borderless)
                Toggle(isOn: autoStart) {
                    Text("Start automatically when this project opens")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
            }
            .textFieldStyle(.roundedBorder)
            Text("Use . for the project root, a relative path, or an absolute path. Changes apply on the next run.")
                .runeFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                Text(error).foregroundStyle(.red).runeFont(size: 11)
            }
            if let validation {
                Text(validation).runeFont(size: 11).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validation != nil || model.isSaving)
            }
        }
        .runeFont(size: 12)
        .padding(24)
        .frame(width: 560)
    }

    private var processList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Processes")
            ForEach($draft.processes) { $process in
                HStack(spacing: 6) {
                    // A lone process is the command itself and goes by the name above.
                    if isGroup {
                        TextField("Name", text: $process.name)
                            .frame(width: 110)
                    }
                    TextField("Command", text: $process.command)
                    TextField("Directory", text: $process.workingDirectory)
                        .frame(width: 90)
                    if isGroup {
                        removeButton(for: process)
                    }
                }
            }
        }
    }

    private func removeButton(for process: ProjectCommand) -> some View {
        Button {
            draft.processes.removeAll { $0.id == process.id }
        } label: { Image(systemName: "minus.circle") }
        .buttonStyle(.borderless)
        // A running process keeps its terminal until it is stopped.
        .disabled(isRunning(process))
        .help(isRunning(process) ? "Stop \(process.name) before removing it" : "Remove process")
        .accessibilityLabel("Remove \(process.name)")
    }

    /// One switch for the whole draft; a group starts together or not at all.
    private var autoStart: Binding<Bool> {
        Binding(
            get: { draft.processes.allSatisfy(\.autoStart) },
            set: { value in for index in draft.processes.indices { draft.processes[index].autoStart = value } }
        )
    }

    private func addProcess() {
        if draft.processes.count == 1, draft.processes[0].name.isEmpty {
            // The first process keeps the command's name until the user renames it.
            draft.processes[0].name = trimmedName
        }
        draft.processes.append(ProjectCommand(
            name: "", command: "",
            workingDirectory: draft.processes.last?.workingDirectory ?? ".",
            autoStart: draft.processes.allSatisfy(\.autoStart)
        ))
    }

    private func save() {
        let processes = draft.processes.map { process in
            var process = process
            process.name = process.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if process.workingDirectory.isEmpty { process.workingDirectory = "." }
            return process
        }
        Task {
            if await model.save(name: trimmedName, processes: processes, replacing: draft.original) { dismiss() }
        }
    }
}

struct ProjectCommandImporter: View {
    @ObservedObject var model: ProjectCommands
    @State private var selectedSource: String?
    @State private var selectedIDs: Set<UUID> = []
    @Environment(\.dismiss) private var dismiss

    private var source: ProjectCommandSource? { model.sources.first { $0.id == selectedSource } }
    private var existingNames: Set<String> { Set(model.commands.map(\.name)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Commands").runeFont(size: 16, weight: .semibold)
            Picker("Source", selection: $selectedSource) {
                ForEach(model.sources) { source in
                    Text(source.name).tag(Optional(source.id))
                }
            }
            if let source {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(source.commands) { command in
                            Toggle(isOn: Binding(
                                get: { selectedIDs.contains(command.id) },
                                set: { if $0 { selectedIDs.insert(command.id) } else { selectedIDs.remove(command.id) } }
                            )) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(command.name + (existingNames.contains(command.name) ? " · Already saved" : ""))
                                        .runeFont(size: 12, weight: .medium)
                                    Text(command.command).runeFont(size: 11).monospaced().foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(existingNames.contains(command.name))
                        }
                        ForEach(Array(source.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning).runeFont(size: 11).foregroundStyle(.orange)
                        }
                        if source.commands.isEmpty { Text("No commands found.").foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 240)
            } else {
                if model.isDiscovering {
                    ProgressView("Discovering commands…")
                } else {
                    Text("No Procfiles or mise tasks found.").foregroundStyle(.secondary)
                }
            }
            Text("Selected commands are saved locally. Importing does not start them or change project files.")
                .runeFont(size: 11).foregroundStyle(.secondary)
            if let error = model.error { Text(error).runeFont(size: 11).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(selectedIDs.count) Commands") {
                    let selected = source?.commands.filter { selectedIDs.contains($0.id) } ?? []
                    Task { if await model.importCommands(selected) { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedIDs.isEmpty || model.isSaving)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task {
            await model.discover()
            if !model.isDiscovering { selectedSource = model.sources.first?.id }
        }
        .onChange(of: model.isDiscovering) {
            if !model.isDiscovering && selectedSource == nil { selectedSource = model.sources.first?.id }
        }
        .onChange(of: selectedSource) {
            selectedIDs = Set(source?.commands.filter { !existingNames.contains($0.name) }.map(\.id) ?? [])
        }
    }
}
