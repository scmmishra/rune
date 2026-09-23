import AppKit
import GhosttyTerminal

/// libghostty tells its surface delegate about a ⌘-clicked link, and spawns `/usr/bin/open`
/// itself unless that delegate handles it. `TerminalViewState` doesn't adopt the open-URL
/// protocol, so Rune wraps it in this proxy: the state keeps every callback it already
/// handles, and Rune gets the chance to open a project file in its own editor.
@MainActor
final class TerminalLinkDelegate: NSObject,
    TerminalSurfaceOpenURLDelegate,
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceScrollbarDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceTextSelectionRequestDelegate,
    TerminalSurfaceClipboardConfirmationDelegate
{
    let state: TerminalViewState
    var onOpenURL: ((String) -> Void)?

    init(state: TerminalViewState) {
        self.state = state
    }

    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        onOpenURL?(url)
    }

    func terminalDidChangeTitle(_ title: String) { state.terminalDidChangeTitle(title) }
    func terminalDidResize(_ size: TerminalGridMetrics) { state.terminalDidResize(size) }
    func terminalDidChangeFocus(_ focused: Bool) { state.terminalDidChangeFocus(focused) }
    func terminalDidClose(processAlive: Bool) { state.terminalDidClose(processAlive: processAlive) }
    func terminalDidRingBell() { state.terminalDidRingBell() }
    func terminalDidRequestDesktopNotification(title: String, body: String) {
        state.terminalDidRequestDesktopNotification(title: title, body: body)
    }
    func terminalDidChangeWorkingDirectory(_ path: String) { state.terminalDidChangeWorkingDirectory(path) }
    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) { state.terminalDidUpdateScrollbar(scrollbar) }
    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        state.terminalDidFinishCommand(exitCode: exitCode, durationNanos: durationNanos)
    }
    func terminalDidAttachSurface(_ surface: GhosttyTerminal.TerminalSurface) { state.terminalDidAttachSurface(surface) }
    func terminalDidDetachSurface() { state.terminalDidDetachSurface() }
    func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest) {
        state.terminalDidRequestTextSelection(request)
    }
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        state.terminalDidRequestClipboardConfirmation(request)
    }
}
