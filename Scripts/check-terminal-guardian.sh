#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
checks_dir=$(mktemp -d /tmp/rune-guardian.XXXXXX)
trap 'rm -rf "$checks_dir"' EXIT
xcrun swiftc -D RUNE_GUARDIAN_TESTING -module-cache-path "$checks_dir/module-cache" \
    Rune/Terminal/TerminalProcessGuardian.swift Rune/Terminal/TerminalProcessMonitor.swift \
    Rune/Terminal/TerminalAgent.swift Scripts/check-terminal-guardian.swift \
    -o "$checks_dir/check-terminal-guardian"
"$checks_dir/check-terminal-guardian"
