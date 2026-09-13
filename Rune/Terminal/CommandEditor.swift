import SwiftUI

struct CommandEditor: View {
    @ObservedObject var model: ProjectCommands
    @State var draft: ProjectCommand
    @Environment(\.dismiss) private var dismiss

    private var validation: String? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a name." }
        if draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a command." }
        if draft.command.contains("\0") { return "The command contains an invalid character." }
        if model.commands.contains(where: { $0.id != draft.id && $0.name == draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            return "A command with this name already exists."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.commands.contains(where: { $0.id == draft.id }) ? "Edit Command" : "Add Command")
                .runeFont(size: 16, weight: .semibold)
            // Stacked labels keep the form inside the sheet at larger font sizes.
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                    TextField("Name", text: $draft.name).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command")
                    TextField("Command", text: $draft.command, axis: .vertical)
                        .labelsHidden()
                        .lineLimit(2...5)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Working directory")
                    TextField("Working directory", text: $draft.workingDirectory).labelsHidden()
                }
                Toggle(isOn: $draft.autoStart) {
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
                Button("Save") {
                    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if draft.workingDirectory.isEmpty { draft.workingDirectory = "." }
                    Task { if await model.save(draft) { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validation != nil || model.isSaving)
            }
        }
        .runeFont(size: 12)
        .padding(24)
        .frame(width: 480)
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
