import AppKit
import SwiftUI

struct GitSidebarView: View {
    let rootURL: URL
    let onOpenFile: (URL) -> Void
    let onOpenDiff: (GitChange, GitChange.Area) -> Void

    @StateObject private var model: GitSidebarModel
    @StateObject private var watcher: WorkspaceWatcher
    @State private var commitMessage = ""
    @State private var pendingDiscard: GitChange?

    init(
        rootURL: URL,
        onOpenFile: @escaping (URL) -> Void,
        onOpenDiff: @escaping (GitChange, GitChange.Area) -> Void
    ) {
        self.rootURL = rootURL
        self.onOpenFile = onOpenFile
        self.onOpenDiff = onOpenDiff
        _model = StateObject(wrappedValue: GitSidebarModel(rootURL: rootURL))
        _watcher = StateObject(
            wrappedValue: WorkspaceWatcher(rootURL: rootURL, debounceDuration: .milliseconds(300))
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            GeometryReader { geometry in
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        changesList
                        commitArea
                    }
                    .frame(height: geometry.size.height * 2 / 3)

                    Divider()

                    historyArea
                }
            }
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
            model.refreshFromWatcher()
        }
        .confirmationDialog(
            "Discard changes to \(pendingDiscard?.path ?? "this file")?",
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            )
        ) {
            Button("Discard Changes", role: .destructive) {
                guard let change = pendingDiscard else { return }
                pendingDiscard = nil
                Task { await model.discard(change) }
            }
            Button("Cancel", role: .cancel) {
                pendingDiscard = nil
            }
        } message: {
            Text("Tracked edits cannot be recovered. Untracked files are moved to Trash.")
        }
    }

    private var changesList: some View {
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
    }

    private var header: some View {
        GitSidebarHeader(
            branch: model.snapshot.branch,
            changeCount: model.snapshot.changes.count,
            additions: model.snapshot.additions,
            deletions: model.snapshot.deletions,
            hasUnstagedChanges: model.snapshot.hasUnstagedChanges,
            isDisabled: model.isBusy,
            onStageAll: {
                Task { await model.stageAll() }
            }
        )
        .equatable()
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
                .contextMenu {
                    changeContextMenu(for: change, area: area)
                }
            }
        }
    }

    @ViewBuilder
    private func changeContextMenu(for change: GitChange, area: GitChange.Area) -> some View {
        let fileURL = rootURL.appending(path: change.path).standardizedFileURL
        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        let canDiscard = change.unstagedState != .untracked || fileExists

        Button {
            onOpenFile(fileURL)
        } label: {
            Label("Preview File", systemImage: "eye")
        }
        .disabled(!fileExists)

        Button {
            onOpenDiff(change, area)
        } label: {
            Label("Preview Diff", systemImage: "doc.text.magnifyingglass")
        }

        Divider()

        Button("Copy Path") {
            copyToPasteboard(fileURL.path)
        }

        Button("Copy Relative Path") {
            copyToPasteboard(change.path)
        }

        Divider()

        if area == .unstaged {
            Button(role: .destructive) {
                pendingDiscard = change
            } label: {
                Label("Discard Changes", systemImage: "arrow.uturn.backward")
            }
            .disabled(!canDiscard || model.isBusy)
        }

        Button(role: .destructive) {
            Task { await model.trash(change) }
        } label: {
            Label("Move to Trash", systemImage: "trash")
        }
        .disabled(!fileExists || model.isBusy)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private var commitArea: some View {
        let hasCommitMessage = !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(spacing: 8) {
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
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $commitMessage)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 2)
                    .padding(.top, 8)
                    .frame(minHeight: 54, maxHeight: 72)
            }
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            }

            Button {
                Task {
                    if await model.commitStaged(message: commitMessage) {
                        commitMessage = ""
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if model.isCommitting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(model.isCommitting ? "Committing…" : "Commit Staged")
                        .frame(maxWidth: .infinity)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(hasCommitMessage ? Color.primary : Color.secondary)
                .padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hasCommitMessage ? 0.12 : 0.055))
                }
            }
            .buttonStyle(.plain)
            .disabled(
                !hasCommitMessage ||
                    model.snapshot.staged.isEmpty ||
                    model.isBusy ||
                    !model.snapshot.isRepository
            )
        }
        .padding(10)
    }

    private var historyArea: some View {
        GitHistoryView(
            commits: model.snapshot.commits,
            isRepository: model.snapshot.isRepository
        )
        .equatable()
    }
}

private struct GitSidebarHeader: View, Equatable {
    let branch: String
    let changeCount: Int
    let additions: Int
    let deletions: Int
    let hasUnstagedChanges: Bool
    let isDisabled: Bool
    let onStageAll: () -> Void

    static func == (lhs: GitSidebarHeader, rhs: GitSidebarHeader) -> Bool {
        lhs.branch == rhs.branch &&
            lhs.changeCount == rhs.changeCount &&
            lhs.additions == rhs.additions &&
            lhs.deletions == rhs.deletions &&
            lhs.hasUnstagedChanges == rhs.hasUnstagedChanges &&
            lhs.isDisabled == rhs.isDisabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))

                Text(branch)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Text("\(changeCount)")
                    .foregroundStyle(.secondary)
            }

            if additions > 0 || deletions > 0 || hasUnstagedChanges {
                HStack(spacing: 7) {
                    if additions > 0 {
                        Text("+\(additions)")
                            .foregroundStyle(.green)
                    }
                    if deletions > 0 {
                        Text("−\(deletions)")
                            .foregroundStyle(.red)
                    }

                    Spacer(minLength: 4)

                    if hasUnstagedChanges {
                        Button("Stage All", action: onStageAll)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .disabled(isDisabled)
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
}

private struct GitHistoryView: View, Equatable {
    let commits: [GitCommit]
    let isRepository: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("HISTORY")
                Spacer()
                Text("\(commits.count)")
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if commits.isEmpty {
                Text(isRepository ? "No commits yet" : "Not a Git repository")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(commits) { commit in
                            GitCommitRow(commit: commit)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

private struct GitCommitRow: View {
    let commit: GitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(commit.subject)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)

            HStack(spacing: 6) {
                Text(commit.shortHash)
                    .foregroundStyle(.secondary)
                Text(commit.author)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(commit.relativeDate)
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 9, design: .monospaced))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
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
