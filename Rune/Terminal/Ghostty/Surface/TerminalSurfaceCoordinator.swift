//
//  TerminalSurfaceCoordinator.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

/// Shared terminal state and logic used by both UIKit and AppKit views.
///
/// Platform views own a `TerminalSurfaceCoordinator` instance and set platform-specific
/// hooks via closures. The core handles surface lifecycle, metrics
/// synchronization. Ghostty's renderer thread paces and draws the frames.
@MainActor
final class TerminalSurfaceCoordinator {
    weak var delegate: (any TerminalSurfaceViewDelegate)? {
        didSet { bridge.delegate = delegate }
    }

    var controller: TerminalController? {
        didSet {
            guard controller !== oldValue else { return }
            rebuildIfReady(removingBridgeFrom: oldValue)
        }
    }

    var configuration: TerminalSurfaceOptions = .init() {
        didSet {
            guard !configuration.isEquivalent(to: oldValue) else { return }
            rebuildIfReady()
        }
    }

    var surface: TerminalSurface?
    let bridge = TerminalCallbackBridge()

    // MARK: - Platform Hooks

    var isAttached: () -> Bool = { false }
    /// Whether the view's window is visible on screen, from its
    /// `occlusionState`. Independent of whether the app is active.
    var isWindowVisible: () -> Bool = { false }
    /// The `CGDirectDisplayID` of the screen the window is on, if known.
    var displayID: () -> UInt32? = { nil }
    var scaleFactor: () -> Double = { 2.0 }
    var viewSize: () -> (width: Double, height: Double) = { (0, 0) }
    var platformSetup: ((inout ghostty_surface_config_s) -> Void)?
    var onMetricsUpdate: (() -> Void)?
    var onCellSizeDidChange: (() -> Void)?

    private var lastMetrics: TerminalViewportMetrics?

    /// The view size, in points, the surface was last sized to. While a
    /// resize throttle window is open this trails the live bounds: the
    /// surface's IOSurface is still the old size, so a platform layer that
    /// stretches to the new bounds shows the old pixels scaled — and the
    /// engine, deriving `contentsScale` from old pixels over new points,
    /// fights the host's correction on every tick. A UIKit host keeps its
    /// sublayer at *this* size until the trailing sync lands, so the gap
    /// shows background instead of a stretched frame. `nil` until the first
    /// sync and after teardown.
    private(set) var syncedViewSize: (width: Double, height: Double)?

    /// What the host declared through `setSurfaceVisible`. A hidden tab keeps
    /// its view in the window, so only this flag tells that it is hidden.
    private var isDisplayVisible = true
    /// The last visibility the SwiftUI host declared through
    /// `TerminalViewState.isSurfaceVisible`. The representable forwards only
    /// changes to this value, so an imperative `setSurfaceVisible` call made
    /// between SwiftUI updates is not silently reverted by every refresh
    /// re-stamping the declarative default.
    var hostDeclaredDisplayVisible: Bool?
    /// The last occlusion and display id sent to the current surface, so
    /// repeated updates do not repeat the C calls. Reset with the surface.
    private var sentOcclusion: Bool?
    private var sentDisplayID: UInt32?

    init() {
        bridge.onCellSizeChange = { [weak self] width, height in
            self?.handleCellSizeChange(width: width, height: height)
        }
    }

    // MARK: - Surface Lifecycle

