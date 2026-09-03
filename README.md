# Rune

Rune is a minimal native macOS workspace for terminal-first development, built with SwiftUI and libghostty.

This initial foundation contains an adaptive light and dark application shell, a Git-aware file tree, one embedded Ghostty terminal session, and a lightweight source editor drawer. Running `rune` from a directory opens that directory in Rune and starts the terminal there.

## Build and run

Requirements:

- macOS 26 or newer
- Xcode 26 or newer

Open `Rune.xcodeproj`, allow Swift Package Manager to resolve dependencies, then run the `Rune` scheme.

From the command line:

```sh
xcodebuild -project Rune.xcodeproj -scheme Rune -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Build and relaunch a single development instance:

```sh
mise run relaunch
```

For an incremental rebuild and relaunch loop while developing:

```sh
mise run dev
```

The task watches the app sources and Xcode project. A successful build replaces the
previous development process, while a failed build leaves the running app open.

Install `Rune.app` in `/Applications`, then add the CLI to your path:

```sh
ln -s "$(pwd)/bin/rune" ~/.local/bin/rune
```

Open the current directory:

```sh
rune
```

You can also open another directory with `rune path/to/project`. Rune keeps one window per canonical directory: invoking `rune` again for an open directory focuses its existing window, while a different directory opens in a new window.

When the CLI is symlinked from this checkout, it prefers the Debug app built by
`mise run relaunch`. Otherwise it opens the installed `Rune.app`. Set
`RUNE_APP_PATH` to explicitly select another app bundle.

## Architecture

```text
Rune/App          Application entry point
Rune/Files        Lazy native file tree
Rune/Editor       Native source editor and syntax highlighting
Rune/Workspace    Native three-pane workspace shell
Rune/Terminal     Single libghostty-backed terminal surface
bin/rune           CLI entry point
```

The CLI delegates directory opening to macOS Launch Services. Rune registers folders as a supported document type, then uses the canonical directory path as the identity of a data-driven SwiftUI window. In Git repositories, the tree uses `git ls-files` to include tracked and untracked files while respecting ignore rules. Other directories fall back to filesystem enumeration.

The app uses the `GhosttyTerminal` product from `libghostty-spm` 1.5.2. The package supplies a prebuilt libghostty XCFramework, its SwiftUI surface wrapper, and the runtime resources needed by the `.exec` backend. Rune remains unsandboxed so libghostty can launch the user’s shell.

Click a file in the tree, select it with the arrow keys and press Return, or press Command+P to fuzzy-find a workspace file. Files open in the editor drawer, which uses the native macOS text system for selection and navigation, supports Command+S, and applies lightweight syntax highlighting for common source formats.

There is no Git detail UI, tabs, or orchestration yet.
