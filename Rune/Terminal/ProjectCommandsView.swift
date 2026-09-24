import SwiftUI

struct ProjectCommandsView: View {
    @ObservedObject var model: ProjectCommands
    @ObservedObject var sessions: TerminalSessions
    let onSelect: (TerminalSession) -> Void
    @State private var editing: CommandDraft?
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
                        } else {
                            _ = model.runAll()
                        }
                    } label: { Image(systemName: model.allCommandsRunning ? "stop.fill" : "play.fill") }
                    .help(model.allCommandsRunning ? "Stop All Commands" : "Start All Commands")
                    .accessibilityLabel(model.allCommandsRunning ? "Stop all commands" : "Start all commands")
                    .disabled(!model.busyIDs.isEmpty)
                }
                Menu {
                    Button("Add Command…") {
                        model.error = nil
                        editing = .new
                    }
                    Button("Import Commands…") {
                        model.error = nil
                        isImporting = true
                    }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add or import commands")
            }
            .buttonStyle(WorkspaceButtonStyle())
            .disabled(!model.isLoaded || model.isSaving)
            .padding(.horizontal, 4)

            if !model.commands.isEmpty {
                let groups = model.groups
                let ungrouped = model.ungrouped
                let rowCount = groups.reduce(ungrouped.count) { count, group in
                    count + 1 + (model.expandedGroups.contains(group.name) ? group.commands.count : 0)
                }
                ScrollView {
                    VStack(spacing: 2) {
                        // Groups gather a project's long-running processes, so they lead.
                        ForEach(groups) { group in
                            groupRow(group)
                            if model.expandedGroups.contains(group.name) {
                                ForEach(group.commands) { command in
                                    commandRow(command)
                                        .padding(.leading, 12)
                                        .background {
                                            TreeConnector(isFirst: command.id == group.commands.first?.id,
                                                          isLast: command.id == group.commands.last?.id)
                                                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                                        }
                                }
                            }
                        }
                        ForEach(ungrouped) { command in
                            commandRow(command)
                        }
                    }
                }
                .frame(height: min(CGFloat(rowCount) * 30, 180))
                .disabled(model.isSaving)
            }
            if model.commands.isEmpty && !model.sources.isEmpty {
                Button("Import Commands…") {
                    model.error = nil
                    isImporting = true
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
        .padding(.horizontal, WorkspaceMetrics.columnInset - 4)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceGroup()
        .sheet(item: $editing) { draft in CommandEditor(model: model, draft: draft) }
        .sheet(isPresented: $isImporting) { ProjectCommandImporter(model: model) }
        .alert("Reset saved commands?", isPresented: $isResetting) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { Task { await model.resetUnreadableStorage() } }
        } message: {
            Text("Rune will keep a backup of the unreadable file and start with an empty command list.")
        }
    }

    private func isCommandSelected(_ command: ProjectCommand) -> Bool {
        guard let session = model.session(for: command) else { return false }
        return sessions.navigation.isPeeked(session.id)
    }

    private func groupRow(_ group: ProjectCommands.Group) -> some View {
        let isExpanded = model.expandedGroups.contains(group.name)
        let running = group.commands.filter { model.session(for: $0)?.isCommandRunning == true }
        let allRunning = running.count == group.commands.count
        return HStack(spacing: 6) {
            Button {
                model.setExpanded(group.name, !isExpanded)
            } label: {
                HStack(spacing: 8) {
                    GroupStatusDot(sessions: group.commands.map { model.session(for: $0) })
                    Text(group.name).lineLimit(1)
                    Spacer(minLength: 4)
                    // A faint count is what marks this row as a group that opens.
                    Text("\(group.commands.count)")
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("\(group.name), \(running.count) of \(group.commands.count) running")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .help("\(group.name): \(group.commands.map(\.name).joined(separator: ", "))")
            Button {
                if allRunning { Task { await model.stopAll(group.commands) } }
                else { _ = model.runAll(group.commands) }
            } label: {
                Image(systemName: allRunning ? "stop.fill" : "play.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 22)
            }
            .help(allRunning ? "Stop \(group.name)" : "Start \(group.name)")
            .accessibilityLabel(allRunning ? "Stop \(group.name)" : "Start \(group.name)")
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .runeFont(size: 11)
        .buttonStyle(.plain)
        .sidebarRowBackground()
        .disabled(group.commands.contains { model.busyIDs.contains($0.id) })
        .contextMenu {
            Button("Start All") { _ = model.runAll(group.commands) }
            Button("Stop All") { Task { await model.stopAll(group.commands) } }
                .disabled(running.isEmpty)
            Divider()
            Button("Edit Group…") {
                model.error = nil
                if let first = group.commands.first { editing = CommandDraft(editing: first, in: model) }
            }
            Button("Delete Group", role: .destructive) { Task { await model.deleteGroup(group.name) } }
                .disabled(!running.isEmpty)
        }
    }

    private func commandRow(_ command: ProjectCommand) -> some View {
        Group {
            if let session = model.session(for: command) {
                RunningCommandRow(
                    command: command, session: session,
                    isSelected: sessions.navigation.activeID == session.id,
                    onSelect: { onSelect(session) },
                    onRun: { _ = model.run(command) },
                    onStop: { Task { _ = await model.stop(command) } }
                )
            } else {
                Button {
                    _ = model.run(command)
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
        .sidebarRowBackground(isSelected: isCommandSelected(command))
        .disabled(model.busyIDs.contains(command.id))
        .contextMenu {
            Button("Run") { _ = model.run(command) }
            Button("Stop") { Task { _ = await model.stop(command) } }
                .disabled(model.session(for: command)?.isCommandRunning != true)
            Button("Restart") {
                Task { _ = await model.restart(command) }
            }
            Divider()
            Button(command.group == nil ? "Edit…" : "Edit Group…") {
                model.error = nil
                editing = CommandDraft(editing: command, in: model)
            }
            Button("Delete", role: .destructive) { Task { await model.delete(command) } }
                .disabled(model.session(for: command)?.isCommandRunning == true)
        }
    }
}

/// Joins a group's processes to the group's dot: a short branch into each row, and a
/// rounded corner on the last one where the trunk ends.
private struct TreeConnector: Shape {
    let isFirst: Bool
    let isLast: Bool
    /// Under the group dot: the row's 8pt inset plus half the 5pt dot.
    private let trunk: CGFloat = 10.5
    private let branchEnd: CGFloat = 14
    private let radius: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        let middle = rect.midY
        // Rows sit 2pt apart; reach up across the gap, or from just under the group's dot.
        let top: CGFloat = isFirst ? -11 : -2
        var path = Path()
        path.move(to: CGPoint(x: trunk, y: top))
        if isLast {
            path.addLine(to: CGPoint(x: trunk, y: middle - radius))
            path.addQuadCurve(to: CGPoint(x: trunk + radius, y: middle), control: CGPoint(x: trunk, y: middle))
        } else {
            path.addLine(to: CGPoint(x: trunk, y: rect.maxY))
            path.move(to: CGPoint(x: trunk, y: middle))
        }
        path.addLine(to: CGPoint(x: branchEnd, y: middle))
        return path
    }
}

/// The group's overall state, in the spot a single command shows its own dot. The most
/// urgent member wins; a ring means only some processes are running.
private struct GroupStatusDot: View {
    let sessions: [TerminalSession?]

    var body: some View {
        let live = sessions.compactMap { $0 }
        let running = live.filter(\.isCommandRunning).count
        if let waiting = live.first(where: \.needsAttention) {
            // Reuse the terminal's own dot so a waiting process breathes here too.
            TerminalStatusDot(session: waiting)
        } else if live.contains(where: { $0.cleanupFailed || (!$0.isCommandRunning && !$0.wasStopped && ($0.exitCode ?? 0) != 0) }) {
            dot(.red, status: "A process failed")
        } else if live.contains(where: \.isStopping) {
            dot(.orange, status: "Stopping")
        } else if running == sessions.count {
            dot(.green, status: "All running")
        } else if running > 0 {
            Circle()
                .strokeBorder(Color.green, lineWidth: 1.2)
                .frame(width: 6, height: 6)
                .help("\(running) of \(sessions.count) running")
                .accessibilityLabel("\(running) of \(sessions.count) running")
        } else {
            dot(.secondary.opacity(0.45), status: "Stopped")
        }
    }

    private func dot(_ color: Color, status: String) -> some View {
        Circle().fill(color).frame(width: 5, height: 5).help(status).accessibilityLabel(status)
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
        .help("\(session.commandStatus)\n\(command.command)")
    }
}