    func rebuildIfReady(removingBridgeFrom previousController: TerminalController? = nil) {
        // A pane that is merely hidden reports a zero size. Tearing the surface
        // down here and then bailing out at the size guard below would destroy
        // ghostty's grid and scrollback for a condition that is temporary: when
        // the pane comes back there is nothing left to show, and only the app
        // redrawing can refill it. Keep the surface — the caller re-runs this
        // once the view has a usable size again.
        //
        // This is the same intent as the reattach guard in viewDidMoveToWindow
        // ("rebuilding on every reattach discards Ghostty's scrollback/state"),
        // which cannot help while the teardown happens before the checks.
        if surface != nil, previousController == nil, !hasValidViewSize {
            // The rebuild is owed, not cancelled. Configuration options are
            // consumed only by createSurface, and no caller re-runs this once
            // the view regains a size (fitToSize, viewDidMoveToWindow and the
            // UIKit twin all take the surface != nil branch and merely sync
            // metrics). Dropping the request outright would leave a hidden
            // pane running its old configuration indefinitely.
            pendingRebuild = true
            let size = viewSize()
            TerminalDebugLog.log(
                .lifecycle,
                "surface kept: view size temporarily invalid \(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height))"
            )

            return
        }
        pendingRebuild = false

        tearDownSurface(removingBridgeFrom: previousController ?? controller)
        guard let controller else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild skipped: missing controller")
            return
        }
        guard isAttached() else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild skipped: view detached")
            return
        }
        guard hasValidViewSize else {
            let size = viewSize()
            TerminalDebugLog.log(
                .lifecycle,
                "surface rebuild skipped: invalid view size=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height))"
            )
            return
        }

        let scale = scaleFactor()
        TerminalDebugLog.log(
            .lifecycle,
            "surface rebuild scale=\(String(format: "%.2f", scale)) \(configuration.debugSummary)"
        )
        let rawSurface = controller.createSurface(
            bridge: bridge,
            configuration: configuration,
            platformSetup: { [self] config in
                platformSetup?(&config)
                config.scale_factor = scale
            }
        )
        guard let rawSurface else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild failed")
            return
        }

        bridge.rawSurface = rawSurface
        let newSurface = TerminalSurface(rawSurface)
        surface = newSurface
        updateOcclusion()
        updateDisplayID()
        TerminalDebugLog.log(.lifecycle, "surface rebuild succeeded")
        (delegate as? any TerminalSurfaceLifecycleDelegate)?
            .terminalDidAttachSurface(newSurface)
        synchronizeMetrics()
    }

    // MARK: - Metrics

    // Ghostty's IO thread coalesces resize messages with a hardcoded 25ms
    // trailing-only window (Thread.zig). For an alt-screen TUI that fully
    // repaints on every winsize (Claude Code), a live divider drag posts new
    // sizes faster than that window resolves — the grid reflow runs
    // permanently behind the layer bounds and the renderer composites the
    // stale grid into the new frame: the mid-drag collapse. Bounding the
    // stream (leading edge for responsiveness, trailing edge so the final
    // size always lands) hands the engine a signal it can settle on.
    //
    // The right window is CONTENT-dependent, so it is a per-surface value
    // the host sets (`TerminalSurfaceOptions.resizeThrottleMilliseconds`, or
    // the platform setter for a live change): a primary-screen transcript
    // that never re-emits its scrollback (codex-style) renders best fully
    // unthrottled — large throttled jumps read as blinking — while the
    // alt-screen full-repaint agents need ~96ms. 0 disables. The env var
    // GHOSTTY_SURFACE_RESIZE_THROTTLE_MS, when set, overrides every surface
    // for whole-process A/B runs.
    private static let resizeThrottleOverride: TimeInterval? = {
        guard
            let raw = ProcessInfo.processInfo
                .environment["GHOSTTY_SURFACE_RESIZE_THROTTLE_MS"],
            let ms = Double(raw), ms >= 0
        else { return nil }
        return ms / 1000
    }()

    /// Set directly by a platform view; otherwise sourced from
    /// `configuration.resizeThrottleMilliseconds`. Kept as an override so the
    /// AppKit setter can adjust a live surface without rebuilding it.
    var resizeThrottleInterval: TimeInterval?

    private var effectiveResizeThrottle: TimeInterval {
        if let override = Self.resizeThrottleOverride { return override }
        if let interval = resizeThrottleInterval { return interval }
        return max(0, configuration.resizeThrottleMilliseconds) / 1000
    }

    private var resizeThrottleArmed = false
    private var resizeThrottleTrailing = false
    /// Invalidates in-flight throttle timers across a teardown. A timer
    /// armed for the old surface must not size — or re-arm against — the
    /// surface that replaced it.
    private var resizeThrottleGeneration = 0
    /// A rebuild deferred by the zero-size guard above, replayed by
    /// `synchronizeMetrics` as soon as the view has a usable size again.
    private var pendingRebuild = false

    func synchronizeMetrics() {
        // Redeem a rebuild the zero-size guard deferred. Every caller that
        // could restore a usable size lands here, so this is the one place
        // that reliably observes the transition.
        if pendingRebuild, hasValidViewSize {
            pendingRebuild = false
            rebuildIfReady()
            return
        }

        guard effectiveResizeThrottle > 0 else {
            performMetricsSync()
            return
        }

        guard !resizeThrottleArmed else {
            // Newest wins: the trailing fire re-reads the live view size,
            // so nothing needs to be captured here.
            resizeThrottleTrailing = true
            return
        }

        // Arm only behind a size the surface actually received. The
        // creation-time cell_size callback lands here while `surface` is still
        // nil; arming then would make the new surface's own first sync wait
        // out a full window as a trailing edge.
        guard performMetricsSync() else { return }
        armResizeThrottle()
    }

    private func armResizeThrottle() {
        resizeThrottleArmed = true
        let generation = resizeThrottleGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + effectiveResizeThrottle
        ) { [weak self] in
            guard let self else { return }
            // A teardown bumped the generation: this timer belongs to a
            // surface that no longer exists. Returning without touching
            // `resizeThrottleArmed` leaves the current surface's own state
            // alone.
            guard generation == resizeThrottleGeneration else { return }
            resizeThrottleArmed = false
            guard resizeThrottleTrailing else { return }
            resizeThrottleTrailing = false
            guard performMetricsSync() else { return }
            armResizeThrottle()
        }
    }

    /// Returns whether a size reached the surface.
    @discardableResult
    private func performMetricsSync() -> Bool {
        guard let surface else {
            TerminalDebugLog.log(.metrics, "synchronizeMetrics skipped: missing surface")
            return false
        }

        let scale = scaleFactor()
        let size = viewSize()
        guard size.width > 0, size.height > 0 else {
            TerminalDebugLog.log(
                .metrics,
                "synchronizeMetrics skipped: invalid view size=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height))"
            )
            return false
        }

        let pixelWidth = UInt32((size.width * scale).rounded(.down))
        let pixelHeight = UInt32((size.height * scale).rounded(.down))
        guard pixelWidth > 0, pixelHeight > 0 else {
            TerminalDebugLog.log(
                .metrics,
                "synchronizeMetrics skipped: invalid pixel size=\(pixelWidth)x\(pixelHeight)"
            )
            return false
        }

        TerminalDebugLog.log(
            .metrics,
            "sync view=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height)) scale=\(String(format: "%.2f", scale)) pixels=\(pixelWidth)x\(pixelHeight)"
        )

        surface.setContentScale(x: scale, y: scale)
        surface.setSize(width: pixelWidth, height: pixelHeight)
        syncedViewSize = size

        guard let surfaceSize = surface.size(),
              surfaceSize.columns > 0, surfaceSize.rows > 0
        else {
            TerminalDebugLog.log(.metrics, "sync missing grid metrics after resize")
            onMetricsUpdate?()
            return true
        }

        let metrics = TerminalViewportMetrics(surfaceSize: surfaceSize, scale: scale)
        guard metrics != lastMetrics else {
            TerminalDebugLog.log(
                .metrics,
                "sync unchanged \(metrics.debugSummary)"
            )
            onMetricsUpdate?()
            return true
        }

        lastMetrics = metrics
        TerminalDebugLog.log(.metrics, "sync updated \(metrics.debugSummary)")
        if let delegate = delegate as? any TerminalSurfaceGridResizeDelegate {
            delegate.terminalDidResize(surfaceSize)
        } else if let delegate = delegate as? any TerminalSurfaceResizeDelegate {
            delegate.terminalDidResize(
                columns: Int(surfaceSize.columns),
                rows: Int(surfaceSize.rows)
            )
        }
        onMetricsUpdate?()
        return true
    }

    func fitToSize() {
        if surface == nil {
            rebuildIfReady()
        } else {
            synchronizeMetrics()
        }
    }

    /// Sends the surface's visibility to Ghostty, which stops rendering a
    /// surface that is not visible. Visible means the host shows it, it is
    /// in a window, and that window is on screen. App activation does not
    /// matter: a terminal in a visible window keeps rendering while another
    /// app is in front.
    ///
    /// This never stops app ticks. They drain the app mailbox for every
    /// surface, hidden or not (see `TerminalController.scheduleTick`).
    func updateOcclusion() {
        guard let surface else { return }
        let visible = isDisplayVisible && isAttached() && isWindowVisible()
        guard sentOcclusion != visible else { return }
        sentOcclusion = visible
        surface.setOcclusion(visible)
    }

    func setDisplayVisible(_ visible: Bool) {
        isDisplayVisible = visible
        updateOcclusion()
    }

    /// Tells Ghostty which display the window is on. Ghostty binds the
    /// renderer's display link to it, so frames follow that display's
    /// refresh rate.
    func updateDisplayID() {
        guard let surface, let id = displayID(), sentDisplayID != id else { return }
        sentDisplayID = id
        surface.setDisplayID(id)
    }

    // MARK: - Focus

    func setFocus(_ focused: Bool) {
        TerminalDebugLog.log(.lifecycle, "focus=\(focused)")
        surface?.setFocus(focused)
        (delegate as? any TerminalSurfaceFocusDelegate)?
            .terminalDidChangeFocus(focused)
    }

    // MARK: - Cleanup

    func freeSurface() {
        TerminalDebugLog.log(.lifecycle, "free surface")
        tearDownSurface(removingBridgeFrom: controller)
    }

    deinit {
        // `@MainActor` classes have a nonisolated deinit by default, but
        // `tearDownSurface` calls methods on other main-actor types (surface,
        // bridge, controller). We rely on deinit running synchronously with
        // exclusive access; assume main-actor isolation so teardown can run
        // inline without crossing isolation.
        MainActor.assumeIsolated {
            tearDownSurface(removingBridgeFrom: controller)
        }
    }

    private func tearDownSurface(removingBridgeFrom controller: TerminalController?) {
        TerminalDebugLog.log(.lifecycle, "tear down surface")
        bridge.rawSurface = nil
        let hadSurface = surface != nil
        surface?.setFocus(false)
        surface?.free()
        surface = nil
        lastMetrics = nil
        syncedViewSize = nil
        // Retire any armed timer with the surface it was armed for, and
        // clear the gate so the replacement surface sizes immediately
        // instead of being suppressed by the old surface's armed flag.
        resizeThrottleGeneration &+= 1
        resizeThrottleArmed = false
        resizeThrottleTrailing = false
        sentOcclusion = nil
        sentDisplayID = nil
        controller?.remove(bridge)
        if hadSurface {
            (delegate as? any TerminalSurfaceLifecycleDelegate)?
                .terminalDidDetachSurface()
        }
    }

    private func handleCellSizeChange(width: UInt32, height: UInt32) {
        TerminalDebugLog.log(
            .metrics,
            "cell size changed width=\(width) height=\(height)"
        )
        synchronizeMetrics()
        onCellSizeDidChange?()
    }

    private var hasValidViewSize: Bool {
        let size = viewSize()
        return size.width > 0 && size.height > 0
    }
}
