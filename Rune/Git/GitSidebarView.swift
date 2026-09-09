import AppKit
import SwiftUI

struct GitSidebarView: View {
    let rootURL: URL
    let topInset: CGFloat
    let selectedDiff: GitDiffSelection?
    let onSelectionsChange: ([GitDiffSelection]) -> Void
    let onOpenFile: (URL) -> Void
    let onOpenDiff: (GitDiffSelection, [GitDiffSelection]) -> Void
    let onOpenCommit: (GitCommit) -> Void
    let onOpenGuide: () -> Void

    @EnvironmentObject private var model: GitSidebarModel
    @State private var commitMessage = ""
    @State private var isComposingCommit = false
    @FocusState private var isCommitFocused: Bool
    @State private var pendingDiscard: GitChange?
    let onOpenBranches: () -> Void

    init(
        rootURL: URL,
        topInset: CGFloat,
        onOpenBranches: @escaping () -> Void,
        selectedDiff: GitDiffSelection?,
        onSelectionsChange: @escaping ([GitDiffSelection]) -> Void,
        onOpenFile: @escaping (URL) -> Void,
        onOpenDiff: @escaping (GitDiffSelection, [GitDiffSelection]) -> Void,
        onOpenCommit: @escaping (GitCommit) -> Void,
        onOpenGuide: @escaping () -> Void
    ) {
        self.rootURL = rootURL
        self.topInset = topInset
        self.onOpenBranches = onOpenBranches
        self.selectedDiff = selectedDiff
        self.onSelectionsChange = onSelectionsChange
        self.onOpenFile = onOpenFile
        self.onOpenDiff = onOpenDiff
        self.onOpenCommit = onOpenCommit
        self.onOpenGuide = onOpenGuide
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: WorkspaceMetrics.groupGap) {
                VStack(spacing: 0) {
                    header
                    changesList
                    commitArea
                }
                .frame(height: geometry.size.height * 2 / 3)
                .workspaceGroup()

                historyArea
                    .frame(maxHeight: .infinity, alignment: .top)
                    .workspaceGroup()
            }
            .padding(.horizontal, WorkspaceMetrics.panelGap)
        }
        .onChange(of: diffSelections, initial: true) { onSelectionsChange(diffSelections) }
        .animation(.easeOut(duration: 0.16), value: isComposingCommit)
        .onChange(of: isCommitFocused) {
            // Leave an in-progress draft expanded; only an empty field folds away.
            if !isCommitFocused && !hasCommitMessage { isComposingCommit = false }
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
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if !model.snapshot.staged.isEmpty {
                    section(
                        "STAGED",
                        changes: model.snapshot.staged,
                        area: .staged,
                        showsBrief: leadingSection == "STAGED",
                        bulkActionTitle: "Unstage All",
                        bulkAction: {
                            Task { await model.unstageAll() }
                        }
                    )
                }

                if !model.snapshot.unstaged.isEmpty {
                    section("CHANGES", changes: model.snapshot.unstaged, area: .unstaged,
                            showsBrief: leadingSection == "CHANGES")
                }

                if !model.snapshot.untracked.isEmpty {
                    section("UNTRACKED", changes: model.snapshot.untracked, area: .unstaged,
                            showsBrief: leadingSection == "UNTRACKED")
                }

                if model.hasLoaded, model.snapshot.changes.isEmpty, model.errorMessage == nil {
                    Text("Working tree clean")
                        .runeFont(size: 11)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, WorkspaceMetrics.columnInset - 4)
            .padding(.vertical, 8)
        }
        .overlay { QuietProgressView(isActive: !model.hasLoaded) }
        .onChange(of: selectedDiffID) { _, selected in
            if let selected { proxy.scrollTo(selected) }
        }
        }
    }

    private var selectedDiffID: String? {
        selectedDiff.map { rowID(path: $0.change.path, area: $0.area) }
    }

    private func rowID(path: String, area: GitChange.Area) -> String {
        (area == .staged ? "staged:" : "unstaged:") + path
    }

    private var diffSelections: [GitDiffSelection] {
        model.snapshot.staged.map { GitDiffSelection(change: $0, area: .staged) }
            + model.snapshot.unstaged.map { GitDiffSelection(change: $0, area: .unstaged) }
            + model.snapshot.untracked.map { GitDiffSelection(change: $0, area: .unstaged) }
    }

    private var header: some View {
        GitSidebarHeader(
            topInset: topInset,
            branch: model.snapshot.branch,
            changeCount: model.snapshot.changes.count,
            additions: model.snapshot.additions,
            deletions: model.snapshot.deletions,
            hasUnstagedChanges: model.snapshot.hasUnstagedChanges,
            isDisabled: model.isBusy,
            canSwitchBranch: model.snapshot.isRepository && !model.isBusy,
            onOpenBranches: onOpenBranches,
            onStageAll: {
                Task { await model.stageAll() }
            }
        )
        .equatable()
    }

    /// The topmost section carries the brief action, so it never claims a row of its own.
    private var leadingSection: String {
        if !model.snapshot.staged.isEmpty { return "STAGED" }
        if !model.snapshot.unstaged.isEmpty { return "CHANGES" }
        return "UNTRACKED"
    }

    private func section(
        _ title: String,
        changes: [GitChange],
        area: GitChange.Area,
        showsBrief: Bool = false,
        bulkActionTitle: String? = nil,
        bulkAction: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .tracking(0.7)
                Text("\(changes.count)")
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                if showsBrief {
                    Button(action: onOpenGuide) {
                        HStack(spacing: 3) {
                            Text("Brief")
                            Image(systemName: "sparkles")
                        }
                    }
                    .buttonStyle(GitSectionActionStyle())
                    .disabled(!model.snapshot.isRepository)
                    .help("Open the change brief")
                }
                if let bulkActionTitle, let bulkAction {
                    Button(bulkActionTitle, action: bulkAction)
                        .buttonStyle(GitSectionActionStyle())
                        .disabled(model.isBusy)
                }
            }
            .runeFont(size: 10, weight: .semibold)
            .foregroundStyle(.secondary)
            .padding(.trailing, 1)
            .frame(height: 18)

            ForEach(changes) { change in
                GitChangeRow(
                    change: change,
                    area: area,
                    isDisabled: model.isBusy,
                    onOpen: {
                        openDiff(change, area: area)
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
                .background {
                    if selectedDiff?.change.path == change.path && selectedDiff?.area == area {
                        RoundedRectangle(cornerRadius: WorkspaceMetrics.rowRadius).fill(Color.accentColor.opacity(0.16))
                    }
                }
                .contextMenu {
                    changeContextMenu(for: change, area: area)
                }
                .id(rowID(path: change.path, area: area))
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
            openDiff(change, area: area)
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

    private func openDiff(_ change: GitChange, area: GitChange.Area) {
        onOpenDiff(
            GitDiffSelection(change: change, area: area),
            diffSelections
        )
    }

    private var hasCommitMessage: Bool {
        !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var commitArea: some View {
        VStack(spacing: 8) {
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .runeFont(size: 10)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isComposingCommit {
                commitEditor
                commitButton
            } else {
                collapsedCommitRow
            }
        }
        .padding(WorkspaceMetrics.columnInset)
    }

    // Rests as a single-line field that matches the editor's box, so clicking it reads
    // as the same input growing rather than a button swapping for a form.
    private var collapsedCommitRow: some View {
        Button {
            isComposingCommit = true
            isCommitFocused = true
        } label: {
            HStack(spacing: 0) {
                Text(hasCommitMessage ? commitMessage : "Commit message")
                    .runeFont(size: 11)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(hasCommitMessage ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy || !model.snapshot.isRepository)
        .help("Write a commit message for the staged changes")
    }

    private var commitEditor: some View {
        ZStack(alignment: .topLeading) {
            if commitMessage.isEmpty {
                Text("Commit message")
                    .runeFont(size: 11)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $commitMessage)
                .runeFont(size: 11)
                .scrollContentBackground(.hidden)
                .focused($isCommitFocused)
                .padding(.horizontal, 2)
                .padding(.top, 8)
                .frame(minHeight: 54, maxHeight: 72)
        }
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
    }

    private var commitButton: some View {
        // The accent treatment only appears once the commit would actually go through.
        let isCommitReady = hasCommitMessage && !model.snapshot.staged.isEmpty && !model.isBusy

        return Button(action: commit) {
            HStack(spacing: 6) {
                if model.isCommitting {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(model.isCommitting ? "Committing…" : "Commit Staged")
                    .frame(maxWidth: .infinity)
            }
            .runeFont(size: 11, weight: .medium)
            .foregroundStyle(isCommitReady ? Color.accentColor : Color.secondary)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isCommitReady ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.055))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.accentColor.opacity(isCommitReady ? 0.35 : 0), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!isCommitReady || !model.snapshot.isRepository)
        .help("Commit staged changes (⌘↩)")
    }

    private func commit() {
        Task {
            if await model.commitStaged(message: commitMessage) {
                commitMessage = ""
                isCommitFocused = false
                isComposingCommit = false
            }
        }
    }

    private var historyArea: some View {
        GitHistoryView(
            commits: model.snapshot.commits,
            isRepository: model.snapshot.isRepository,
            onOpenCommit: onOpenCommit,
            onOpenCommitInGitHub: openCommitInGitHub
        )
        .equatable()
    }

    private func openCommitInGitHub(_ commit: GitCommit) {
        Task {
            let rootURL = rootURL
            let commitURL = await Task.detached(priority: .userInitiated) {
                GitRepository.githubURL(for: commit.id, at: rootURL)
            }.value

            guard let commitURL else { return }
            NSWorkspace.shared.open(commitURL)
        }
    }
}

struct BranchPickerView: View {
    let rootURL: URL
    let onClose: () -> Void
    @EnvironmentObject private var model: GitSidebarModel
    @State private var query = ""
    @State private var branches: [String] = []
    @State private var selected: String?
    @State private var loadError: String?
    @State private var isLoading = true

    private struct Choice: Identifiable {
        let name: String
        var create = false
        var id: String { (create ? "create:" : "branch:") + name }
    }

    private var choices: [Choice] {
        let queryBytes = Array(query.lowercased().utf8)
        // Preserve Git's newest-first order when search relevance is equal.
        let matches = branches.enumerated().compactMap { index, name -> (name: String, score: Int, recency: Int)? in
            guard !query.isEmpty else { return (name, 0, index) }
            guard let score = FuzzyMatcher.pathScore(queryBytes, path: name.lowercased(), filename: name.lowercased()) else { return nil }
            return (name, score, index)
        }.sorted { $0.score == $1.score ? $0.recency < $1.recency : $0.score > $1.score }
        var result = matches.map { Choice(name: $0.name) }
        if !isLoading, loadError == nil, !query.isEmpty, !branches.contains(query) {
            result.append(Choice(name: query, create: true))
        }
        return result
    }

    var body: some View {
        SearchPalette(
            placeholder: "Switch branch or create a new one", query: $query,
            items: choices, selection: $selected, isLoading: isLoading,
            isBusy: model.isSwitchingBranch, error: loadError ?? model.errorMessage,
            onClose: onClose, onSelect: switchTo
        ) { choice in
            HStack(spacing: 8) {
                Image(systemName: choice.create ? "plus" : "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                Text(choice.create ? "Create branch ‘\(choice.name)’" : choice.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if !choice.create, choice.name == model.snapshot.branch {
                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: query) { selected = choices.first?.id }
        .task {
            let rootURL = rootURL
            let result = await Task.detached(priority: .userInitiated) { GitRepository.branches(at: rootURL) }.value
            guard !Task.isCancelled else { return }
            branches = result.names
            loadError = result.error
            isLoading = false
            selected = choices.first?.id
        }
    }

    private func switchTo(_ choice: Choice) {
        guard !model.isBusy else { return }
        Task {
            if await model.switchBranch(choice.name, create: choice.create) { onClose() }
        }
    }
}

private struct GitSidebarHeader: View, Equatable {
    let topInset: CGFloat
    let branch: String
    let changeCount: Int
    let additions: Int
    let deletions: Int
    let hasUnstagedChanges: Bool
    let isDisabled: Bool
    let canSwitchBranch: Bool
    let onOpenBranches: () -> Void
    let onStageAll: () -> Void

    static func == (lhs: GitSidebarHeader, rhs: GitSidebarHeader) -> Bool {
        lhs.topInset == rhs.topInset &&
            lhs.branch == rhs.branch &&
            lhs.changeCount == rhs.changeCount &&
            lhs.additions == rhs.additions &&
            lhs.deletions == rhs.deletions &&
            lhs.hasUnstagedChanges == rhs.hasUnstagedChanges &&
            lhs.isDisabled == rhs.isDisabled &&
            lhs.canSwitchBranch == rhs.canSwitchBranch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Button(action: onOpenBranches) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10, weight: .semibold))
                        Text(branch)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(height: WorkspaceMetrics.headerHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(WorkspaceButtonStyle())
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!canSwitchBranch)
                .help("Switch Branch (⇧⌘B)")

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
                            .buttonStyle(GitSectionActionStyle())
                            .disabled(isDisabled)
                    }
                }
                .runeFont(size: 10, weight: .medium)
            }
        }
        .runeFont(size: 12, weight: .medium)
        .padding(.horizontal, WorkspaceMetrics.columnInset)
        .padding(.top, topInset + 8)
        .padding(.bottom, 8)
    }
}

