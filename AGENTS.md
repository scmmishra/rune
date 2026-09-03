# AGENTS.md

- Keep Rune native, minimal, and easy to understand. Do not add features or dependencies without a clear need.
- Use SwiftUI for app structure. Keep terminal code isolated under `Rune/Terminal` when it is introduced.
- Document surgical fixes, platform quirks, and edge-case workarounds with a concise code comment explaining why they are necessary.
- Verify changes with `xcodebuild -project Rune.xcodeproj -scheme Rune -configuration Debug build CODE_SIGNING_ALLOWED=NO`.
- When rebuilding and reopening Rune during development, use `mise run relaunch` so the existing instance is replaced by the latest build.
