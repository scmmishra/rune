#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
checks_dir=$(mktemp -d /tmp/rune-file-tree-actions.XXXXXX)
trap 'rm -rf "$checks_dir"' EXIT
mkdir -p "$checks_dir/project"
xcrun swiftc -module-cache-path "$checks_dir/module-cache" \
    Rune/Files/FileTreeActions.swift Scripts/check-file-tree-actions.swift \
    -o "$checks_dir/check-file-tree-actions"
"$checks_dir/check-file-tree-actions" "$checks_dir/project"
