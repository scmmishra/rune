/** The home page's content, shared by every variation of the page. */

export const traits = [
  { name: "Rooted", text: "Every window belongs to a repo. Files, Git changes, and history sit beside the terminals and always show that repo." },
  { name: "Watchful", text: "Rune spots Claude Code and Codex in a tab and names the tab after the agent. A dot appears when the agent finishes or waits for you." },
  { name: "Two-way", text: "Agents can act on Rune. They open files and diffs for you, show plans with diagrams, read the dev server's output, and tell you when they are done." },
  { name: "Glance", text: "Files, diffs, and commits open in a drawer over the terminals. The terminal stays in view, so you look without switching apps." },
  { name: "Composable", text: "Cards and setups shape a window around one job, such as a support queue where each conversation has its own agent thread." },
];

/** Real shortcuts. `key` is KeyboardEvent.key, lowercased. */
export const shortcuts = [
  { keys: ["⌘", "P"], key: "p", shift: false, label: "Find a file" },
  { keys: ["⇧", "⌘", "P"], key: "p", shift: true, label: "Command palette" },
  { keys: ["⌘", "D"], key: "d", shift: false, label: "Split right" },
  { keys: ["⇧", "⌘", "D"], key: "d", shift: true, label: "Split down" },
  { keys: ["⇧", "⌘", "↩"], key: "enter", shift: true, label: "Zoom a pane" },
  { keys: ["⇧", "⌘", "F"], key: "f", shift: true, label: "Search the project" },
  { keys: ["⇧", "⌘", "B"], key: "b", shift: true, label: "Switch branch" },
  { keys: ["⇧", "⌘", "O"], key: "o", shift: true, label: "Switch project" },
];

export const more = [
  { name: "Split panes", text: "Split a tab into panes, zoom one, resize them, and move between them from the keyboard. A tab shows the icon of each process in it." },
  { name: "Cards", text: "Files, Git changes, history, saved commands, and agent usage live in cards. Drag them between columns, or remove the ones you don't use.", href: "/docs/layout" },
  { name: "Custom cards", text: "A TOML file with a shell script makes a card. Its items can open links and files, set variables, and start agent sessions.", href: "/docs/cards" },
  { name: "Setups", text: "A setup is a named layout for a repo, opened in a window of its own. The same repo can be open in its default layout and a setup at once.", href: "/docs/spaces" },
  { name: "Agent threads", text: "A card item can open a Claude Code session tied to a key, such as a ticket ID. Clicking it again resumes the same session, even after a relaunch." },
  { name: "Agent tools", text: "An MCP server inside Rune gives Claude Code and Codex tools for the window they run in. Connect them from the command palette.", href: "/docs/agent-control" },
  { name: "Commands that stop", text: "Procfile entries and mise tasks run in terminals of their own. Rune stops them when it quits." },
  { name: "Themes", text: "Rune has 10 themes, such as Catppuccin, Gruvbox, and Tokyo Night. A theme colors the terminal and the whole window. In the command palette, the arrow keys preview each one." },
  { name: "The rune command", text: "Type rune in any shell to open the current folder in Rune." },
];

export const headline = "A terminal that knows your repo and your agents.";
export const lede =
  "Rune is a native Mac app for working with coding agents such as Claude Code and Codex. It keeps your terminals, your files, and your Git changes in one window.";
