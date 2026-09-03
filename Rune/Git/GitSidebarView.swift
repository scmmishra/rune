import SwiftUI

struct GitSidebarView: View {
    let rootURL: URL
    let onOpenDiff: (GitChange, GitChange.Area) -> Void

    @StateObject private var model: GitSidebarModel
    @StateObject private var watcher: WorkspaceWatcher
    @State private var commitMessage = ""

    init(
        rootURL: URL,
        onOpenDiff: @escaping (GitChange, GitChange.Area) -> Void
    ) {
        self.rootURL = rootURL
        self.onOpenDiff = onOpenDiff
        _model = StateObject(wrappedValue: GitSidebarModel(rootURL: rootURL))
        _watcher = StateObject(
            wrappedValue: WorkspaceWatcher(rootURL: rootURL, debounceDuration: .milliseconds(300))
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !model.snapshot.staged.isEmpty {
                        section(
                            "STAGED",
                            changes: model.snapshot.staged,
                            area: .staged,
                            bulkActionTitle: "Unstage All",
                            bulkAction: {
                                Task { await model.unstageAll() }
                            }
                        )
                    }

                    if !model.snapshot.unstaged.isEmpty {
                        section("CHANGES", changes: model.snapshot.unstaged, area: .unstaged)
                    }

                    if !model.snapshot.untracked.isEmpty {
                        section("UNTRACKED", changes: model.snapshot.untracked, area: .unstaged)
                    }

                    if model.snapshot.changes.isEmpty, model.errorMessage == nil {
                        Text("Working tree clean")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }

            commitArea
        }
        .onAppear {
            watcher.start()
            model.refresh()
        }
        .onDisappear {
            watcher.stop()
            model.cancelRefresh()
        }
        .onChange(of: watcher.revision) {
            model.refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))

                Text(model.snapshot.branch)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Text("\(model.snapshot.changes.count)")
                    .foregroundStyle(.secondary)
            }

            if model.snapshot.additions > 0 ||
                model.snapshot.deletions > 0 ||
                model.snapshot.hasUnstagedChanges {
                HStack(spacing: 7) {
                    if model.snapshot.additions > 0 {
                        Text("+\(model.snapshot.additions)")
                            .foregroundStyle(.green)
                    }
                    if model.snapshot.deletions > 0 {
                        Text("−\(model.snapshot.deletions)")
                            .foregroundStyle(.red)
                    }

                    Spacer(minLength: 4)

                    if model.snapshot.hasUnstagedChanges {
                        Button("Stage All") {
                            Task { await model.stageAll() }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(model.isBusy)
                    }
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
            }
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func section(
        _ title: String,
        changes: [GitChange],
        area: GitChange.Area,
        bulkActionTitle: String? = nil,
        bulkAction: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                if let bulkActionTitle, let bulkAction {
                    Button(bulkActionTitle, action: bulkAction)
                        .buttonStyle(.plain)
                        .disabled(model.isBusy)
                } else {
                    Text("\(changes.count)")
                }
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)

            ForEach(changes) { change in
                GitChangeRow(
                    change: change,
                    area: area,
                    isDisabled: model.isBusy,
                    onOpen: {
                        onOpenDiff(change, area)
                    },
                    onToggle: {
                        Task {
                            switch area {
                            case .staged:
                                await model.unstage(change)
                            case .unstaged:
                                await model.stage(change)
                            }
                        }
                    }
                )
            }
        }
    }

    private var commitArea: some View {
        VStack(spacing: 8) {
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ZStack(alignment: .topLeading) {
                if commitMessage.isEmpty {
                    Text("Commit message")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 7)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $commitMessage)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 2)
                    .frame(minHeight: 54, maxHeight: 72)
            }
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            }

            Button {
                Task {
                    if await model.commitAll(message: commitMessage) {
                        commitMessage = ""
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if model.isCommitting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(model.isCommitting ? "Committing…" : "Commit All")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    model.snapshot.changes.isEmpty ||
                    model.isBusy ||
                    !model.snapshot.isRepository
            )
        }
        .padding(10)
    }
}

private struct GitChangeRow: View {
    let change: GitChange
    let area: GitChange.Area
    let isDisabled: Bool
    let onOpen: () -> Void
    let onToggle: () -> Void

    private var state: GitFileState {
        switch area {
        case .staged:
            change.stagedState ?? .modified
        case .unstaged:
            change.unstagedState ?? .modified
        }
    }

    private var diff: GitDiffCount? {
        switch area {
        case .staged:
            change.stagedDiff
        case .unstaged:
            change.unstagedDiff
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Text(state.label)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(state.color)
                        .frame(width: 10)

                    Text(change.path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    if let diff {
                        HStack(spacing: 4) {
                            if let additions = diff.additions, additions > 0 {
                                Text("+\(additions)")
                                    .foregroundStyle(.green)
                            }
                            if let deletions = diff.deletions, deletions > 0 {
                                Text("−\(deletions)")
                                    .foregroundStyle(.red)
                            }
                        }
                        .font(.system(size: 9, design: .monospaced))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            Button(action: onToggle) {
                Image(systemName: area == .staged ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(area == .staged ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .help(area == .staged ? "Unstage \(change.path)" : "Stage \(change.path)")
        }
        .padding(.horizontal, 4)
        .frame(height: 20)
        .contentShape(Rectangle())
    }
}

private extension GitFileState {
    var color: Color {
        switch self {
        case .added, .untracked:
            .green
        case .deleted, .conflicted:
            .red
        case .modified, .renamed, .copied, .typeChanged:
            .yellow
        }
    }
}
