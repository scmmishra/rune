import SwiftUI

struct QuickOpenPanel: View {
    let rootURL: URL
    let files: [URL]
    let onOpen: (URL) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var selectedURL: URL?
    @FocusState private var isSearchFocused: Bool

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
                        ForEach(matchingFiles, id: \.self) { fileURL in
                            fileRow(fileURL)
                                .id(fileURL)
                        }
                    }
                    .padding(6)
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
            selectedURL = matchingFiles.first
            isSearchFocused = true
        }
        .onChange(of: query) {
            selectedURL = matchingFiles.first
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .escape]) { keyPress in
            handleKeyPress(keyPress.key)
        }
    }

    private var matchingFiles: [URL] {
        guard !query.isEmpty else { return files }
        return files.compactMap { fileURL -> (url: URL, path: String, score: Int)? in
            let path = relativePath(for: fileURL)
            guard let score = FuzzyMatcher.pathScore(query, path: path) else { return nil }
            return (fileURL, path, score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
        .map(\.url)
    }

    private func fileRow(_ fileURL: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: FileTreeIcon.symbolName(for: fileURL, isDirectory: false))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 12)

            Text(relativePath(for: fileURL))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 25)
        .background {
            if selectedURL == fileURL {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(0.20))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen(fileURL)
        }
    }

    private func relativePath(for fileURL: URL) -> String {
        WorkspaceFileIndex.relativePath(of: fileURL, in: rootURL)
    }

    private func openSelection() {
        guard let fileURL = selectedURL ?? matchingFiles.first else { return }
        onOpen(fileURL)
    }

    private func handleKeyPress(_ key: KeyEquivalent) -> KeyPress.Result {
        if key == .escape {
            onClose()
            return .handled
        }

        guard !matchingFiles.isEmpty else { return .ignored }
        let currentIndex = selectedURL.flatMap { matchingFiles.firstIndex(of: $0) }

        if key == .upArrow {
            selectedURL = matchingFiles[max(0, (currentIndex ?? 1) - 1)]
            return .handled
        }

        if key == .downArrow {
            selectedURL = matchingFiles[min(matchingFiles.count - 1, (currentIndex ?? -1) + 1)]
            return .handled
        }

        return .ignored
    }
}
