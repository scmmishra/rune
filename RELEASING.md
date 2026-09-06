# Releasing Rune

Publishing a GitHub Release triggers an Apple Silicon Release build, highlighting
checks, a ZIP and SHA-256 checksum, and a signed Sparkle update feed. Rune requires
**macOS 26.0 or newer**. CI uses an arm64 macOS 26 runner so the checks can run,
selects Xcode 26.6 and the macOS 26 SDK, and verifies the packaged minimum OS
and generated feed. Both the runner OS and deployment target are explicit.

## One-time signing setup

Rune uses Sparkle 2.9.5, matching brrr. Generate a separate Rune key, not brrr's:

```sh
xcodebuild -resolvePackageDependencies -project Rune.xcodeproj -scheme Rune -derivedDataPath DerivedData
DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account rune
```

Store the printed public key as the repository Actions variable
`SPARKLE_PUBLIC_KEY`. Export the private key into a temporary file and upload it
without printing it:

```sh
private_key_file="$(mktemp)"
DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account rune -x "$private_key_file"
gh secret set SPARKLE_PRIVATE_KEY --repo scmmishra/rune < "$private_key_file"
rm "$private_key_file"
```

Back up the private key securely. Never commit it, print it, or replace it casually:
installed copies trust its public half to authenticate subsequent updates.

## Publish

1. Push the release code, including the resolved package lockfile.
2. Publish a GitHub Release tagged `vX.Y.Z`, with user-facing release notes.
3. Wait for **Build Release** to upload `Rune-arm64.zip`, its checksum, and
   `appcast.xml`. Release notes are embedded in the feed as Markdown.
4. Mark the intended stable release as latest. Sparkle reads
   `https://github.com/scmmishra/rune/releases/latest/download/appcast.xml`.

Prereleases also build but are not offered through the stable latest-release URL.
Keep stable version numbers increasing. Do not mark an older release as latest.
The workflow uses the GitHub release body directly rather than editing a changelog
on the default branch.

## Local packaging and verification

```sh
RUNE_VERSION=0.1.0 SPARKLE_PUBLIC_KEY='<public key>' bash Scripts/package-app.sh
```

This builds with Xcode, preserves the app's resource bundles and embedded
frameworks, and writes the archive into `build/`. It does not install or launch it.
Debug builds never start the updater. Release builds without a valid public key
also leave updates disabled. Distributed builds provide **Check for Updates…**
in the Rune menu and automatic-update controls in Settings.

Like brrr, packaging currently uses ad-hoc code signing, **not Developer ID signing
or notarization**. Sparkle signatures authenticate updates; they do not remove
Gatekeeper's first-install warnings. Developer ID distribution requires a separate
certificate and notarization setup.

Before shipping broadly, test an installed older release updating to a newer one
on macOS 26, including signature rejection and manual/automatic update behavior.
Local builds alone cannot verify the hosted end-to-end update path.

## References

- [brrr release workflow](https://github.com/scmmishra/brrr/blob/main/.github/workflows/release.yml)
- [Sparkle setup and signing](https://sparkle-project.org/documentation/)
- [Sparkle SwiftUI integration](https://sparkle-project.org/documentation/programmatic-setup/#create-an-updater-in-swiftui)
- [Sparkle settings](https://sparkle-project.org/documentation/preferences-ui/#adding-settings-in-swiftui)
- [Publishing updates](https://sparkle-project.org/documentation/publishing/)
