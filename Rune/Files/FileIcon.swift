import SwiftUI

struct FileIconView: View {
    let url: URL
    let isDirectory: Bool
    var isExpanded = false

    var body: some View {
        Image(FileIcon.assetName(for: url, isDirectory: isDirectory, isExpanded: isExpanded))
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

private enum FileIcon {
    private static let iconsByFilename = [
        ".gitattributes": "ph-git-branch",
        ".env": "ph-file-lock",
        ".gitignore": "ph-git-branch",
        ".gitmodules": "ph-git-branch",
        "cargo.lock": "ph-file-lock",
        "cargo.toml": "ph-package",
        "composer.json": "ph-package",
        "composer.lock": "ph-file-lock",
        "copying": "ph-seal-check",
        "dockerfile": "ph-hammer",
        "gemfile": "ph-package",
        "gemfile.lock": "ph-file-lock",
        "go.mod": "ph-package",
        "go.sum": "ph-file-lock",
        "justfile": "ph-hammer",
        "license": "ph-seal-check",
        "license.md": "ph-seal-check",
        "makefile": "ph-hammer",
        "package-lock.json": "ph-file-lock",
        "package.json": "ph-package",
        "package.swift": "ph-package",
        "pnpm-lock.yaml": "ph-file-lock",
        "podfile": "ph-package",
        "podfile.lock": "ph-file-lock",
        "yarn.lock": "ph-file-lock",
    ]

    private static let iconsByExtension = [
        "7z": "ph-file-archive",
        "bash": "ph-terminal",
        "bz2": "ph-file-archive",
        "c": "ph-file-c",
        "cc": "ph-file-cpp",
        "conf": "ph-brackets-curly",
        "cpp": "ph-file-cpp",
        "css": "ph-file-css",
        "cxx": "ph-file-cpp",
        "fish": "ph-terminal",
        "gif": "ph-file-image",
        "go": "ph-file-code",
        "gz": "ph-file-archive",
        "h": "ph-file-c",
        "heic": "ph-file-image",
        "hpp": "ph-file-cpp",
        "htm": "ph-file-html",
        "html": "ph-file-html",
        "ini": "ph-brackets-curly",
        "java": "ph-file-code",
        "jpeg": "ph-file-image",
        "jpg": "ph-file-image",
        "js": "ph-file-js",
        "json": "ph-brackets-curly",
        "jsonc": "ph-brackets-curly",
        "jsx": "ph-file-jsx",
        "kt": "ph-file-code",
        "lock": "ph-file-lock",
        "m": "ph-file-code",
        "markdown": "ph-file-md",
        "md": "ph-file-md",
        "mm": "ph-file-code",
        "pdf": "ph-file-pdf",
        "plist": "ph-brackets-curly",
        "png": "ph-file-image",
        "py": "ph-file-py",
        "rb": "ph-file-code",
        "rs": "ph-file-rs",
        "rtf": "ph-file-text",
        "scss": "ph-file-css",
        "sh": "ph-terminal",
        "sql": "ph-file-sql",
        "svg": "ph-file-svg",
        "swift": "ph-file-code",
        "tar": "ph-file-archive",
        "tgz": "ph-file-archive",
        "toml": "ph-brackets-curly",
        "ts": "ph-file-ts",
        "tsx": "ph-file-tsx",
        "txt": "ph-file-text",
        "vue": "ph-file-vue",
        "webp": "ph-file-image",
        "xcworkspace": "ph-hammer",
        "xcodeproj": "ph-hammer",
        "xml": "ph-brackets-curly",
        "xz": "ph-file-archive",
        "yaml": "ph-brackets-curly",
        "yml": "ph-brackets-curly",
        "zip": "ph-file-archive",
        "zsh": "ph-terminal",
    ]

    static func assetName(for url: URL, isDirectory: Bool, isExpanded: Bool) -> String {
        if isDirectory {
            return isExpanded ? "ph-folder-open" : "ph-folder"
        }

        let filename = url.lastPathComponent.lowercased()
        if let icon = iconsByFilename[filename] {
            return icon
        }
        if filename.hasPrefix(".env.") {
            return "ph-file-lock"
        }

        return iconsByExtension[url.pathExtension.lowercased()] ?? "ph-file"
    }
}
