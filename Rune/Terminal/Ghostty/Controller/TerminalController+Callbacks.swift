//
//  TerminalController+Callbacks.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

import AppKit

private nonisolated enum TerminalCallbacks {
    static func wakeup(userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        Unmanaged<TerminalController>.fromOpaque(userdata)
            .takeUnretainedValue()
            .scheduleTick()
    }

    static func action(
        appPtr: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        guard let appPtr else { return false }
        guard ghostty_app_userdata(appPtr) != nil else { return false }
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        guard let surfacePtr = target.target.surface else { return false }
        guard let bridgePtr = ghostty_surface_userdata(surfacePtr) else { return false }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(bridgePtr)
            .takeUnretainedValue()
        guard Thread.isMainThread else {
            terminalRunOnMain { bridge.handleAction(action) }
            return false
        }
        return MainActor.assumeIsolated {
            bridge.handleAction(action)
            // Core spawns /usr/bin/open for an open_url reported unhandled,
            // so a host delegate that took the URL is reported as handling
            // it. Both open_url emitters run on the main thread.
            return action.tag == GHOSTTY_ACTION_OPEN_URL
                && bridge.delegate is any TerminalSurfaceOpenURLDelegate
        }
    }

    static func closeSurface(
        userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        guard let userdata else { return }
        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            bridge.handleClose(processAlive: processAlive)
        }
    }

    /// A program wrote the clipboard (OSC 52 or the Kitty clipboard
    /// protocol), or a copy binding did.
    ///
    /// `confirm` is ghostty's `clipboard-write = ask`: the write must not
    /// land until the host has asked. That goes through the same
    /// confirmation delegate as a protected read; a host without one denies
    /// it, as it does the read. The default configuration allows writes
    /// outright, and those land immediately.
    static func writeClipboard(
        userdata: UnsafeMutableRawPointer?,
        clipboard: ghostty_clipboard_e,
        contents: UnsafePointer<ghostty_clipboard_content_s>?,
        contentsLen: Int,
        confirm: Bool
    ) {
        // The selection clipboard is advertised (`supports_selection_clipboard`)
        // so that `copy-on-select` writes there and not to the one pasteboard
        // the user has — otherwise every drag, and every double-click a tap
        // lands within ghostty's click interval, would replace it. Nothing
        // exposes a primary selection, so those writes go nowhere.
        guard clipboard == GHOSTTY_CLIPBOARD_STANDARD else { return }
        guard contentsLen > 0, let contents else { return }
        let entries = UnsafeBufferPointer(start: contents, count: contentsLen)
        // Several representations may arrive together (the Kitty clipboard
        // protocol can carry images); the pasteboard here only carries
        // text, so only the text/plain one is written.
        guard let chosen = entries.first(where: { $0.mime.map { String(cString: $0) } == "text/plain" }),
              let data = chosen.data
        else { return }
        // The data is length-delimited and not necessarily NUL-terminated.
        let string = String(decoding: UnsafeRawBufferPointer(start: data, count: chosen.len), as: UTF8.self)
        TerminalDebugLog.log(
            .input,
            "clipboard write bytes=\(chosen.len) confirm=\(confirm)"
        )

        guard confirm else {
            terminalRunOnMain { setPasteboardString(string) }
            return
        }
        guard let userdata else { return }
        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            bridge.handleClipboardConfirmation(contents: string, kind: .osc52Write) { allowed in
                TerminalDebugLog.log(
                    .input,
                    allowed ? "clipboard write allowed" : "clipboard write denied"
                )
                guard allowed else { return }
                setPasteboardString(string)
            }
        }
    }

    @MainActor
    private static func setPasteboardString(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// One representation of a clipboard, copied out of ghostty's memory.
    private struct ClipboardRepresentation: Sendable {
        let mime: String
        let data: [UInt8]
    }

    /// Ghostty asks for the representations it wants served (`mimes`) and,
    /// for a paste event, a listing of what the clipboard holds (`list`).
    /// Only text is served. Returning `STARTED` promises that
    /// `ghostty_surface_complete_clipboard_request` or
    /// `ghostty_surface_deny_clipboard_request` follows; the other results
    /// are answered by ghostty and need no follow-up.
    static func readClipboard(
        userdata: UnsafeMutableRawPointer?,
        clipboard: ghostty_clipboard_e,
        opaquePtr: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let userdata, let opaquePtr else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let surface = bridge.rawSurface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        // Only the standard clipboard exists here: nothing exposes a
        // primary selection, so `paste_from_selection` has nothing to read.
        guard clipboard == GHOSTTY_CLIPBOARD_STANDARD else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

        var wantsText = false
        if let mimes {
            for index in 0 ..< mimesLen {
                if let mime = mimes[index], String(cString: mime) == "text/plain" { wantsText = true }
            }
        }

        // Text and file URLs only. This also serves a program's OSC 52 read,
        // which must not write files as a side effect.
        var representations: [ClipboardRepresentation] = []
        if wantsText, let text = TerminalPasteboardContent.text() {
            representations.append(ClipboardRepresentation(mime: "text/plain", data: Array(text.utf8)))
        }
        // The listing only inspects declared types and never reads data.
        let available = list && TerminalPasteboardContent.hasText() ? ["text/plain"] : []

        // Nothing to serve and no listing requested: nothing to complete with.
        if representations.isEmpty && !list {
            TerminalDebugLog.log(.input, "clipboard paste read empty")
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }
        completeClipboardRequest(
            surface,
            representations: representations,
            available: available,
            opaquePtr: opaquePtr,
            confirmed: false
        )
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// Hands ghostty what a clipboard request resolved to. The data is
    /// copied into C memory for the duration of the call and passed with
    /// explicit lengths, so embedded NUL bytes survive.
    private static func completeClipboardRequest(
        _ surface: ghostty_surface_t,
        representations: [ClipboardRepresentation],
        available: [String],
        opaquePtr: UnsafeMutableRawPointer,
        confirmed: Bool
    ) {
        TerminalDebugLog.log(
            .input,
            "clipboard request complete representations=\(representations.count) bytes=\(representations.reduce(0) { $0 + $1.data.count }) confirmed=\(confirmed)"
        )
        var strings: [UnsafeMutablePointer<CChar>] = []
        var buffers: [UnsafeMutableRawPointer] = []
        defer {
            strings.forEach { free($0) }
            buffers.forEach { $0.deallocate() }
        }

        var cContents: [ghostty_clipboard_content_s] = []
        for representation in representations {
            guard let mime = strdup(representation.mime) else { continue }
            strings.append(mime)
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(representation.data.count, 1), alignment: 1)
            buffers.append(buffer)
            representation.data.withUnsafeBytes { source in
                if let base = source.baseAddress {
                    buffer.copyMemory(from: base, byteCount: source.count)
                }
            }
            cContents.append(ghostty_clipboard_content_s(
                mime: mime,
                data: buffer.assumingMemoryBound(to: CChar.self),
                len: representation.data.count
            ))
        }

        var cAvailable: [UnsafePointer<CChar>?] = []
        for mime in available {
            guard let string = strdup(mime) else { continue }
            strings.append(string)
            cAvailable.append(UnsafePointer(string))
        }

        cContents.withUnsafeBufferPointer { contentsBuffer in
            cAvailable.withUnsafeBufferPointer { availableBuffer in
                var complete = ghostty_clipboard_complete_s(
                    contents: contentsBuffer.baseAddress,
                    contents_len: contentsBuffer.count,
                    available: availableBuffer.baseAddress,
                    available_len: availableBuffer.count,
                    confirmed: confirmed,
                    remember: false
                )
                ghostty_surface_complete_clipboard_request(surface, &complete, opaquePtr)
            }
        }
    }

    /// Ghostty needs the host's decision before it completes a request. The
    /// host answers through the confirmation delegate. Allowing completes the
    /// request with exactly the contents ghostty showed. Denying calls
    /// `ghostty_surface_deny_clipboard_request`, which also answers a
    /// program that is waiting for a reply (OSC 52, Kitty clipboard).
    static func confirmReadClipboard(
        userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        opaquePtr: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let userdata, let opaquePtr else { return }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let surface = bridge.rawSurface else { return }
        guard let confirm, let kind = TerminalClipboardRequestKind(request) else {
            ghostty_surface_deny_clipboard_request(surface, opaquePtr)
            return
        }

        // `confirm` is only valid during this call, but the answer may come
        // later, so copy what it holds.
        let pending = confirm.pointee
        var representations: [ClipboardRepresentation] = []
        if let contents = pending.contents {
            for index in 0 ..< pending.contents_len {
                let content = contents[index]
                guard let mime = content.mime else { continue }
                let data: [UInt8] = if let bytes = content.data, content.len > 0 {
                    Array(UnsafeRawBufferPointer(start: bytes, count: content.len))
                } else {
                    []
                }
                representations.append(ClipboardRepresentation(mime: String(cString: mime), data: data))
            }
        }
        var available: [String] = []
        if let listed = pending.available {
            for index in 0 ..< pending.available_len {
                if let mime = listed[index] { available.append(String(cString: mime)) }
            }
        }

        // The host shows text. Show the text representation when there is one
        // and summarize the others.
        let text = representations.first { $0.mime == "text/plain" }
            .map { String(decoding: $0.data, as: UTF8.self) }
            ?? representations.map { "\($0.mime) (\($0.data.count) bytes)" }.joined(separator: "\n")
        let requestState = UInt(bitPattern: opaquePtr)
        let pendingRepresentations = representations
        let pendingAvailable = available
        TerminalDebugLog.log(
            .input,
            "clipboard confirm request=\(request.rawValue) bytes=\(text.utf8.count) lines=\(TerminalInputText.lineCount(in: text))"
        )
        terminalRunOnMain {
            guard let surface = bridge.rawSurface else { return }
            guard let opaquePtr = UnsafeMutableRawPointer(bitPattern: requestState) else {
                return
            }
            bridge.handleClipboardConfirmation(
                contents: text,
                kind: kind
            ) { allowed in
                guard bridge.rawSurface == surface else { return }
                TerminalDebugLog.log(
                    .input,
                    allowed ? "clipboard request allowed" : "clipboard request denied"
                )
                if allowed {
                    completeClipboardRequest(
                        surface,
                        representations: pendingRepresentations,
                        available: pendingAvailable,
                        opaquePtr: opaquePtr,
                        confirmed: true
                    )
                } else {
                    ghostty_surface_deny_clipboard_request(surface, opaquePtr)
                }
            }
        }
    }
}

