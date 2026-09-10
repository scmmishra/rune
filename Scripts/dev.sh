#!/bin/bash
# Build Rune Dev, install it as /Applications/Rune Dev.app, and open it beside the
# installed Rune. Debug builds have their own bundle identifier and icon, so this never
# touches /Applications/Rune.app or its settings, and only Rune Dev is quit.
set -euo pipefail

cd "$(dirname "$0")/.."
repository_root="$PWD"
built_app="$repository_root/DerivedData/Build/Products/Debug/Rune.app"
app="/Applications/Rune Dev.app"
executable="$app/Contents/MacOS/Rune"

mise run build
[ -x "$built_app/Contents/MacOS/Rune" ]

# Match the app process by its exact command line. Guardian helpers run the same
# executable with arguments and must be left to clean up their sessions.
pids=$(pgrep -fx "$executable" || true)
if [ -n "$pids" ]; then
    kill -TERM $pids 2>/dev/null || true
    for ((attempt = 0; attempt < 100; attempt++)); do
        pgrep -fx "$executable" >/dev/null || break
        sleep 0.05
    done
    if pgrep -fx "$executable" >/dev/null; then
        echo "rune-dev: previous Rune Dev is still running after 5 seconds." >&2
        exit 1
    fi
fi

# Stage beside the destination so the swap is a rename, never a half-copied bundle.
staged="/Applications/.Rune Dev.app.staging"
rm -rf "$staged"
ditto "$built_app" "$staged"
rm -rf "$app"
mv "$staged" "$app"

# Keep automation's monochrome-output preference out of interactive shells.
env -u NO_COLOR open -a "$app" "${1:-$repository_root}"
