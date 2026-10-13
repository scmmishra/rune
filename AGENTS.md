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

## Glossary

Use one name for one thing, in the interface, the code, and when talking about Rune. Older code still uses some of the retired words. Use these names in new code, and rename old code only as a separate change.

- **Space.** A repo and its branch, shown in one window. Not "workspace".
- **Setup.** A named space. A repo's default space has no setup.
- **Layout.** Where the columns and cards sit in a space.
- **Hub.** The focus column. Not "terminal panel".
- **Tab.** One page of the hub.
- **Pane.** One region of a tab. A **terminal pane** runs a shell or agent. A **view pane** shows a view, such as an open chat.
- **Column.** A stack of cards beside the hub. Not "sidebar".
- **Card.** One unit in a column. A **built-in card** ships with Rune. A **custom card** is defined by the user. Not "panel", "group", or "section".
- **Drawer.** A quick look that slides over the hub.
- **Source.** The script that produces the content of a custom card or a view pane. "Command" is reserved for the Commands card's saved commands.
- **Item.** One row a source returns.
- **Action.** What happens when an item is clicked.
- **Variable.** A named value on the space, such as `conversation`. Not "context", which means an agent's context window.
- **Binding.** A source or pane that reads a variable and reloads when it changes.
- **Session.** One terminal process.
- **Thread.** One agent conversation, which can be resumed.
- **Thread key.** The variable value a thread belongs to, such as a conversation ID or a branch.
