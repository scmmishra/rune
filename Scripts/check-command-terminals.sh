#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Build with mise run build first. These checks briefly mount native test windows.
products="$PWD/DerivedData/Build/Products/Debug"
checks_dir=$(mktemp -d /tmp/rune-command-terminals.XXXXXX)
trap 'rm -rf "$checks_dir"' EXIT
ln -s "$products/GhosttyKit_GhosttyTerminal.bundle" "$checks_dir/GhosttyKit_GhosttyTerminal.bundle"
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -target "$(uname -m)-apple-macos26.0" \
    -module-cache-path "$checks_dir/module-cache" \
    -I "$products" -I "$products/include" -L "$products" \
    -lghostty -lc++ -framework Carbon \
    "$products/GhosttyTerminal.o" "$products/GhosttyKit.o" "$products/MSDisplayLink.o" \
    Rune/Terminal/ProjectCommand.swift Rune/Terminal/CommandExecution.swift \
    Rune/Terminal/TerminalProcessMonitor.swift Rune/Terminal/TerminalAgent.swift Rune/Terminal/TerminalProcessGuardian.swift \
    Rune/Terminal/TerminalSession.swift Rune/Terminal/TerminalNavigation.swift \
    Rune/Terminal/TerminalPane.swift Rune/App/TypographyPreferences.swift \
    Scripts/check-command-terminals.swift -o "$checks_dir/check-command-terminals"
"$checks_dir/check-command-terminals"