private struct GitHistoryView: View, Equatable {
    let commits: [GitCommit]
    let isRepository: Bool
    let onOpenCommit: (GitCommit) -> Void
    let onOpenCommitInGitHub: (GitCommit) -> Void

    static func == (lhs: GitHistoryView, rhs: GitHistoryView) -> Bool {
        lhs.commits == rhs.commits && lhs.isRepository == rhs.isRepository
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("HISTORY")
                    .tracking(0.7)
                Text("\(commits.count)")
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
            }
            .runeFont(size: 10, weight: .semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, WorkspaceMetrics.columnInset)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if commits.isEmpty {
                Text(isRepository ? "No commits yet" : "Not a Git repository")
                    .runeFont(size: 11)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(commits) { commit in
                            GitCommitRow(
                                commit: commit,
                                onOpen: { onOpenCommit(commit) },
                                onOpenInGitHub: { onOpenCommitInGitHub(commit) }
                            )
                        }
                    }
                    .padding(.horizontal, WorkspaceMetrics.columnInset - 4)
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

private struct GitCommitRow: View {
    let commit: GitCommit
    let onOpen: () -> Void
    let onOpenInGitHub: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: handleOpen) {
            VStack(alignment: .leading, spacing: 3) {
                commitSubject
                    .runeFont(size: 11)
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
                .runeFont(size: 9)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Color.primary.opacity(isHovered ? 0.055 : 0),
            in: RoundedRectangle(cornerRadius: WorkspaceMetrics.rowRadius, style: .continuous)
        )
        .onHover { isHovered = $0 }
        .help("Preview commit \(commit.shortHash). Command-click to open on GitHub.")
    }

