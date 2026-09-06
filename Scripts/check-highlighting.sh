#!/bin/bash
set -euo pipefail

# Build first with mise run build so the pinned parser libraries and resources exist.
cd "$(dirname "$0")/.."
products="$PWD/DerivedData/Build/Products/Debug"
maps="$PWD/DerivedData/Build/Intermediates.noindex/GeneratedModuleMaps"
checks_dir=$(mktemp -d /tmp/rune-highlighting.XXXXXX)
flags=()
for module in TreeSitter TreeSitterSwift TreeSitterRuby TreeSitterGo; do
    flags+=(-Xcc "-fmodule-map-file=$maps/$module.modulemap")
done
xcrun swiftc -O -I "$products" -F "$products/PackageFrameworks" \
    "${flags[@]}" Rune/Editor/SyntaxHighlighter.swift Scripts/check-highlighting.swift \
    "$products/SwiftTreeSitter.o" "$products/TreeSitter.o" \
    "$products/TreeSitterSwift.o" "$products/TreeSitterRuby.o" "$products/TreeSitterGo.o" \
    -o "$checks_dir/check-highlighting"
"$checks_dir/check-highlighting"
