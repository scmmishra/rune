import AppKit
import SwiftUI

struct GitCommitDrawer: View {
    let rootURL: URL
    let commit: GitCommit
    let onClose: () -> Void

    @State private var files: [GitCommitFileDiff] = []
    @State private var isTruncated = false
    @State private var loadError: String?
    @State private var isLoading = true
    @Environment(\.runeTypography) private var typography

    private static let minimumDiffHeight: CGFloat = 84
    private static let maximumDiffHeight: CGFloat = 320
    private static let approximateLineHeight: CGFloat = 15
    private static let editorVerticalPadding: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView(
                    "Unable to Load Commit",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else if files.isEmpty {
                ContentUnavailableView(
                    "No Changes",
                    systemImage: "doc",
                    description: Text("No changes in this commit.")
                )
            } else {
                commitFiles
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
        .background {
            GitPreviewEscapeMonitor(onEscape: onClose)
        }
        .task(id: commit.id) {
            await load()
        }
    }

    private var commitFiles: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(files) { file in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            FileIconView(
                                url: rootURL.appending(path: file.path),
                                isDirectory: false
                            )
                            .frame(width: 14, height: 14)

                            Text(file.path)
                                .runeFont(size: 11, weight: .medium)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 8)

                            HStack(spacing: 6) {
                                Text("+\(file.additions)")
                                    .foregroundStyle(.green)
                                Text("−\(file.deletions)")
                                    .foregroundStyle(.red)
                            }
                            .runeFont(size: 10, weight: .medium)
                        }

                        CodeEditorView(
                            text: .constant(file.patch),
                            fileURL: rootURL.appending(path: file.path),
                            isEditable: false,
                            presentation: .diff
                        )
                        .frame(height: diffHeight(for: file.patch))
                        .background(Color.primary.opacity(0.025))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.primary.opacity(0.11), lineWidth: 1)
                        }
                    }
                }

                if isTruncated {
                    Text("Commit diff truncated after 5 MB.")
                        .runeFont(size: 10)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(12)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(commit.subject)
                    .runeFont(size: 12, weight: .medium)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(commit.author)
                    Text("•")
                    Text(commit.relativeDate)
                }
                .runeFont(size: 9)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(commit.shortHash)
                .runeFont(size: 9, weight: .medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: Capsule())

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private func load() async {
        isLoading = true
        loadError = nil

        let rootURL = rootURL
        let commitID = commit.id
        let result = await Task.detached(priority: .userInitiated) {
            GitRepository.diff(for: commitID, at: rootURL)
        }.value

        guard !Task.isCancelled else { return }
        files = result.files
        isTruncated = result.isTruncated
        loadError = result.errorMessage
        isLoading = false
    }

    private func diffHeight(for patch: String) -> CGFloat {
        let lineCount = patch.reduce(1) { count, character in
            character == "\n" ? count + 1 : count
        }
        let scale = typography.size(relativeTo: 1)
        let naturalHeight = CGFloat(lineCount) * Self.approximateLineHeight * scale
            + Self.editorVerticalPadding
        return min(
            max(naturalHeight, Self.minimumDiffHeight * scale),
            Self.maximumDiffHeight * scale
        )
    }
}
