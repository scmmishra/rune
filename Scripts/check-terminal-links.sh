#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
checks_dir=$(mktemp -d /tmp/rune-terminal-links.XXXXXX)
trap 'rm -rf "$checks_dir"' EXIT
mkdir -p "$checks_dir/project/pkg/sub"
printf 'one\ntwo\nthree\n' > "$checks_dir/project/pkg/sub/File.swift"
xcrun swiftc -module-cache-path "$checks_dir/module-cache" \
    Rune/Terminal/TerminalLink.swift Scripts/check-terminal-links.swift \
    -o "$checks_dir/check-terminal-links"
"$checks_dir/check-terminal-links" "$checks_dir/project"
