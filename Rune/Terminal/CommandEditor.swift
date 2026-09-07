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
            Form {
                TextField("Name", text: $draft.name)
                TextField("Command", text: $draft.command, axis: .vertical)
                    .lineLimit(2...5)
                TextField("Working directory", text: $draft.workingDirectory)
                Toggle("Start automatically when this project opens", isOn: $draft.autoStart)
            }
            .textFieldStyle(.roundedBorder)
            Text("Use . for the project root, a relative path, or an absolute path. Changes apply on the next run.")
                .runeFont(size: 11)
                .foregroundStyle(.secondary)
            if let error = model.error {
                Text(error).foregroundStyle(.red).runeFont(size: 11)
            }
            HStack {
                if let validation { Text(validation).runeFont(size: 11).foregroundStyle(.secondary) }
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
        .padding(24)
        .frame(width: 480)
    }
}

struct ProcfileImporter: View {
    @ObservedObject var model: ProjectCommands
    @State private var selectedFile: URL?
    @State private var selectedIDs: Set<UUID> = []
    @Environment(\.dismiss) private var dismiss

    private var procfile: Procfile? { model.procfiles.first { $0.url == selectedFile } }
    private var existingNames: Set<String> { Set(model.commands.map(\.name)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Commands").runeFont(size: 16, weight: .semibold)
            Picker("Procfile", selection: $selectedFile) {
                ForEach(model.procfiles) { file in
                    Text(file.url.lastPathComponent).tag(Optional(file.url))
                }
            }
            if let procfile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(procfile.commands) { command in
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
                        ForEach(Array(procfile.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning).runeFont(size: 11).foregroundStyle(.orange)
                        }
                        if procfile.commands.isEmpty { Text("No commands found.").foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 240)
            } else {
                Text("No Procfiles found in the project root.").foregroundStyle(.secondary)
            }
            Text("Selected commands are saved locally. Importing does not start them or change the Procfile.")
                .runeFont(size: 11).foregroundStyle(.secondary)
            if let error = model.error { Text(error).runeFont(size: 11).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(selectedIDs.count) Commands") {
                    let selected = procfile?.commands.filter { selectedIDs.contains($0.id) } ?? []
                    Task { if await model.importCommands(selected) { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedIDs.isEmpty || model.isSaving)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { selectedFile = model.procfiles.first?.url }
        .onChange(of: selectedFile) {
            selectedIDs = Set(procfile?.commands.filter { !existingNames.contains($0.name) }.map(\.id) ?? [])
        }
    }
}
