import SwiftUI

struct QuickOpenPanel: View {
    let rootURL: URL
    let onOpen: (URL) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var files: [WorkspaceFileIndex.Entry] = []
    @State private var matchingFiles: [WorkspaceFileIndex.Entry] = []
    @State private var isLoading = true
    @State private var selectedURL: URL?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    // Bound SwiftUI diffing while still keeping far more results than the panel can display.
    private let resultLimit = 200

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Open file", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($isSearchFocused)
                    .onSubmit(openSelection)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(matchingFiles, id: \.url) { file in
                            fileRow(file)
                                .id(file.url)
                        }
                    }
                    .padding(6)
                }
                .overlay {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .onChange(of: selectedURL) { _, selectedURL in
                    if let selectedURL {
                        proxy.scrollTo(selectedURL, anchor: .center)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 28, y: 10)
        .onAppear {
            isSearchFocused = true
        }
        .onChange(of: query) {
            refreshMatches()
        }
        .task(id: rootURL) {
            await loadFiles()
        }
        .onDisappear {
            searchTask?.cancel()
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .escape]) { keyPress in
            handleKeyPress(keyPress.key)
        }
    }

    private func fileRow(_ file: WorkspaceFileIndex.Entry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: FileTreeIcon.symbolName(for: file.url, isDirectory: false))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 12)

            Text(file.relativePath)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 25)
        .background {
            if selectedURL == file.url {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(0.20))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen(file.url)
        }
    }

    private func openSelection() {
        guard let fileURL = selectedURL ?? matchingFiles.first?.url else { return }
        onOpen(fileURL)
    }

    private func handleKeyPress(_ key: KeyEquivalent) -> KeyPress.Result {
        if key == .escape {
            onClose()
            return .handled
        }

        guard !matchingFiles.isEmpty else { return .ignored }
        let currentIndex = selectedURL.flatMap { selectedURL in
            matchingFiles.firstIndex { $0.url == selectedURL }
        }

        if key == .upArrow {
            selectedURL = matchingFiles[max(0, (currentIndex ?? 1) - 1)].url
            return .handled
        }

        if key == .downArrow {
            selectedURL = matchingFiles[min(matchingFiles.count - 1, (currentIndex ?? -1) + 1)].url
            return .handled
        }

        return .ignored
    }

    private func loadFiles() async {
        isLoading = true
        let rootURL = rootURL
        let indexedFiles = await Task.detached(priority: .userInitiated) {
            WorkspaceFileIndex.files(in: rootURL)
        }.value

        guard !Task.isCancelled else { return }
        files = indexedFiles
        isLoading = false
        refreshMatches()
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