    private func handleOpen() {
        if NSEvent.modifierFlags.contains(.command) {
            onOpenInGitHub()
        } else {
            onOpen()
        }
    }

    private var commitSubject: Text {
        guard let prefix = ConventionalCommitPrefix(subject: commit.subject) else {
            return Text(commit.subject)
        }

        return Text(prefix.type)
            .foregroundColor(prefix.color(for: colorScheme))
            .fontWeight(.semibold) + Text(prefix.remainder)
    }
}

private struct ConventionalCommitPrefix {
    let type: String
    let remainder: String

    private static let supportedTypes: Set<String> = [
        "build", "chore", "ci", "docs", "feat", "fix", "perf",
        "refactor", "revert", "style", "test"
    ]

    init?(subject: String) {
        guard let colon = subject.firstIndex(of: ":") else { return nil }
        let header = subject[..<colon]
        guard let typeEnd = header.firstIndex(where: { $0 == "(" || $0 == "!" }) else {
            let type = String(header)
            guard Self.supportedTypes.contains(type) else { return nil }
            self.type = type
            remainder = String(subject[header.endIndex...])
            return
        }

        let type = String(header[..<typeEnd])
        let suffix = header[typeEnd...]
        guard Self.supportedTypes.contains(type), Self.isValidSuffix(suffix) else { return nil }
        self.type = type
        remainder = String(subject[typeEnd...])
    }

