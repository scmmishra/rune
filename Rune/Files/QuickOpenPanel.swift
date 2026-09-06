import SwiftUI

enum WorkspaceCommand: String, CaseIterable, Identifiable {
    case reload, openProject, switchBranch

    var id: Self { self }
    var title: String {
        switch self {
        case .reload: "Reload Files and Git"
        case .openProject: "Open Project…"
        case .switchBranch: "Switch Branch…"
        }
    }
    var symbol: String {
        switch self {
        case .reload: "arrow.clockwise"
        case .openProject: "folder"
        case .switchBranch: "arrow.triangle.branch"
        }
    }
}

struct CommandPalette: View {
    let canSwitchBranch: Bool
    let onClose: () -> Void
    let onSelect: (WorkspaceCommand) -> Void
    @State private var query = ""
    @State private var selection: WorkspaceCommand? = .reload

    private var matches: [WorkspaceCommand] {
        let commands = WorkspaceCommand.allCases.filter { $0 != .switchBranch || canSwitchBranch }
        guard !query.isEmpty else { return commands }
        let bytes = Array(query.lowercased().utf8)
        return commands.compactMap { command -> (WorkspaceCommand, Int)? in
            let name = command.title.lowercased()
            guard let score = FuzzyMatcher.pathScore(bytes, path: name, filename: name) else { return nil }
            return (command, score)
        }
        .sorted { $0.1 == $1.1 ? $0.0.title < $1.0.title : $0.1 > $1.1 }
        .map(\.0)
    }

    var body: some View {
        SearchPalette(
            placeholder: "Run a command", query: $query, items: matches,
            selection: $selection, onClose: onClose, onSelect: onSelect
        ) { command in
            HStack(spacing: 8) {
                Image(systemName: command.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                Text(command.title)
                Spacer(minLength: 0)
            }
        }
        .onChange(of: query) { selection = matches.first }
        .onChange(of: canSwitchBranch) { selection = matches.first }
    }
}

struct QuickOpenPanel: View {
    let rootURL: URL
    let onOpen: (URL) -> Void
    let onClose: () -> Void
    @EnvironmentObject private var repository: GitSidebarModel

    @State private var query = ""
    @State private var files: [WorkspaceFileIndex.Entry] = []
    @State private var matchingFiles: [WorkspaceFileIndex.Entry] = []
    @State private var isLoading = true
    @State private var selectedURL: URL?
    @State private var searchTask: Task<Void, Never>?

    // Bound SwiftUI diffing while still keeping far more results than the panel can display.
    private let resultLimit = 200

    var body: some View {
        SearchPalette(
            placeholder: "Open file", query: $query, items: matchingFiles,
            selection: $selectedURL, isLoading: isLoading,
            onClose: onClose, onSelect: { onOpen($0.url) }
        ) { file in
            HStack(spacing: 8) {
                FileIconView(url: file.url, isDirectory: false)
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                Text(file.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        .onChange(of: query) {
            refreshMatches()
        }
        .onChange(of: repository.files, initial: true) {
            files = repository.files
            isLoading = !repository.hasLoaded
            refreshMatches()
        }
        .onChange(of: repository.hasLoaded) { isLoading = !repository.hasLoaded }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func refreshMatches() {
        searchTask?.cancel()

        let query = query
        let files = files
        guard !query.isEmpty else {
            matchingFiles = Array(files.prefix(resultLimit))
            selectedURL = matchingFiles.first?.url
            return
        }

        let worker = Task.detached(priority: .userInitiated) {
            QuickOpenSearch.matches(query: query, files: files, limit: resultLimit)
        }

        searchTask = Task {
            let matches = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard !Task.isCancelled, self.query == query else { return }
            matchingFiles = matches
            selectedURL = matches.first?.url
        }
    }
}

nonisolated private enum QuickOpenSearch {
    static func matches(
        query: String,
        files: [WorkspaceFileIndex.Entry],
        limit: Int
    ) -> [WorkspaceFileIndex.Entry] {
        let normalizedQuery = Array(query.lowercased().utf8)
        var matches: [(file: WorkspaceFileIndex.Entry, score: Int)] = []
        matches.reserveCapacity(files.count)

        for (index, file) in files.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled {
                return []
            }

            guard let score = FuzzyMatcher.pathScore(
                normalizedQuery,
                path: file.searchablePath,
                filename: file.searchableFilename
            ) else { continue }
            matches.append((file, score))
        }

        matches.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.file.relativePath < rhs.file.relativePath
        }

        return matches.prefix(limit).map(\.file)
    }
}

struct SearchPalette<Item: Identifiable, Row: View>: View {
    let placeholder: String
    @Binding var query: String
    let items: [Item]
    @Binding var selection: Item.ID?
    var isLoading = false
    var isBusy = false
    var error: String?
    let onClose: () -> Void
    let onSelect: (Item) -> Void
    @ViewBuilder let row: (Item) -> Row
    @FocusState private var isSearchFocused: Bool
    @Environment(\.runeTypography) private var typography

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .runeFont(size: 13)
                    .focused($isSearchFocused)
                    .disabled(isBusy)
                    .onSubmit {
                        guard !isBusy, let item = items.first(where: { $0.id == selection }) else { return }
                        onSelect(item)
                    }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            Button {
                                guard !isBusy else { return }
                                selection = item.id
                                onSelect(item)
                            } label: {
                                row(item)
                                    .runeFont(size: 12)
                                    .padding(.horizontal, 8)
                                    .frame(minHeight: max(25, typography.size(relativeTo: 25)))
                                    .background {
                                        if selection == item.id {
                                            RoundedRectangle(cornerRadius: 5)
                                                .fill(Color.accentColor.opacity(0.20))
                                        }
                                    }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isBusy)
                            .id(item.id)
                        }
                    }
                    .padding(6)
                }
                .overlay {
                    if isLoading || isBusy {
                        ProgressView().controlSize(.small)
                    }
                }
                .onChange(of: selection) { _, selected in
                    if let selected { proxy.scrollTo(selected, anchor: .center) }
                }
            }
            if let error {
                Divider()
                Text(error)
                    .runeFont(size: 11)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 28, y: 10)
        .onAppear { isSearchFocused = true }
        .onChange(of: isBusy) { if !isBusy { isSearchFocused = true } }
        .onKeyPress(keys: [.upArrow, .downArrow, .escape], phases: [.down, .repeat]) { event in
            guard !isBusy else { return .handled }
            if event.key == .escape { onClose(); return .handled }
            guard !items.isEmpty else { return .ignored }
            let index = selection.flatMap { selected in items.firstIndex { $0.id == selected } }
            let next = event.key == .upArrow ? max(0, (index ?? 1) - 1) : min(items.count - 1, (index ?? -1) + 1)
            selection = items[next].id
            return .handled
        }
    }
}
