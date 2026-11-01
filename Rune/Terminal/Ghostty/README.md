# Ghostty terminal layer

This code is the macOS part of the `GhosttyTerminal` module from [libghostty-spm](https://github.com/Lakr233/libghostty-spm) by @Lakr233, copied into Rune and now maintained here.

- Package: libghostty-spm
- Tag: 1.5.2
- Commit: 4a92e0102ba134b7f4bdd7a2d1c3b9cfa9614edd
- License: MIT. See `LICENSE` in this folder.

Ghostty's renderer paces the frames. Swift only ticks the app and never draws.

The Ghostty core is not from the package. `Scripts/build-ghostty.sh` builds it from Ghostty source into `Vendor/GhosttyKit.xcframework`, and the Xcode project links that. The script also copies the shell integration and terminfo into `Rune/Resources`.

## What was removed

- UIKit views, the input accessory bar, and every `#if canImport(UIKit)`, iOS, and Mac Catalyst branch.
- In-memory (host-managed) terminal sessions: `InMemoryTerminalSession` and its helpers, `TerminalSessionBackend`, and `TerminalSurfaceOptions.backend`. Rune only runs the exec backend.
- `ShellCraftKit`, `GhosttyTheme`, and the theme catalog. Rune keeps its own colors in `Rune/Terminal/TerminalColors.swift`.
- `PlatformSupport.swift`, which only guarded against targets with neither UIKit nor AppKit.
- Code only the UIKit views called: file staging for pasted images, the long-press text-selection request, quicklook word lookup, selection anchors, IME composition helpers, the software key commit router, and the USB HID key tables.
- The `#if DEBUG` test hooks on `TerminalSurfaceCoordinator`.
- The package's shared display link and every per-frame draw and refresh call. The package ticked and drew from a display link. Rune only ticks the app, and passes the window's occlusion, display id and app focus to Ghostty.

## What changed

- `GhosttyRuntimeResources` reads the shell integration and terminfo from the app bundle (`Bundle.main`) instead of the package's resource bundle. The files live in `Rune/Resources/Ghostty` and `Rune/Resources/terminfo`.
- Every top-level declaration that was not `@MainActor` is marked `nonisolated`, because Rune builds with main-actor default isolation and the package does not.
- `TerminalCallbackBridge` moved from `InMemory/` to `Controller/`, because the exec backend uses it too.
- `TerminalPasteboardContent` keeps only the AppKit reader.
- `TerminalSurfaceView` uses the two-parameter `onChange`.
- Rune's own `TerminalSurface` enum is now `TerminalBackground`, because this module's `TerminalSurface` class has the old name.
- The clipboard callbacks follow the Ghostty 1.4.0 C API: explicit lengths, the confirm struct, and `ghostty_surface_deny_clipboard_request` for a refused request. Only `text/plain` is served and written.