    func color(for colorScheme: ColorScheme) -> Color {
        let isDark = colorScheme == .dark
        return switch type {
        case "feat":
            Color(red: isDark ? 0.48 : 0.20, green: isDark ? 0.72 : 0.48, blue: isDark ? 0.55 : 0.28)
        case "fix", "revert":
            Color(red: isDark ? 0.82 : 0.65, green: isDark ? 0.48 : 0.24, blue: isDark ? 0.44 : 0.20)
        case "perf":
            Color(red: isDark ? 0.65 : 0.43, green: isDark ? 0.54 : 0.30, blue: isDark ? 0.82 : 0.65)
        case "refactor":
            Color(red: isDark ? 0.47 : 0.20, green: isDark ? 0.64 : 0.40, blue: isDark ? 0.82 : 0.62)
        case "docs", "test":
            Color(red: isDark ? 0.42 : 0.12, green: isDark ? 0.70 : 0.48, blue: isDark ? 0.74 : 0.52)
        default:
            Color(white: isDark ? 0.62 : 0.38)
        }
    }

    private static func isValidSuffix(_ suffix: Substring) -> Bool {
        if suffix == "!" { return true }
        guard suffix.first == "(", let closingParenthesis = suffix.lastIndex(of: ")") else {
            return false
        }
        let scope = suffix[suffix.index(after: suffix.startIndex)..<closingParenthesis]
        let trailing = suffix[suffix.index(after: closingParenthesis)...]
        return !scope.isEmpty && (trailing.isEmpty || trailing == "!")
    }
}

