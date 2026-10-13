# Cards

A **card** is one unit in a column. Rune ships five built-in cards: Commands, Files, Changes, History, and Usage. A **custom card** is one the user defines with a file.

This document specifies custom cards. How cards are placed and sized is in [Layout](layout.md).

## The card file

A custom card is one TOML file: `~/.rune/cards/<name>.toml`.

```toml
title = "Conversations"
refresh = 60
sizing = "fill"
reads = ["inbox"]

source = '''
chatwoot convs -o json | jq '{items: [.data.payload[] | {
  id: (.id | tostring),
  title: .meta.sender.name,
  action: {set: {conversation: (.id | tostring)}}
}]}'
'''
```

The file's name, without `.toml`, is the card's ID. A layout refers to the card by that ID.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `title` | Text | The file name | The card's title. |
| `refresh` | Number | None | Seconds between runs. Values below 5 are raised to 5. Without it, the source runs only on the events listed under [When a source runs](#when-a-source-runs). |
| `sizing` | `"fixed"` or `"fill"` | `"fill"` | How the card takes height. See [Layout](layout.md#card-heights). |
| `reads` | List of names | Empty | The variables the source is bound to. See [Variables](#variables). |
| `source` | Text | Required | The script that produces the card's content. |

Rules:

- A file named after a built-in card, such as `files.toml`, is ignored.
- Cards live in the home folder only. Every card is one the user put there. A repo cannot add a card.
- A file Rune cannot read still makes a card. The card shows the reason, such as `Line 4: Expected = after title`.
- A layout that names a card with no file shows a placeholder card saying where the file should be.

### The TOML Rune reads

Rune reads a subset of TOML: tables, arrays of tables, dotted keys, basic and literal strings, multi-line strings, numbers, booleans, arrays, inline tables, and comments. It does not read dates or times.

Write the source between `'''`. Text there is taken literally, so quotes, backslashes, and `$` need no escaping.

## The source

`source` takes one of two forms.

**An inline script.** Rune runs it with `/bin/bash -c`. The whole script is one argument to bash.

**A path to an executable.** A value on one line, with no spaces, that starts with `./`, `../`, `/`, or `~/` names a file. Rune executes that file directly, so it can be in any language. A relative path is resolved against the card file's folder.

```toml
title = "Conversations"
source = "./conversations.py"
```

### What a source receives

- **Working directory.** The repo's root.
- **Standard input.** Empty.
- **Environment.** Rune's own environment, with these changes:

| Variable | Value |
|---|---|
| `PATH` | The search path of the user's login shell. |
| `RUNE_REPO` | The repo's root path. |
| `RUNE_BRANCH` | The current branch. |
| `RUNE_VAR_<NAME>` | One per variable in `reads`, with the name in capitals. Empty when the variable is not set. |

Rune asks the login shell for its `PATH` once per launch. An app started from the Dock otherwise sees only the system's directories, where tools such as `jq` and `gh` are not installed. If the shell does not answer in 5 seconds, Rune adds `/opt/homebrew/bin` and `/usr/local/bin` to its own path instead.

### When a source runs

- When the card appears.
- Every `refresh` seconds, if set.
- When a variable in `reads` changes.
- When the card's refresh button is clicked.
- When the card file changes and Rune has re-read it.

A source never runs twice at once. A run requested while one is going starts when that one ends.

Rune re-reads the card files when a window opens, when the command palette opens, on **Reload Files and Git**, and when any card's refresh button is clicked. There is no file watcher. An edit to a card file takes effect at the next of those moments.

### Limits and failures

- A run is stopped after 10 seconds. Rune stops the script. A process the script started in the background may keep running.
- Rune reads at most 2 MB of output.
- The run fails if the source exits with a non-zero status, prints nothing, or prints something other than one JSON object in the shape below.
- On failure the card keeps its last content and shows the reason above it. For a non-zero exit, the reason is the first line the source wrote to standard error.

## What a source prints

One JSON object on standard output. It holds one kind of content, plus optional fields that apply to any kind.

| Field | Meaning |
|---|---|
| `items` | A list of rows. See [Items](#items). |
| `messages` | A conversation. See [Messages](#messages). |
| `markdown` | A page of Markdown, as text. |
| `empty` | Text shown when there is nothing else to show. |
| `buttons` | Buttons for the card's header. See [Buttons](#buttons). |
| `anchor` | `"bottom"` opens messages or Markdown at their end. |

Exactly one of `items`, `messages`, and `markdown` is used. If more than one is present, `markdown` wins, then `messages`.

### Items

```json
{
  "items": [
    {
      "id": "4821",
      "title": "Priya Nair",
      "subtitle": "Refund not received",
      "badge": { "text": "open", "tint": "green" },
      "action": { "set": { "conversation": "4821" } }
    }
  ],
  "empty": "No open conversations"
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | Yes | Unique within the list. A number is accepted. |
| `title` | Yes | The row's main line. |
| `subtitle` | No | A second, quieter line. |
| `badge` | No | A short label at the row's end. Either text, or an object with `text` and an optional `tint`. |
| `action` | No | What a click does. See [Actions](#actions). |

`tint` is one of `green`, `orange`, `red`, `blue`, `yellow`, or `purple`. Any other value draws in grey.

An item without an action is plain information. It cannot be clicked.

An item shows as selected while the window holds every value its action sets. See [Variables](#variables).

### Messages

```json
{
  "anchor": "bottom",
  "messages": [
    { "id": "1", "author": "Priya Nair", "time": "Oct 10, 17:03", "text": "Hello", "kind": "message" },
    { "id": "2", "text": "Assigned to Sam", "time": "Oct 10, 17:04", "kind": "activity" }
  ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | Yes | Unique within the list. A number is accepted. |
| `text` | Yes | What was said. |
| `author` | No | Who said it. |
| `time` | No | When, as text already formatted for reading. |
| `kind` | No | `message`, `note`, or `activity`. The default is `message`. |

How each kind is drawn:

- **`message`.** The author and time on one muted line, then the text at full strength.
- **`note`.** As a message, set in from an orange rule and labelled "Private note". Use it for text written for the team and not sent to the other side.
- **`activity`.** One muted line holding the text and the time. Use it for events, such as an assignment.

The text keeps its own line breaks. Inline Markdown in it is rendered, such as bold and links.

### Buttons

```json
{
  "buttons": [
    { "title": "Open in browser", "action": { "open": "https://example.com/conversations/4821" } }
  ]
}
```

A button has a `title` and an `action`, both required. Titles must be unique. Buttons show in the card's header, before the refresh button.

## Actions

An action is an object. It can hold any of the four fields below, and it must hold at least one. One click performs all of them, in the order listed.

| Field | Effect |
|---|---|
| `set` | Sets variables on the window. An object of names and values. |
| `open` | Opens a web link in the browser. Only `http` and `https` are allowed. |
| `file` | Opens a file in Rune's drawer. A path relative to the repo, with an optional `:line`. |
| `thread` | Switches the hub to an agent thread, starting or resuming it. See [Threads](#threads). |

```json
{
  "action": {
    "set": { "conversation": "4821" },
    "thread": { "key": "chatwoot-4821", "name": "CW-4821" }
  }
}
```

## Variables

A **variable** is a named value held by one window. Variables are how one card drives another.

- An action's `set` writes variables. Every value is stored as text.
- A card whose `reads` lists a variable receives it as `RUNE_VAR_<NAME>`, and its source runs again when the value changes.
- A name uses ASCII letters, digits, and underscores only. It has to survive becoming an environment variable.
- Variables belong to the window. Two windows on the same repo, such as its default space and a setup, do not share them.
- Variables are not saved. A new window starts with none.

Example: a list card's items set `conversation`. A second card reads `conversation` and prints that conversation's messages. Clicking an item reloads the second card.

## Threads

A **thread** is one agent conversation that can be resumed. A **thread key** names the thing the thread belongs to, such as a conversation ID.

| Field | Required | Meaning |
|---|---|---|
| `key` | Yes | The thread key. One key always leads to the same thread. |
| `name` | No | The tab's name, and the thread's name in the agent's own session picker. |
| `prompt` | No | What a new thread starts with. A resumed thread is not given it again. |
| `model` | No | The model, passed each time the thread is opened. |
| `effort` | No | `low`, `medium`, `high`, `xhigh`, or `max`, passed each time the thread is opened. |

Without `model` or `effort`, the agent uses its own settings.

What happens on a click:

1. If the window already has a tab for the key, Rune switches to it.
2. Otherwise Rune opens a new tab in the hub and runs the agent in it.
3. If Rune has a session recorded for the key, and the agent still has that session, the agent resumes it.
4. Otherwise the agent starts a new session, and Rune records its ID for the key.

Details:

- **The agent is Claude Code.** It can start a session under an ID chosen in advance, which is what lets a key find its session again.
- **A new thread runs** `claude --session-id <id> [--model …] [--effort …] [--name …] [prompt]`.
- **A resumed thread runs** `claude --resume <id> [--model …] [--effort …]`.
- **Records** are kept per repo in `~/.rune/threads/<folder>-<hash>.json`, as an object of thread keys and session IDs. Every window on the repo uses the same file, so a thread started in one setup resumes in another.
- **The tab is a normal terminal.** The agent runs in the user's login shell. When the agent exits, the tab drops to a shell prompt.
- **Every value is passed as one quoted argument.** Text from a card is never run as code.

## Trust

- Card files are read from the home folder only.
- A source is the user's own script, and it runs with the user's permissions.
- What a source prints is treated as data. An item can open only web links, open only a file path, and set only text values. Thread fields reach the agent as single arguments.
