//
//  TerminalController.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

import AppKit
import os

/// Manages the Ghostty app lifecycle, configuration loading, and surface
/// creation.
///
/// `TerminalController` is the **single source of truth** for terminal
/// configuration, including the base config, per-session overrides, theme
/// colors, and the active color scheme. When any of these change the
/// controller re-resolves the effective config and pushes it to ghostty.
@MainActor
public final class TerminalController {
    struct PreparedConfig {
        let rawValue: ghostty_config_t
        let managedConfigURL: URL?
        let renderedContents: String
    }

    struct ConfigurationIssue: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    public enum ConfigSource: Sendable, Hashable {
        case none
        case file(String)
        case generated(String)
    }

    public static let shared = TerminalController()

    static let defaultRenderedConfig = TerminalConfiguration.default.rendered
    private static var runtimeInitialized = false

    nonisolated(unsafe) var app: ghostty_app_t?
    nonisolated(unsafe) var config: ghostty_config_t?
    var retainedBridges: [TerminalCallbackBridge] = []
    var configSource: ConfigSource
    var managedConfigURL: URL?
    var renderedConfigContents: String = TerminalController.defaultRenderedConfig

    public internal(set) var lastConfigurationIssue: String?
    /// True while a wakeup has queued an app tick that has not started yet.
    /// Ghostty calls the wakeup callback from its own threads, at a rate
    /// that follows terminal output. This flag keeps at most one tick on the
    /// main queue, so a burst of wakeups cannot flood it.
    private nonisolated let tickQueued = OSAllocatedUnfairLock(initialState: false)

    /// Tokens for the app activation observers that feed `ghostty_app_set_focus`.
    private nonisolated(unsafe) var activationObservers: [any NSObjectProtocol] = []

    // MARK: - Config Resolution State

    /// The base config before theme/colorScheme are applied: what actually
    /// loaded, so `.none` after init fell back from a rejected file.
    var baseConfigSource: ConfigSource = .none
    var baseConfigTemplate: String = ""

    /// Per-session configuration overrides (e.g. font size changes).
    public private(set) var terminalConfiguration: TerminalConfiguration

    /// Color theme (light + dark variants).
    public private(set) var theme: TerminalTheme

    /// The currently active color scheme.
    public private(set) var effectiveColorScheme: TerminalColorScheme = .light

    // MARK: - Public Accessors

    public var currentConfigSource: ConfigSource {
        configSource
    }

    public var renderedConfig: String {
        renderedConfigContents
    }

    // MARK: - Initializers

    /// Creates a controller with the default terminal configuration.
    public convenience init() {
        self.init(configuration: .default)
    }

    /// Creates a controller with a fully custom configuration.
    public convenience init(
        configuration: TerminalConfiguration,
        theme: TerminalTheme = .default
    ) {
        self.init(
            configSource: .generated(configuration.rendered),
            theme: theme
        )
    }

    /// Creates a controller by composing additional commands on top of
    /// the default configuration.
    ///
    ///     TerminalController {
    ///         $0.withBackgroundOpacity(0)
    ///         $0.withCustom("keybind", "super+k=text:\\x0c")
    ///     }
    public convenience init(
        theme: TerminalTheme = .default,
        configure: (inout TerminalConfiguration.Builder) -> Void
    ) {
        self.init(
            configuration: TerminalConfiguration(
                startingFrom: .default,
                configure: configure
            ),
            theme: theme
        )
    }

    /// Creates a controller that loads its configuration from a file.
    public convenience init(
        configFilePath: String?,
        theme: TerminalTheme = .default
    ) {
        guard let configFilePath else {
            self.init(configSource: .none, theme: theme)
            return
        }
        self.init(configSource: .file(configFilePath), theme: theme)
    }

    /// Low-level initialiser for full control over the config source.
    public init(
        configSource: ConfigSource = .none,
        theme: TerminalTheme = .default,
        terminalConfiguration: TerminalConfiguration = .init()
    ) {
        Self.initializeRuntimeIfNeeded()

        self.theme = theme
        self.terminalConfiguration = terminalConfiguration
        self.configSource = configSource

        // Load the base config (without theme) so ghostty validates it.
        applyInitialConfig(source: configSource)
        baseConfigSource = self.configSource
        baseConfigTemplate = renderedConfigContents
        let baseIssue = lastConfigurationIssue

        // Now apply theme on top and push to ghostty.
        reconfigure()
        // The theme pass loading does not make a rejected base config
        // load; the fallback is what a host reads here after init.
        if let baseIssue { lastConfigurationIssue = baseIssue }
        createApp()
        observeAppActivation()
    }

    // MARK: - Color Scheme

    /// Updates the active color scheme and reconfigures the terminal.
    ///
    /// Called by platform views when the OS appearance changes. This is
    /// the only method views need to call — the controller handles all
    /// config resolution internally.
    public func setColorScheme(_ scheme: TerminalColorScheme) {
        setColorScheme(scheme, willChange: nil)
    }