private struct GitChangeRow: View {
    let change: GitChange
    let area: GitChange.Area
    let isDisabled: Bool
    let onOpen: () -> Void
    let onToggle: () -> Void
    @State private var isHovered = false
    @Environment(\.runeTypography) private var typography

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
                        .runeFont(size: 10, weight: .bold)
                        .foregroundStyle(state.color)
                        .frame(width: 10)

                    Text(change.path)
                        .runeFont(size: 11)
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
                        .runeFont(size: 9)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .help(change.path)

            Button(action: onToggle) {
                Image(systemName: area == .staged ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(area == .staged ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(WorkspaceButtonStyle())
            .disabled(isDisabled)
            .help(area == .staged ? "Unstage \(change.path)" : "Stage \(change.path)")
        }
        .padding(.horizontal, 4)
        .frame(minHeight: max(20, typography.size(relativeTo: 20)))
        .background(RoundedRectangle(cornerRadius: WorkspaceMetrics.rowRadius).fill(Color.primary.opacity(isHovered ? 0.04 : 0)))
        .onHover { isHovered = $0 }
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


/// Full-width sidebar rows that light up on hover, matching the change and commit lists.
private struct GitRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration) }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    Color.primary.opacity(isEnabled ? (configuration.isPressed ? 0.09 : isHovered ? 0.055 : 0.025) : 0.02),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovered = $0 }
        }
    }
}

/// Compact text actions inside section headers, which are too short for WorkspaceButtonStyle's 24pt box.
private struct GitSectionActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration) }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(
                    Color.primary.opacity(isEnabled ? (configuration.isPressed ? 0.12 : isHovered ? 0.07 : 0) : 0),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
                .foregroundStyle(isHovered && isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}
