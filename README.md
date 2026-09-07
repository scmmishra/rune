# Rune

<img src="Artwork/AppIcon.svg" alt="Rune's green pixel CRT icon" width="128" height="128">

Your terminal, with the context you need.

Rune is a minimal native macOS workspace for terminal-first development. Keep
your shell at the center, with files, diffs, and Git history close at hand.

![Rune workspace showing the file tree, terminal, and Git sidebar](.github/screenshot.png)

- **Stay in your flow.** A Ghostty-powered terminal alongside your project files.
- **See what changed.** Browse diffs and Git history without leaving your workspace.
- **Understand the change.** Generate a Change Guide with your installed Codex or Claude Code, with explanations, native diagrams, and links to captured diffs.
- **Keep your hands on the keyboard.** Find files, run commands, and switch branches or projects through searchable palettes.
- **Pick up where you left off.** Rune remembers your last project, window layout, and expanded folders.

Built for macOS 26 and newer. Small, focused, and native.

## Change Guide

Open **Change Guide** above the Git sidebar’s changed files. Choose **Staged** or
**Working Tree** (unstaged and untracked files), select an installed agent, and
click **Generate Guide**. Sign in to that CLI from your terminal first. Generation
uses its existing account and usage limits in a separate read-only run. Keep the
CLI up to date: Rune uses Codex’s named permission profiles and Claude Code’s
restricted mode. User hooks and external integrations are not loaded for guides.

Guides and diagram images are cached for the current workspace session. You can
close the panel while generation runs. When files change, the guide keeps its
captured diffs and offers **Refresh**. Open a code reference to see the full
captured diff; **Back to Guide** or Escape returns to the same section.

Guides currently support up to 100 files and 250 KB of diff content. Flowcharts
and sequence diagrams render natively; unsupported diagrams fall back to the
section’s explanation. Guides describe the captured code, without access to the
conversation in your interactive terminal.

To run the focused Git and agent-output checks:

```sh
swiftc -parse-as-library Rune/Git/GitRepository.swift Rune/Guide/ChangeGuide.swift \
  Rune/Guide/GuideAgent.swift Scripts/check-change-guide.swift -o /tmp/rune-guide-checks
/tmp/rune-guide-checks
```

Pass `codex` or `claude` to the check executable to also test real generation
against a temporary fixture repository using that agent’s account.

## Credits

Powered by [Ghostty](https://ghostty.org/). File icons from the
[Colored Zed Icons Theme](https://github.com/TheRedXD/zed-icons-colored-theme),
vendored at [af356cf](https://github.com/TheRedXD/zed-icons-colored-theme/tree/af356cf3d9546928a272a05a08a9aa0dd4b6556e)
with their original license notice included in the app bundle.

Native diagrams use [BeautifulMermaid](https://github.com/lukilabs/beautiful-mermaid-swift)
under the MIT license and its [elk-swift](https://github.com/lukilabs/elk-swift)
layout dependency under the Eclipse Public License 2.0. The unmodified elk-swift
1.0.2 source is available at its [tagged source repository](https://github.com/lukilabs/elk-swift/tree/1.0.2).
License texts and source links are included in the app’s resources.
