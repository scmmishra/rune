import SwiftUI

struct FileIconView: View {
    let url: URL
    let isDirectory: Bool

    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }

    private var image: Image {
        switch FileIcon.source(for: url, isDirectory: isDirectory) {
        case let .asset(name):
            Image(name).renderingMode(.original)
        case let .system(name):
            Image(systemName: name)
        }
    }
}

private enum FileIcon {
    enum Source {
        case asset(String)
        case system(String)
    }

    private static let iconsByFilename = [
        ".env": "zed-settings",
        ".gitattributes": "zed-git",
        ".gitignore": "zed-git",
        ".gitmodules": "zed-git",
        ".prettierignore": "zed-prettier",
        ".prettierrc": "zed-prettier",
        "bun.lock": "zed-bun",
        "bun.lockb": "zed-bun",
        "cargo.lock": "zed-lock",
        "cargo.toml": "zed-package",
        "compose.yaml": "zed-docker",
        "compose.yml": "zed-docker",
        "composer.json": "zed-package",
        "composer.lock": "zed-lock",
        "copying": "zed-book",
        "docker-compose.yaml": "zed-docker",
        "docker-compose.yml": "zed-docker",
        "dockerfile": "zed-docker",
        "eslint.config.js": "zed-eslint",
        "eslint.config.mjs": "zed-eslint",
        "eslint.config.ts": "zed-eslint",
        "gemfile": "zed-package",
        "gemfile.lock": "zed-lock",
        "go.mod": "zed-package",
        "go.sum": "zed-lock",
        "license": "zed-book",
        "license.md": "zed-book",
        "package-lock.json": "zed-lock",
        "package.json": "zed-package",
        "package.swift": "zed-package",
        "pnpm-lock.yaml": "zed-lock",
        "podfile": "zed-package",
        "podfile.lock": "zed-lock",
        "procfile": "zed-heroku",
        "schema.prisma": "zed-prisma",
        "yarn.lock": "zed-lock",
    ]

    private static let iconsByExtension = [
        "as": "zed-actionscript",
        "astro": "zed-astro",
        "bash": "zed-terminal",
        "c": "zed-c",
        "cc": "zed-cpp",
        "coffee": "zed-coffeescript",
        "cpp": "zed-cpp",
        "css": "zed-css",
        "cts": "zed-typescript",
        "cxx": "zed-cpp",
        "dart": "zed-dart",
        "diff": "zed-diff",
        "elm": "zed-elm",
        "erl": "zed-erlang",
        "ex": "zed-elixir",
        "exs": "zed-elixir",
        "fish": "zed-terminal",
        "fs": "zed-fsharp",
        "fsi": "zed-fsharp",
        "fsx": "zed-fsharp",
        "gleam": "zed-gleam",
        "go": "zed-go",
        "gql": "zed-graphql",
        "graphql": "zed-graphql",
        "h": "zed-c",
        "hcl": "zed-hcl",
        "heex": "zed-phoenix",
        "hpp": "zed-cpp",
        "hrl": "zed-erlang",
        "hs": "zed-haskell",
        "htm": "zed-html",
        "html": "zed-html",
        "java": "zed-java",
        "js": "zed-javascript",
        "json": "zed-code",
        "jsonc": "zed-code",
        "jsx": "zed-react",
        "jl": "zed-julia",
        "kt": "zed-kotlin",
        "kts": "zed-kotlin",
        "lock": "zed-lock",
        "lua": "zed-lua",
        "m": "zed-c",
        "markdown": "zed-book",
        "md": "zed-book",
        "metal": "zed-metal",
        "ml": "zed-ocaml",
        "mli": "zed-ocaml",
        "mm": "zed-cpp",
        "mts": "zed-typescript",
        "nim": "zed-nim",
        "nix": "zed-nix",
        "odin": "zed-odin",
        "patch": "zed-diff",
        "php": "zed-php",
        "prisma": "zed-prisma",
        "py": "zed-python",
        "r": "zed-r",
        "rb": "zed-ruby",
        "roc": "zed-roc",
        "rs": "zed-rust",
        "sass": "zed-sass",
        "scala": "zed-scala",
        "scss": "zed-sass",
        "sh": "zed-terminal",
        "sql": "zed-database",
        "svelte": "zed-svelte",
        "swift": "zed-swift",
        "tcl": "zed-tcl",
        "tf": "zed-terraform",
        "tfvars": "zed-terraform",
        "toml": "zed-toml",
        "ts": "zed-typescript",
        "tsx": "zed-react",
        "v": "zed-v",
        "vue": "zed-vue",
        "zig": "zed-zig",
        "zsh": "zed-terminal",
    ]

    static func source(for url: URL, isDirectory: Bool) -> Source {
        if isDirectory {
            return .system("folder.fill")
        }

        let filename = url.lastPathComponent.lowercased()
        if let icon = iconsByFilename[filename] {
            return .asset(icon)
        }
        if filename.hasPrefix(".env.") {
            return .asset("zed-settings")
        }
        if filename.hasPrefix(".eslintrc") {
            return .asset("zed-eslint")
        }
        if filename.hasPrefix(".prettierrc") {
            return .asset("zed-prettier")
        }
        if filename.hasPrefix("dockerfile.") {
            return .asset("zed-docker")
        }

        if let icon = iconsByExtension[url.pathExtension.lowercased()] {
            return .asset(icon)
        }

        switch url.pathExtension.lowercased() {
        case "7z", "bz2", "gz", "rar", "tar", "tgz", "xz", "zip":
            return .asset("zed-archive")
        case "bmp", "gif", "heic", "jpeg", "jpg", "png", "svg", "webp":
            return .system("photo")
        case "conf", "ini", "plist", "xml", "yaml", "yml":
            return .asset("zed-settings")
        case "db", "sqlite", "sqlite3":
            return .asset("zed-database")
        case "otf", "ttf", "woff", "woff2":
            return .asset("zed-font")
        case "pdf":
            return .system("doc.richtext")
        case "rtf", "txt":
            return .asset("zed-book")
        case "xcworkspace", "xcodeproj":
            return .asset("zed-swift")
        default:
            return .system("doc")
        }
    }
}
