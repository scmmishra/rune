import SwiftUI

struct FileEditorDrawer: View {
    let fileURL: URL
    let onClose: () -> Void

    @State private var text = ""
    @State private var savedText = ""
    @State private var loadError: String?

    private var isDirty: Bool {
        text != savedText
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if let loadError {
                ContentUnavailableView(
                    "Unable to Open File",
                    systemImage: "doc.badge.ellipsis",
                    description: Text(loadError)
                )
            } else {
                CodeEditorView(
                    text: $text,
                    fileURL: fileURL
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
        .task(id: fileURL) {
            load()
        }
        .focusedSceneValue(\.saveCurrentFile, save)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)

            Text(fileURL.lastPathComponent)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)

            if isDirty {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Unsaved changes")
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close")
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private func load() {
        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            guard data.count <= 5_000_000 else {
                throw FileEditorError.tooLarge
            }
            guard let contents = String(data: data, encoding: .utf8) else {
                throw FileEditorError.notText
            }
            text = contents
            savedText = contents
            loadError = nil
        } catch {
            text = ""
            savedText = ""
            loadError = error.localizedDescription
        }
    }

    private func save() {
        guard loadError == nil else { return }

        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            savedText = text
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private enum FileEditorError: LocalizedError {
    case tooLarge
    case notText

    var errorDescription: String? {
        switch self {
        case .tooLarge:
            "Files larger than 5 MB are not shown."
        case .notText:
            "This file is not UTF-8 text."
        }
    }
}
