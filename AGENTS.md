# AGENTS.md

- Keep Rune native, minimal, and easy to understand. Do not add features or dependencies without a clear need.
- Use SwiftUI for app structure. Keep terminal code isolated under `Rune/Terminal` when it is introduced.
- Document surgical fixes, platform quirks, and edge-case workarounds with a concise code comment explaining why they are necessary.
- Verify changes with `xcodebuild -project Rune.xcodeproj -scheme Rune -configuration Debug build CODE_SIGNING_ALLOWED=NO`.
- To try a change, run `mise run dev`. Debug builds are "Rune Dev" (`dev.rune.app.debug`), installed as `/Applications/Rune Dev.app` with an amber icon. It runs beside the installed Rune with its own settings, and `mise run dev` replaces only Rune Dev. Never quit or reinstall `/Applications/Rune.app`: it is the environment Rune is developed in. `bin/rune-dev <dir>` opens a folder in Rune Dev.
- Performance is a non-negotiable, opening and closing dialogs or panels should be quick and near instant. Transitions should be tasteful and crisp