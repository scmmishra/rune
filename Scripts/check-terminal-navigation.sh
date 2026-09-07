#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
checks_dir=$(mktemp -d /tmp/rune-terminal-navigation.XXXXXX)
trap 'rm -rf "$checks_dir"' EXIT
xcrun swiftc -module-cache-path "$checks_dir/module-cache" \
    Rune/Terminal/TerminalNavigation.swift Rune/Terminal/TerminalShortcut.swift \
    Scripts/check-terminal-navigation.swift -o "$checks_dir/check-terminal-navigation"
"$checks_dir/check-terminal-navigation"
