# AGENTS.md

- Keep Rune native, minimal, and easy to understand. Do not add features or dependencies without a clear need.
- Use SwiftUI for app structure. Keep terminal code isolated under `Rune/Terminal` when it is introduced.
- Verify changes with `xcodebuild -project Rune.xcodeproj -scheme Rune -configuration Debug build CODE_SIGNING_ALLOWED=NO`.