nonisolated func terminalControllerWakeupCallback(userdata: UnsafeMutableRawPointer?) {
    TerminalCallbacks.wakeup(userdata: userdata)
}

nonisolated func terminalControllerActionCallback(
    appPtr: ghostty_app_t?,
    target: ghostty_target_s,
    action: ghostty_action_s
) -> Bool {
    TerminalCallbacks.action(appPtr: appPtr, target: target, action: action)
}

nonisolated func terminalControllerCloseSurfaceCallback(
    userdata: UnsafeMutableRawPointer?,
    processAlive: Bool
) {
    TerminalCallbacks.closeSurface(userdata: userdata, processAlive: processAlive)
}

nonisolated func terminalControllerWriteClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    contents: UnsafePointer<ghostty_clipboard_content_s>?,
    contentsLen: Int,
    confirm: Bool
) {
    TerminalCallbacks.writeClipboard(
        userdata: userdata,
        clipboard: clipboard,
        contents: contents,
        contentsLen: contentsLen,
        confirm: confirm
    )
}

nonisolated func terminalControllerReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    opaquePtr: UnsafeMutableRawPointer?,
    mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    mimesLen: Int,
    list: Bool
) -> ghostty_clipboard_read_result_e {
    TerminalCallbacks.readClipboard(
        userdata: userdata,
        clipboard: clipboard,
        opaquePtr: opaquePtr,
        mimes: mimes,
        mimesLen: mimesLen,
        list: list
    )
}

nonisolated func terminalControllerConfirmReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    opaquePtr: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
) {
    TerminalCallbacks.confirmReadClipboard(
        userdata: userdata,
        confirm: confirm,
        opaquePtr: opaquePtr,
        request: request
    )
}
