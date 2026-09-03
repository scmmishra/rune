# Rune

Rune is a minimal native macOS workspace for terminal-first development, built with SwiftUI and libghostty.

This initial foundation contains an adaptive light and dark application shell, a Git-aware file tree, and one embedded Ghostty terminal session. Running `rune` from a directory opens that directory in Rune and starts the terminal there.

## Build and run

Requirements:

- macOS 26 or newer
- Xcode 26 or newer

Open `Rune.xcodeproj`, allow Swift Package Manager to resolve dependencies, then run the `Rune` scheme.

From the command line:

```sh
xcodebuild -project Rune.xcodeproj -scheme Rune -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Install `Rune.app` in `/Applications`, then add the CLI to your path:

```sh
ln -s "$(pwd)/bin/rune" ~/.local/bin/rune
```

Open the current directory:

```sh
rune
```

You can also open another directory with `rune path/to/project`.

## Architecture

```text
Rune/App          Application entry point
Rune/Files        Lazy native file tree
Rune/Workspace    Native three-pane workspace shell
Rune/Terminal     Single libghostty-backed terminal surface
bin/rune           CLI entry point
```

The CLI delegates directory opening to macOS Launch Services. Rune registers folders as a supported document type, and SwiftUI routes incoming folder URLs into the active workspace. In Git repositories, the tree uses `git ls-files` to include tracked and untracked files while respecting ignore rules. Other directories fall back to filesystem enumeration.

The app uses the `GhosttyTerminal` product from `libghostty-spm` 1.5.2. The package supplies a prebuilt libghostty XCFramework, its SwiftUI surface wrapper, and the runtime resources needed by the `.exec` backend. Rune remains unsandboxed so libghostty can launch the user’s shell.

There is no file editing, Git status UI, persistence, tabs, or orchestration yet.
