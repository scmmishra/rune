#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
checks_dir=$(mktemp -d)
trap 'rm -rf "$checks_dir"' EXIT
xcrun swiftc -module-cache-path "$checks_dir/module-cache" \
    Rune/Terminal/ProjectCommand.swift Rune/Terminal/CommandExecution.swift \
    Rune/Terminal/TerminalProcessMonitor.swift Rune/Terminal/TerminalAgent.swift Rune/Terminal/TerminalProcessGuardian.swift \
    Scripts/check-project-commands.swift -o "$checks_dir/check-project-commands"
"$checks_dir/check-project-commands"
