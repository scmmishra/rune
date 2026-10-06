# AGENTS.md

- Keep Rune native, minimal, and easy to understand. Do not add features or dependencies without a clear need.
- Use SwiftUI for app structure. Keep terminal code isolated under `Rune/Terminal` when it is introduced.
- Document surgical fixes, platform quirks, and edge-case workarounds with a concise code comment explaining why they are necessary.
- Verify changes with `xcodebuild -project Rune.xcodeproj -scheme Rune -configuration Debug build CODE_SIGNING_ALLOWED=NO`.
- To try a change, run `mise run dev`. Debug builds are "Rune Dev" (`dev.rune.app.debug`), installed as `/Applications/Rune Dev.app` with an amber icon. It runs beside the installed Rune with its own settings, and `mise run dev` replaces only Rune Dev. Never quit or reinstall `/Applications/Rune.app`: it is the environment Rune is developed in. `bin/rune-dev <dir>` opens a folder in Rune Dev.
- Performance is a non-negotiable, opening and closing dialogs or panels should be quick and near instant. Transitions should be tasteful and crisp

## Vision

Rune is a native Mac workspace for people who work through agent TUIs such as Claude Code and Codex. It is a terminal plus a meta harness for agents. It sits between a plain terminal and the UI-heavy agent apps. Once a space is configured, the user never leaves Rune to do the work.

Out of scope: sessions that outlive the window, multi-device access, and remote servers. Worktrees are out for now.

## Layout model

This is the target model. The app does not implement all of it yet. Build this foundation before any card or extension system.

- **Space.** A repo plus its current branch. A repo is always required. Files and Git always show the space, never the focused terminal.
- **Canvas.** One row of columns: one hub and any number of card columns, in any order the user picks.
- **Hub.** The focus area. It holds tabs.
- **Tab.** Either a terminal workspace with split terminal panes, or a pinned view such as a PR review. A view tab can hold no terminal.
- **Side task.** A terminal in the same window, unrelated to the main task. It never changes what the space is about.
- **Cards.** Metadata about the space. A card is fixed height, or it fills with a minimum height. Resizing only adjusts. Columns have no gaps.
- **Drawers.** Quick looks at a file or diff. They leave the terminal partly visible.
- **Narrow screens.** The hub stays fully visible. Card columns that do not fit collapse.
- **Storage.** A space's configuration saves to the home folder by default. A palette command saves it to the repo. If a repo configuration exists, it wins.
- **Branch switch.** Terminals stay. Rune can offer to switch the agent thread, with a setting for ask, do nothing, or automatic.

Not designed yet: user-defined card types, finding agent threads per branch, a more reachable Change Brief, and PR review mode. PR review mode is a hub tab with a diff viewer in the Change Brief style. The user selects code and asks about it in one continuous thread, in a fresh session of the agent they chose.
