import SwiftUI

struct ProjectCommandsView: View {
    @ObservedObject var model: ProjectCommands
    @ObservedObject var sessions: TerminalSessions
    let onSelect: (TerminalSession) -> Void
    @State private var editing: ProjectCommand?
    @State private var isImporting = false
    @State private var isResetting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("COMMANDS").runeFont(size: 10, weight: .semibold).foregroundStyle(.secondary)
                Spacer()
                if !model.commands.isEmpty {
                    Button {
                        if model.allCommandsRunning {
                            Task { await model.stopAll() }
                        } else if let session = model.runAll() {
                            onSelect(session)
                        }
                    } label: { Image(systemName: model.allCommandsRunning ? "stop.fill" : "play.fill") }
                    .help(model.allCommandsRunning ? "Stop All Commands" : "Start All Commands")
                    .accessibilityLabel(model.allCommandsRunning ? "Stop all commands" : "Start all commands")
                    .disabled(!model.busyIDs.isEmpty)
                }
                Menu {
                    Button("Add Command…") {
                        model.error = nil
                        editing = ProjectCommand(name: "", command: "")
                    }
                    Button("Import from Procfile…") {
                        model.error = nil
                        Task { await model.discover(); isImporting = true }
                    }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add or import commands")
            }
            .buttonStyle(WorkspaceButtonStyle())
            .disabled(!model.isLoaded || model.isSaving)
            .padding(.horizontal, 8)

            if !model.commands.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.commands) { command in
                            commandRow(command)
                        }
                    }
                }
                .frame(height: min(CGFloat(model.commands.count) * 30, 180))
                .disabled(model.isSaving)
            }
            if model.commands.isEmpty && !model.procfiles.isEmpty {
                Button("Import from Procfile…") {
                    model.error = nil
                    Task { await model.discover(); isImporting = true }
                }
                .buttonStyle(.plain)
                .runeFont(size: 11)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .disabled(!model.isLoaded || model.isSaving)
            }
            if let error = model.error, editing == nil, !isImporting {
                Text(error).runeFont(size: 11).foregroundStyle(.red).padding(.horizontal, 8)
                if !model.isLoaded {
                    HStack {
                        Button("Retry") { Task { await model.load() } }
                        Button("Reset…") { isResetting = true }
                    }
                    .runeFont(size: 11)
                    .padding(.horizontal, 8)
                    .disabled(model.isSaving)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .sheet(item: $editing) { command in CommandEditor(model: model, draft: command) }
        .sheet(isPresented: $isImporting) { ProcfileImporter(model: model) }
        .alert("Reset saved commands?", isPresented: $isResetting) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { Task { await model.resetUnreadableStorage() } }
        } message: {
            Text("Rune will keep a backup of the unreadable file and start with an empty command list.")
        }
    }

    private func commandRow(_ command: ProjectCommand) -> some View {
        Group {
            if let session = model.session(for: command) {
                RunningCommandRow(
                    command: command, session: session,
                    isSelected: sessions.navigation.activeID == session.id,
                    onSelect: { onSelect(session) },
                    onRun: { if let session = model.run(command) { onSelect(session) } },
                    onStop: { Task { _ = await model.stop(command) } }
                )
            } else {
                Button {
                    if let session = model.run(command) { onSelect(session) }
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Color.secondary.opacity(0.45)).frame(width: 5, height: 5)
                        Text(command.name).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "play.fill").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .help("Run \(command.name)\n\(command.command)")
            }
        }
        .runeFont(size: 11)
        .buttonStyle(.plain)
        .disabled(model.busyIDs.contains(command.id))
        .contextMenu {
            Button("Run") { if let session = model.run(command) { onSelect(session) } }
            Button("Stop") { Task { _ = await model.stop(command) } }
                .disabled(model.session(for: command)?.isCommandRunning != true)
            Button("Restart") {
                Task { if let session = await model.restart(command) { onSelect(session) } }
            }
            Divider()
            Button("Edit…") { model.error = nil; editing = command }
            Button("Delete", role: .destructive) { Task { await model.delete(command) } }
                .disabled(model.session(for: command)?.isCommandRunning == true)
        }
    }
}

private struct RunningCommandRow: View {
    let command: ProjectCommand
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onRun: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    TerminalStatusDot(session: session)
                    Text(command.name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            Button(action: session.isCommandRunning ? onStop : onRun) {
                Image(systemName: session.isCommandRunning ? "stop.fill" : "play.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 22)
            }
            .help(session.isCommandRunning ? "Stop \(command.name)" : "Run \(command.name)")
            .accessibilityLabel(session.isCommandRunning ? "Stop \(command.name)" : "Run \(command.name)")
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.primary.opacity(isSelected ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 5))
        .help("\(session.commandStatus)\n\(command.command)")
    }
}
