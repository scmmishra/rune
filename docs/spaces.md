# Spaces and setups

A **space** is a repo and its branch, shown in one window. A **setup** is a space with a name.

## The default space

Every repo has a default space. It needs no configuration. Opening a folder opens its default space.

The default space starts with the standard layout: Commands and Files on the left of the hub, and Changes, History, and Usage on the right.

### Where it is stored

Rune looks in two places, in this order:

1. `.rune/space.json` in the repo.
2. `~/.rune/spaces/<folder>-<hash>.json` in the home folder.

`<folder>` is the repo folder's name. `<hash>` is the first 8 hex digits of the SHA-256 of the repo's full path. The hash keeps two checkouts with the same folder name apart.

If the repo file exists, Rune uses it and ignores the home file. If neither exists, Rune uses the standard layout.

Rune saves to whichever file it read. With no repo file, it saves to the home folder.

### File format

```json
{
  "version": 1,
  "layout": {
    "leading": [
      { "id": "6F1C…", "width": 240, "cards": ["commands", "files"] }
    ],
    "trailing": [
      { "id": "A9D2…", "width": 240, "cards": ["changes", "history", "usage"] }
    ]
  }
}
```

The `layout` object is specified in [Layout](layout.md).

### Sharing it with a team

The command palette has **Save Workspace Layout to Repository**. It writes `.rune/space.json` into the repo.

From then on, every layout change in that repo's default space edits that checked-in file. There is no personal override on top of it.

The command is available in the default space only.

## Setups

A setup is a named layout for one repo. A repo can have any number of setups.

A setup opens in a window of its own. The same repo can be open in its default space and in several setups at once. Each window has its own terminals, tabs, agents, and variables. All of them show the same files and the same Git state, because they are the same folder and branch.

### Where it is stored

Each setup is one file: `~/.rune/setups/<id>.json`.

```json
{
  "version": 1,
  "id": "EC233296-E3B8-4169-9363-340680541694",
  "name": "Customer Support",
  "repository": "/Users/me/code/chatwoot",
  "layout": { "leading": [], "trailing": [] }
}
```

- The file is named by the setup's ID, not its name. A rename does not move the file.
- The `id` inside the file must match the file name. A file that fails this check is ignored.
- Two setups may share a name, in the same repo or in different ones.
- Setups live in the home folder only. A repo cannot add one.

### Commands

All of these are in the command palette.

| Command | Where it shows | What it does |
|---|---|---|
| New Setup with *repo*… | Every window | Asks for a name, copies the window's current layout into a new setup, and opens it in a new window. The window you were in does not change. |
| Open Setup… | When at least one setup exists | Lists every setup, with its repo beside the name. |
| Rename Setup… | A setup's window | Changes the name. |
| Delete Setup… | A setup's window | Asks first, then deletes the file and closes the window. The repo and its default space are not affected. |

Setups also appear in the project picker, after the recent projects.

Opening a setup that is already open brings its window to the front.

### Telling windows apart

- The Files card's header shows the setup's name after the project name.
- The window's title is `<setup name> — <repo folder>`.
- Each setup remembers its own window size and position.

### Edge cases

- **The repo folder is gone.** The setup is left out of both lists. Its file stays on disk.
- **The setup was deleted while its window was closed.** A window restored for it shows the repo's default layout.

## What a window owns

These belong to one window and are never shared with another window on the same repo:

- The layout, which is the default space's or the setup's.
- The hub's tabs and panes, and every terminal in them.
- The variables set by cards. See [Cards](cards.md#variables).

Variables and terminals are not saved. They are gone when the window closes. Agent threads can be resumed, because Rune records which session belongs to which key. See [Cards](cards.md#threads).

## Out of scope

Rune does not keep sessions running after a window closes, and it does not connect to other machines.
