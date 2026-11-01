//
//  AppTerminalView+Lifecycle.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

import AppKit

/// SwiftUI focus-bridge hooks; behavior lives in +Lifecycle.
nonisolated struct FocusBridgeState {
    var onFocusChange: ((Bool) -> Void)?
}

extension AppTerminalView {
    func setupTrackingArea() {
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .inVisibleRect,
            .activeAlways,
        ]
        let area = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override open func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        setupTrackingArea()
    }

    override open var acceptsFirstResponder: Bool {
        true
    }

    override open func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        core.setFocus(true)
        focusBridge.onFocusChange?(true)
        return result
    }

    override open func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        core.setFocus(false)
        focusBridge.onFocusChange?(false)
        return result
    }

    override open func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObservers()
        if window != nil {
            // SwiftUI/AppKit can temporarily detach and reattach the terminal view while
            // diffing the view hierarchy. Rebuilding on every reattach discards Ghostty's
            // scrollback/state, so only create a new surface when one does not already exist.
            if surface == nil {
                core.rebuildIfReady()
            } else {
                core.synchronizeMetrics()
            }
            updateMetalLayerMetrics()
            updateColorScheme()
            core.updateOcclusion()
            core.updateDisplayID()

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
            // Ghostty stops rendering a surface in a window that is fully
            // covered, minimized or on another Space, as its own app does.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeOcclusionState),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
            // Cross-display rescue: AppKit posts didChangeScreen when the
            // window's screen reference changes, even when the new screen
            // has the same backingScaleFactor (in which case
            // viewDidChangeBackingProperties does not fire). Listening
            // here lets us re-run metric sync on every screen transition
            // — required for the case where two displays share scale but
            // differ in geometry / color profile, and harmless when
            // viewDidChangeBackingProperties also fires for the
            // different-scale case.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeScreen),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
            // Same runloop hop as `requestFocus`: attaching can happen
            // mid SwiftUI update, where the first-responder dance must
            // not mutate focus state.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                (delegate as? TerminalViewState)?.replayPendingFocusIfNeeded()
            }
        } else {
            // A detached view is not visible: Ghostty stops rendering it.
            core.updateOcclusion()
            core.setFocus(false)
        }
    }

    // Window key state is not a first-responder change: reporting it
    // through the focus bridge flips the host's FocusState, whose
    // synchronizeFocus then resigns a view that is still first responder.
    @objc func windowDidBecomeKey(_: Notification) {
        let focused = window?.isKeyWindow == true
            && window?.firstResponder === self
        core.setFocus(focused)
    }

    @objc func windowDidResignKey(_: Notification) {
        core.setFocus(false)
    }

    @objc func windowDidChangeOcclusionState(_: Notification) {
        core.updateOcclusion()
    }

    @objc func windowDidChangeScreen(_: Notification) {
        // Ghostty binds its display link to this display, so the renderer
        // follows the new display's refresh rate. Ghostty's own app does
        // this synchronously, before the deferred metrics pass below.
        core.updateDisplayID()
        // Defer one runloop tick so AppKit's layout pass and the
        // window's new backingScaleFactor have both settled before we
        // re-derive metrics. Calling synchronously can race with the
        // layout pass and re-introduce the drift we're trying to fix.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            updateMetalLayerMetrics()
            core.synchronizeMetrics()
        }
    }

    private func removeWindowObservers() {
        // Remove any existing key-window observers before registering for the
        // current window. AppKit can move the view directly between windows
        // without an intermediate nil attachment.
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
    }

    override open func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        core.fitToSize()
    }

    override open func layout() {
        super.layout()
        core.fitToSize()
    }

    override open func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMetalLayerMetrics()
        core.fitToSize()
    }

    public func fitToSize() {
        core.fitToSize()
    }

    func updateMetalLayerMetrics() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = core.scaleFactor()
        // Write to the actually-attached backing layer (not just the
        // cached `metalLayer` ivar). The render pipeline can swap
        // `self.layer` to an IOSurfaceLayer for IOSurface-backed
        // compositing; once that happens the cached CAMetalLayer
        // reference is detached from the view tree and writes to its
        // contentsScale are no-ops as far as what's visible. The
        // observable symptom is text rendered at half size after the
        // window crosses to a display with a different
        // backingScaleFactor.
        layer?.contentsScale = scale
        if let metal = layer as? CAMetalLayer {
            metal.drawableSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
        }
        // Mirror to the cached ivar in case anything else still
        // reads through it during a transitional layout pass.
        metalLayer?.contentsScale = scale
        metalLayer?.drawableSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
    }

    override open func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColorScheme()
    }

    func updateColorScheme() {
        let scheme: TerminalColorScheme = switch effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: .dark
        default: .light
        }
        surface?.setColorScheme(scheme.ghosttyValue)
        if let controller,
           let viewState = delegate as? TerminalViewState,
           viewState.controller === controller
        {
            viewState.adopt(terminalColorScheme: scheme)
        } else {
            controller?.setColorScheme(scheme)
        }
    }
}