    @discardableResult
    func setColorScheme(
        _ scheme: TerminalColorScheme,
        willChange: (() -> Void)?
    ) -> Bool {
        let previous = effectiveColorScheme
        guard scheme != previous else {
            if let app {
                ghostty_app_set_color_scheme(app, scheme.ghosttyValue)
            }
            return false
        }

        let resolved = resolveEffectiveConfig(colorScheme: scheme)
        guard applyResolvedConfig(
            resolved,
            willChange: willChange,
            applyState: { effectiveColorScheme = scheme }
        ) else {
            return false
        }

        if let app {
            ghostty_app_set_color_scheme(app, scheme.ghosttyValue)
        }

        return true
    }

    // MARK: - Theme

    /// Updates the theme and reconfigures the terminal.
    @discardableResult
    public func setTheme(_ theme: TerminalTheme) -> Bool {
        setTheme(theme, willChange: nil)
    }

    @discardableResult
    func setTheme(
        _ theme: TerminalTheme,
        willChange: (() -> Void)?
    ) -> Bool {
        guard theme != self.theme else { return false }
        let resolved = resolveEffectiveConfig(theme: theme)
        return applyResolvedConfig(
            resolved,
            willChange: willChange,
            applyState: { self.theme = theme }
        )
    }

    // MARK: - Terminal Configuration

    /// Updates per-session configuration overrides and reconfigures.
    @discardableResult
    public func setTerminalConfiguration(
        _ terminalConfiguration: TerminalConfiguration
    ) -> Bool {
        setTerminalConfiguration(terminalConfiguration, willChange: nil)
    }

    @discardableResult
    func setTerminalConfiguration(
        _ terminalConfiguration: TerminalConfiguration,
        willChange: (() -> Void)?
    ) -> Bool {
        guard terminalConfiguration != self.terminalConfiguration else { return false }
        let resolved = resolveEffectiveConfig(terminalConfiguration: terminalConfiguration)
        return applyResolvedConfig(
            resolved,
            willChange: willChange,
            applyState: { self.terminalConfiguration = terminalConfiguration }
        )
    }

    // MARK: - Config Resolution

    @discardableResult
    func reconfigure() -> Bool {
        applyResolvedConfig(resolveEffectiveConfig(), willChange: nil)
    }

    private func resolveEffectiveConfig() -> (
        source: ConfigSource, contents: String
    ) {
        resolveEffectiveConfig(
            theme: theme,
            terminalConfiguration: terminalConfiguration,
            colorScheme: effectiveColorScheme
        )
    }

    private func resolveEffectiveConfig(
        theme: TerminalTheme? = nil,
        terminalConfiguration: TerminalConfiguration? = nil,
        colorScheme: TerminalColorScheme? = nil
    ) -> (source: ConfigSource, contents: String) {
        let nextTheme = theme ?? self.theme
        let nextTerminalConfiguration = terminalConfiguration ?? self.terminalConfiguration
        let nextColorScheme = colorScheme ?? effectiveColorScheme
        let themeConfig = nextTheme.configuration(for: nextColorScheme)
        if nextTerminalConfiguration.isEmpty, themeConfig.isEmpty {
            return (baseConfigSource, baseConfigTemplate)
        }

        let contents = GhosttyConfigRenderer.render(
            baseContents: baseConfigTemplate,
            configuration: nextTerminalConfiguration,
            theme: themeConfig
        )
        return (.generated(contents), contents)
    }

    // MARK: - Tick

    public func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Called from Ghostty's wakeup callback, on any thread. Queues one
    /// `ghostty_app_tick` on the main queue unless one is already queued.
    ///
    /// Ticks run regardless of surface visibility or app activation. The app
    /// mailbox (titles, pwd, bell, child exit) only empties in a tick, and a
    /// full mailbox blocks the session's write thread. Ghostty's renderer
    /// threads pace and draw frames on their own, so a tick draws nothing.
    nonisolated func scheduleTick() {
        let alreadyQueued = tickQueued.withLock { queued in
            let was = queued
            queued = true
            return was
        }
        guard !alreadyQueued else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { [self] in
                // Clear before ticking. A wakeup that arrives during the
                // tick queues another one instead of being dropped.
                tickQueued.withLock { $0 = false }
                tick()
            }
        }
    }

    /// Tells Ghostty whether the app is active, as Ghostty's own macOS app does.
    func observeAppActivation() {
        ghostty_app_set_focus(app, NSApplication.shared.isActive)
        let center = NotificationCenter.default
        for (name, active) in [
            (NSApplication.didBecomeActiveNotification, true),
            (NSApplication.didResignActiveNotification, false),
        ] {
            activationObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let app = self?.app else { return }
                        ghostty_app_set_focus(app, active)
                    }
                }
            )
        }
    }

    private static func initializeRuntimeIfNeeded() {
        guard !runtimeInitialized else { return }
        runtimeInitialized = true
        GhosttyRuntimeResources.configureEnvironment()
        ghostty_init(0, nil)
    }

    deinit {
        for observer in activationObservers { NotificationCenter.default.removeObserver(observer) }
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
        if let managedConfigURL {
            try? FileManager.default.removeItem(at: managedConfigURL)
        }
    }
}
