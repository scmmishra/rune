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
| `rune_space` | Returns the repository, branch, setup name, variables, and the tabs with their panes. The caller's pane has `"yours": true`. |
| `rune_open_file` | Opens a file in the preview drawer, at an optional line. A relative path resolves against the repository root. |
| `rune_open_diff` | Opens the diff drawer for a file with an uncommitted change. It shows the unstaged diff unless `staged` is true or the file has only a staged change. |
| `rune_open_terminal` | Opens a shell in the repository root and runs an optional command in it. `placement` is `right` (default) or `down` to split the caller's pane, or `tab` for a new tab. The caller's pane keeps the focus. The shell stays after the command ends. |
| `rune_set_variable` | Sets a space variable. Cards bound to it reload. |

There is no tool to edit files. An agent edits files with its own tools, so its permission prompts and its transcript cover every edit.

## Permissions

A command run by `rune_open_terminal` runs outside the agent's sandbox. The agent's own prompt before an MCP tool call is the only check. If the user allows the tool without asking, the agent can run any command in a new pane.
