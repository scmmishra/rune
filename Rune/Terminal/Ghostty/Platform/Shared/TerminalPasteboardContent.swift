//
//  TerminalPasteboardContent.swift
//  libghostty-spm
//
//  Reference:
//  - ghostty-org/ghostty
//  - macos/Sources/Helpers/NSPasteboard+Extension.swift
//    (`getOpinionatedStringContents`: URLs first — file URLs paste as
//    escaped paths, others verbatim — then the string)
//

import Foundation
import UniformTypeIdentifiers

import AppKit

/// What a paste hands the terminal, read off the general pasteboard the way
/// Ghostty's macOS app reads it: files as shell-escaped paths, text as-is.
///
/// Two readers, deliberately kept apart:
///
/// - ``text(from:)`` is what ghostty's `read_clipboard` callback uses. It
///   serves the paste binding *and* a program's OSC 52 read, so it has no
///   side effects and never touches the disk.
/// - ``files(from:completion:)`` (UIKit) is for a host-driven paste when the
///   pasteboard holds raw image or document data with no path at all — a
///   screenshot, a photo, a file copied out of Files. That data is staged as
///   a file first (``TerminalFileStaging``) so the paste lands as a path a
///   program can open; a program asking for "the clipboard" must never
///   trigger that write.
public nonisolated enum TerminalPasteboardContent {
    /// Upstream's `getOpinionatedStringContents`, as the one rule every
    /// reader applies: URLs first — a file URL as its shell-escaped path,
    /// any other verbatim — then the string. The order matters: a file
    /// copied in Finder or Files carries both its URL and its display name
    /// as the string, and taking the string first pasted the name.
    static func text(string: String?, urls: [URL]) -> String? {
        if !urls.isEmpty {
            return urls
                .map { $0.isFileURL ? TerminalShellEscape.escape($0.path) : $0.absoluteString }
                .joined(separator: " ")
        }
        guard let string, !string.isEmpty else { return nil }
        return string
    }

    /// Whether ``text(from:)`` could return text, judged from the declared
    /// pasteboard types without reading any data.
    static func hasText(in pasteboard: NSPasteboard = .general) -> Bool {
        let types = pasteboard.types ?? []
        return types.contains(.string) || types.contains(.fileURL)
    }

    /// The pasteboard as text — see ``text(string:urls:)``.
    static func text(from pasteboard: NSPasteboard = .general) -> String? {
        text(
            string: pasteboard.string(forType: .string),
            urls: (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        )
    }
}
