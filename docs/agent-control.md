# Agent control

An agent that runs in a Rune terminal can act on the window around it. It does this through an MCP server that ships inside the Rune binary. Claude Code and Codex both start it over stdio.

## Setup

Rune does not register the server on its own. Run "Connect Agents to Rune" from the command palette, or use the "Let agents use Rune" step of the welcome window. Either one registers the running Rune's binary with each agent CLI found on the login shell's PATH, at user scope. It replaces any server named `rune` that is already there.

The welcome step reads each CLI's config file to show its state: not installed, not connected, connected, or connected to another copy of Rune, such as Rune Dev.

The server offers no tools when the agent runs outside Rune, so it can stay registered everywhere. Agent sessions that were already running load it only after a restart.

The same registration by hand:

```sh
claude mcp add -s user rune -- /Applications/Rune.app/Contents/MacOS/Rune --rune-mcp
codex mcp add rune -- /Applications/Rune.app/Contents/MacOS/Rune --rune-mcp
```

Any Rune binary can serve as the server for any running Rune, Rune Dev included.

## Which window it controls

Each running Rune listens on one Unix socket, `~/.rune/run/<pid>.sock`, readable only by the user. A crashed Rune leaves its socket behind. The next Rune to start removes sockets of processes that are gone.

The server looks for the socket of its nearest ancestor process. If it finds none, it is not running inside Rune. It then lists no tools and sends no instructions.

Rune reads the caller's process ID from the socket. It walks that process's parents and looks for the root process of one of its terminal sessions. That session is the caller's pane, and its window handles the call. A process that does not descend from a Rune terminal gets an error. So an agent controls only the window it runs in, and only the pane it runs in counts as "yours".

A card's source runs as a child of Rune, not of a terminal. It cannot use the socket.

## Tools

| Tool | What it does |
|---|---|
| `rune_space` | Returns the repository, branch, setup name, variables, the tabs with their panes, and the saved commands that are running. Each pane has an id, a name, its foreground process, and its directory. The caller's pane has `"yours": true`. |
| `rune_open_file` | Opens a file in the preview drawer, at an optional line. A relative path resolves against the repository root. |
| `rune_open_diff` | Opens the diff drawer for a file with an uncommitted change. It shows the unstaged diff unless `staged` is true or the file has only a staged change. |
| `rune_open_terminal` | Opens a shell in the repository root and runs an optional command in it. `placement` is `right` (default) or `down` to split the caller's pane, or `tab` for a new tab. The caller's pane keeps the focus. The shell stays after the command ends. |
| `rune_set_variable` | Sets a space variable. Cards bound to it reload. |
| `rune_read_terminal` | Returns the last lines of any terminal in the window, scrollback included. `pane` is an id or a name from `rune_space`. `lines` defaults to 200, at most 5,000. Soft-wrapped rows come back as one line. |
| `rune_notify` | Marks the caller's tab as waiting and tells the user. If the window is focused, a toast shows over the hub for four seconds. If not, Rune sends a macOS notification. If the caller's pane has the keyboard, nothing is shown. Clicking either one selects the caller's tab. |
| `rune_open_markdown` | Shows Markdown in the preview drawer under a title. Mermaid blocks render as diagrams. A link to a path, such as `src/app.ts:42`, opens that file at that line. A second call replaces the page. |
| `rune_list_commands` | Returns every saved command of the Commands card: its id, name, shell command, folder, group, auto-start, and status. A command that has run lists its pane. A running command lists the TCP ports its process tree listens on. |
| `rune_save_command` | Adds a saved command, or updates the one with the same name. Fields left out keep their value. `new_name` renames it. An empty `group` removes it from its group. An update does not restart a running command. |
| `rune_delete_command` | Deletes a saved command. A running command is stopped first. |
| `rune_run_command` | Runs a saved command and returns its pane id for `rune_read_terminal`. |
| `rune_stop_command` | Stops a running saved command and its processes. |
| `rune_restart_command` | Stops a saved command if it runs, then runs it again. |

There is no tool to edit files. An agent edits files with its own tools, so its permission prompts and its transcript cover every edit.

## Reading terminals

`rune_read_terminal` reads every terminal in the caller's window, not only the panes the agent opened. A terminal can show secrets, such as a token printed by a command. The agent's prompt before the tool call is the check.

libghostty-spm 1.5.2 has no public way to read a terminal's text. Rune reads the surface handle from the package's `TerminalSurface` by reflection. The package is pinned to that exact version, and an update has to check this still works.

## Saved commands

The command tools change the same store as the Commands card, so the card shows each change at once. They name a command by its id or its name, without regard to case. If two commands in different groups share a name, `group` picks one.

A saved command with `auto_start` runs each time the repository opens in Rune. An agent can set it. The port list comes from the same process tree scan as the terminal header. A process that detaches from the tree, such as a daemon, is not counted.

## Notifications

macOS asks for notification permission the first time `rune_notify` sends one. If the user declines, the tab still shows that it is waiting.

## Permissions

A command run by `rune_open_terminal` or `rune_run_command` runs outside the agent's sandbox. A command saved with `rune_save_command` can run later without any agent, when it has auto-start. The agent's own prompt before an MCP tool call is the only check. If the user allows these tools without asking, the agent can run any command.
