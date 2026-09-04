import AppKit
import SwiftUI

struct GitCommitDrawer: View {
    let rootURL: URL
    let commit: GitCommit
    let onClose: () -> Void

    @State private var contents = ""
    @State private var loadError: String?
    @State private var isLoading = true

    private var diffURL: URL {
        rootURL.appending(path: "\(commit.shortHash).diff")
    }

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
            } else {
                CodeEditorView(
                    text: $contents,
                    fileURL: diffURL,
                    isEditable: false,
                    presentation: .diff
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
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

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(commit.subject)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(commit.author)
                    Text("•")
                    Text(commit.relativeDate)
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(commit.shortHash)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
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
        contents = result.contents
        loadError = result.errorMessage
        isLoading = false
    }
}
