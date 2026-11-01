#!/bin/bash
# Build GhosttyKit.xcframework (macOS arm64, ReleaseFast) from Ghostty's source.
# Output: Vendor/GhosttyKit.xcframework and Vendor/GhosttyResources.
# It also copies the shell integration and terminfo into Rune/Resources, which are tracked
# in git, so the resources in the app always match this Ghostty version.
# To upgrade Ghostty, change the two lines below and run this script.
# Patches in Scripts/ghostty-patches/*.patch are applied to the source before the build.
# Drop a patch once the pinned version contains the fix.
GHOSTTY_VERSION="v1.4.0"
# The commit the tag points to. A moved tag fails the build.
GHOSTTY_SHA="83fb95624b0439ee660c2679b43b38c8b63769cd"
# -Dxcframework-target=native builds arm64 only. The macOS app is skipped.
# Sentry stays off: it would install its crash handler in Rune's process.
ZIG_FLAGS="-Doptimize=ReleaseFast -Dapp-runtime=none -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native -Dsentry=false"

set -eu

cd "$(dirname "$0")/.."
root="$PWD"
source_dir="$root/build/ghostty-src"
vendor_dir="$root/Vendor"
output="$vendor_dir/GhosttyKit.xcframework"
resources_output="$vendor_dir/GhosttyResources"
stamp="$vendor_dir/GhosttyKit.stamp"

# Rune ships these two folders without the themes. Xcode copies them into the app as is.
# --checksum leaves files with unchanged content alone, so a no-op sync touches nothing.
sync_app_resources() {
    rsync -a --checksum --delete "$resources_output/ghostty/shell-integration/" "$root/Rune/Resources/Ghostty/shell-integration/"
    rsync -a --checksum --delete "$resources_output/terminfo/" "$root/Rune/Resources/terminfo/"
}

# The patches are part of the stamp, so changing one rebuilds.
patch_files=("$root"/Scripts/ghostty-patches/*.patch)
[ -e "${patch_files[0]}" ] || patch_files=()
patches_hash=$( (echo "patches"; [ ${#patch_files[@]} -eq 0 ] || cat "${patch_files[@]}") | shasum -a 256 | cut -d' ' -f1)
stamp_value="$GHOSTTY_SHA $ZIG_FLAGS $patches_hash"
if [ -d "$output" ] && [ -d "$resources_output" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$stamp_value" ]; then
    sync_app_resources
    echo "GhosttyKit.xcframework is up to date ($GHOSTTY_VERSION)."
    exit 0
fi

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "build-ghostty: this script builds for macOS on Apple silicon only." >&2
    exit 1
fi

# Ghostty compiles its Metal shaders, which needs Xcode's separate Metal Toolchain.
if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    echo "build-ghostty: the Metal Toolchain is missing. Run 'xcodebuild -downloadComponent MetalToolchain'." >&2
    exit 1
fi

mkdir -p "$source_dir"
if [ ! -d "$source_dir/.git" ]; then
    git -C "$source_dir" init -q
    git -C "$source_dir" remote add origin https://github.com/ghostty-org/ghostty.git
fi
if ! git -C "$source_dir" cat-file -e "$GHOSTTY_SHA^{commit}" 2>/dev/null; then
    git -C "$source_dir" fetch -q --depth 1 origin "refs/tags/$GHOSTTY_VERSION:refs/tags/$GHOSTTY_VERSION"
fi
tag_sha=$(git -C "$source_dir" rev-parse "refs/tags/$GHOSTTY_VERSION^{commit}" 2>/dev/null || true)
if [ "$tag_sha" != "$GHOSTTY_SHA" ]; then
    echo "build-ghostty: $GHOSTTY_VERSION is at '${tag_sha:-unknown}', expected $GHOSTTY_SHA." >&2
    exit 1
fi
git -C "$source_dir" -c advice.detachedHead=false checkout -q -f "$GHOSTTY_SHA"
# Remove old outputs so a stale xcframework is never mistaken for a fresh one.
git -C "$source_dir" clean -fdq
for patch in ${patch_files[@]+"${patch_files[@]}"}; do
    git -C "$source_dir" apply "$patch"
    echo "Applied $(basename "$patch")."
done
rm -rf "$source_dir/zig-out"

# Ghostty needs one exact Zig release. mise.toml pins it.
required_zig=$(sed -n -E 's/^[[:space:]]*\.?minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$source_dir/build.zig.zon")
cd "$source_dir"
if [ "$(zig version)" != "$required_zig" ]; then
    echo "build-ghostty: Ghostty $GHOSTTY_VERSION needs Zig $required_zig, found $(zig version). Run 'mise install'." >&2
    exit 1
fi

# The xcframework step always installs the runtime resources (terminfo, shell integration).
# ZIG_FLAGS holds only flags, so word splitting is what we want here.
# shellcheck disable=SC2086
zig build $ZIG_FLAGS

cd "$root"
built="$source_dir/macos/GhosttyKit.xcframework"
if [ ! -d "$built" ] || [ ! -d "$source_dir/zig-out/share/ghostty" ]; then
    echo "build-ghostty: the build did not produce the xcframework or the resources." >&2
    exit 1
fi

rm -rf "$output" "$resources_output" "$stamp"
mkdir -p "$resources_output"
cp -R "$built" "$output"
cp -R "$source_dir/zig-out/share/ghostty" "$resources_output/ghostty"
cp -R "$source_dir/zig-out/share/terminfo" "$resources_output/terminfo"
printf '%s' "$stamp_value" > "$stamp"
sync_app_resources
echo "Built $output from Ghostty $GHOSTTY_VERSION."
