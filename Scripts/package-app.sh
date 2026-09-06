#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
: "${RUNE_VERSION:?Set RUNE_VERSION to X.Y.Z}"
: "${SPARKLE_PUBLIC_KEY:?Set SPARKLE_PUBLIC_KEY for Rune}"
if [[ ! "$RUNE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "RUNE_VERSION must be X.Y.Z" >&2
    exit 1
fi
if [[ ! "$SPARKLE_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "SPARKLE_PUBLIC_KEY must be a base64-encoded Ed25519 public key" >&2
    exit 1
fi

xcodebuild -project Rune.xcodeproj -scheme Rune -configuration Release \
    -derivedDataPath DerivedData -destination 'generic/platform=macOS' \
    build CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$RUNE_VERSION" CURRENT_PROJECT_VERSION="$RUNE_VERSION" \
    MACOSX_DEPLOYMENT_TARGET=26.0

app="DerivedData/Build/Products/Release/Rune.app"
plist="$app/Contents/Info.plist"
plutil -replace SUPublicEDKey -string "$SPARKLE_PUBLIC_KEY" "$plist"
sparkle="DerivedData/SourcePackages/artifacts/sparkle/Sparkle"
test -d "$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/Resources/Licenses"
cp "$sparkle/LICENSE" "$app/Contents/Resources/Licenses/Sparkle.txt"

# Match brrr's ad-hoc distribution. EdDSA signs updates, not Apple notarization.
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
test "$(lipo -archs "$app/Contents/MacOS/Rune")" = arm64
test "$(plutil -extract CFBundleShortVersionString raw "$plist")" = "$RUNE_VERSION"
test "$(plutil -extract CFBundleVersion raw "$plist")" = "$RUNE_VERSION"
test "$(plutil -extract LSMinimumSystemVersion raw "$plist")" = 26.0
test "$(plutil -extract SUPublicEDKey raw "$plist")" = "$SPARKLE_PUBLIC_KEY"

mkdir -p build
ditto -c -k --sequesterRsrc --keepParent "$app" build/Rune-arm64.zip
(cd build && shasum -a 256 Rune-arm64.zip > Rune-arm64.zip.sha256)
echo "Packaged build/Rune-arm64.zip (macOS 26+, Apple Silicon)"
