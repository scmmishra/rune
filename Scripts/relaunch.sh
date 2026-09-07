#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
repository_root="$PWD"
built_app="$repository_root/DerivedData/Build/Products/Debug/Rune.app"
installed_app="/Applications/Rune.app"
staging_directory="/Applications/.Rune-relaunch"
staged_app="$staging_directory/Rune.app"
previous_app="$staging_directory/Previous.app"

# Serialize installs and keep staging on the destination filesystem so moves
# publish complete bundles. An interrupted install leaves its backup here.
if ! mkdir "$staging_directory"; then
    echo "rune: cannot acquire $staging_directory; check for another relaunch or an interrupted install." >&2
    exit 1
fi

cleanup() {
    local status=$?
    if [ -e "$previous_app" ] || [ -L "$previous_app" ]; then
        if [ ! -e "$installed_app" ] && [ ! -L "$installed_app" ]; then
            if ! mv "$previous_app" "$installed_app"; then
                echo "rune: restore failed; previous installation preserved at $previous_app" >&2
                exit 1
            fi
        fi
    fi
    rm -rf "$staging_directory"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

mise run build
[ -x "$built_app/Contents/MacOS/Rune" ]
ditto "$built_app" "$staged_app"
[ -x "$staged_app/Contents/MacOS/Rune" ]

# Discover common development copies and Spotlight-indexed installations.
# Only the canonical install is replaced; other copies may be intentional.
{
    for candidate in "/Applications/Rune.app" "$HOME/Applications/Rune.app" \
        "$repository_root"/DerivedData/Build/Products/*/Rune.app \
        "$HOME"/Library/Developer/Xcode/DerivedData/*/Build/Products/*/Rune.app; do
        [ ! -d "$candidate" ] || printf '%s\n' "$candidate"
    done
    mdfind 'kMDItemCFBundleIdentifier == "dev.rune.app"' 2>/dev/null || true
} | sort -u | while IFS= read -r candidate; do
    case "$candidate" in
        "$installed_app"|"$built_app"|"$staging_directory"/*) continue ;;
    esac
    [ ! -d "$candidate" ] || printf 'rune: other copy left unchanged: %s\n' "$candidate"
done

rune_pids() {
    local status=0
    pgrep -x Rune || status=$?
    # pgrep distinguishes no matches (1) from an inspection failure (>1).
    if [ "$status" -gt 1 ]; then
        echo "rune: unable to verify running instances; installation aborted." >&2
        exit "$status"
    fi
}

pids=$(rune_pids)
if [ -n "$pids" ]; then
    while IFS= read -r pid; do
        kill -TERM "$pid" 2>/dev/null || true
    done <<< "$pids"
fi

# Never replace a bundle still in use. Leave the existing app intact if a
# process refuses to exit, rather than silently continuing after a timeout.
for ((attempt = 0; attempt < 100; attempt++)); do
    pids=$(rune_pids)
    [ -n "$pids" ] || break
    sleep 0.05
done
pids=$(rune_pids)
if [ -n "$pids" ]; then
    echo "rune: still running after 5 seconds; existing installation left unchanged." >&2
    exit 1
fi

if [ -e "$installed_app" ] || [ -L "$installed_app" ]; then
    mv "$installed_app" "$previous_app"
fi
mv "$staged_app" "$installed_app"

# Keep automation's monochrome-output preference out of interactive shells.
env -u NO_COLOR open -a "$installed_app" "$repository_root"
