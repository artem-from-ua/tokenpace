import AppKit
import SwiftUI
import TokenPaceKit

// MARK: - SettingsWindowController

/// The "Settings…" window (#14, redesigned #131, rewritten on SwiftUI #168 / ADR-0042): a macOS
/// System Settings-style window reached from the popup menu — a sidebar of sections on the left, a
/// detail pane of grouped `Form` cards on the right, hosted in an `NSWindow` via `NSHostingController`.
///
/// The controller is a thin hosting wrapper. All state and behaviour live in `SettingsModel`
/// (`@Observable`), which the SwiftUI tree binds to. The controller keeps the exact public contract
/// the `AppDelegate` wires (`AppDelegate.openSettings`): the ten `on…Change`/provider callbacks plus
/// `updateAvailability(_:)` and `updateArchiveStatus()`. Those properties forward straight into the
/// model, so `App.swift` is unchanged.
///
/// Because the model is created in `init` and lives as long as the controller, the background poll
/// completions (`updateAvailability`/`updateArchiveStatus`, fired while the window is closed) mutate
/// model state rather than a view outlet — so the panes can build lazily and the old eager-build
/// invariant is gone (ADR-0042).
///
/// Opened from an accessory (menu-bar) app, so it uses `NSApp.activate` + a floating window level to
/// come to the front (ADR-0012 §6), rather than switching activation policy to `.regular`.
@MainActor
final class SettingsWindowController: NSWindowController {

    private enum Metrics {
        /// Fixed window content width, matching System Settings exactly (measured 857 pt, #156). The
        /// window never resizes; the sidebar/detail split moves inside it (sidebar 258, detail 599).
        static let contentWidth: CGFloat = 857
        /// Fixed window content height. Bumped 480 → 520 (#199) so the taller Appearance pane (extra
        /// menu-bar toggle) and the other panes breathe without inner scrolling.
        static let contentHeight: CGFloat = 520
    }

    /// The single observable state object, alive for the controller's lifetime (so background
    /// callbacks always have somewhere to write — see the type doc).
    private let model = SettingsModel()

    // MARK: Public callbacks (the AppDelegate contract — forwarded into the model, unchanged surface)

    /// Called when the user changes the monitored-services selection (#89), with the new config.
    var onMonitoredServicesChange: ((MonitoredServices) -> Void)? {
        get { model.onMonitoredServicesChange } set { model.onMonitoredServicesChange = newValue }
    }

    /// Called when the user clicks "Check now" (#37) — runs an immediate update check.
    var onCheckForUpdatesNow: (() -> Void)? {
        get { model.onCheckForUpdatesNow } set { model.onCheckForUpdatesNow = newValue }
    }

    /// Called when the user toggles "Calm MenuBar Widget colors" (#105), with the new state.
    var onCalmColorsChange: ((Bool) -> Void)? {
        get { model.onCalmColorsChange } set { model.onCalmColorsChange = newValue }
    }

    /// Called when the user changes the menu-bar "Reset countdown" mode (#103), with the new mode.
    var onResetCountdownModeMenuBarChange: ((ResetCountdownMode) -> Void)? {
        get { model.onResetCountdownModeMenuBarChange } set { model.onResetCountdownModeMenuBarChange = newValue }
    }

    /// Called when the user toggles "Show service status dot on issues" (#31), with the new state.
    var onServiceDotChange: ((Bool) -> Void)? {
        get { model.onServiceDotChange } set { model.onServiceDotChange = newValue }
    }

    /// Called when the user toggles "Show extra-usage credits icon" (#146), with the new state.
    var onExtraUsageChange: ((Bool) -> Void)? {
        get { model.onExtraUsageChange } set { model.onExtraUsageChange = newValue }
    }

    /// Called when the user toggles "Hide 7-day bar when calm" (#94), with the new state.
    var onHideCalmSevenDayChange: ((Bool) -> Void)? {
        get { model.onHideCalmSevenDayChange } set { model.onHideCalmSevenDayChange = newValue }
    }

    /// Called when the user toggles "Show pacing bars when 5h/7d limits reached" (#194), with the new
    /// state (stored inverted as `hideBarsWhenBlocked`).
    var onHideBarsWhenBlockedChange: ((Bool) -> Void)? {
        get { model.onHideBarsWhenBlockedChange } set { model.onHideBarsWhenBlockedChange = newValue }
    }

    /// Called when the user toggles "Show pause icon when fully blocked" (#199), with the new state.
    var onShowBlockedPauseChange: ((Bool) -> Void)? {
        get { model.onShowBlockedPauseChange } set { model.onShowBlockedPauseChange = newValue }
    }

    /// Called when the user toggles "Pause polling while the screen is locked" (#114).
    var onPausePollingChange: ((Bool) -> Void)? {
        get { model.onPausePollingChange } set { model.onPausePollingChange = newValue }
    }

    /// Called when the user clicks "Archive now" (#110).
    var onArchiveNow: (() -> Void)? {
        get { model.onArchiveNow } set { model.onArchiveNow = newValue }
    }

    /// Called when the user turns the "Back to work" notification on (#160) — lazily requests
    /// notification authorization; the completion reports the resolved state so the pane refreshes.
    var onBackToWorkEnabled: ((@escaping @MainActor (BackToWorkNotifier.AuthState) -> Void) -> Void)? {
        get { model.onBackToWorkEnabled } set { model.onBackToWorkEnabled = newValue }
    }

    /// Fires the "Back to work!" notification on demand from the Settings "Try" button (#193).
    var onTryBackToWork: (() -> Void)? {
        get { model.onTryBackToWork } set { model.onTryBackToWork = newValue }
    }

    /// Fires the "Switching to Extra Usage" notification on demand from its Settings "Try" button.
    var onTryExtraUsage: (() -> Void)? {
        get { model.onTryExtraUsage } set { model.onTryExtraUsage = newValue }
    }

    /// Provides the last archive summary for the status line (#110).
    var archiveSummaryProvider: (() -> LogArchiver.Summary?)? {
        get { model.archiveSummaryProvider } set { model.archiveSummaryProvider = newValue }
    }

    /// Whether the window has been positioned yet — so the first `show()` of a session centres it, and
    /// later shows leave the user's position alone (#131).
    private var hasBeenPositioned = false

    convenience init() {
        // A settings window is fixed-size, not user-resizable: HIG says it "accommodates the size of
        // the current pane," so minimize/maximize are dimmed (#156). Dropping `.resizable`/
        // `.miniaturizable` from the style mask stops resizing; the still-drawn zoom/minimize buttons
        // are also hidden below, leaving only close.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.contentWidth, height: Metrics.contentHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "TokenPace Settings"
        window.level = .floating               // float above other apps from a menu-bar app (ADR-0012 §6)
        window.isReleasedWhenClosed = false    // keep the controller alive so re-opening reuses it
        // No `setFrameAutosaveName`: the window opens centred every launch rather than restoring a saved
        // frame. A restored frame can outlive its display layout (disconnected monitor, changed
        // resolution/scale) and reopen off-screen; centring is always on-screen (see `show()`).
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        // Fixed content size (857×520), like System Settings — a non-resizable single-pane form. Pin
        // min == max so the window never resizes by pane or by the hosting view's ideal size, and the
        // sidebar/detail split moves inside it.
        window.contentMinSize = NSSize(width: Metrics.contentWidth, height: Metrics.contentHeight)
        window.contentMaxSize = NSSize(width: Metrics.contentWidth, height: Metrics.contentHeight)
        self.init(window: window)
        let hosting = NSHostingController(rootView: SettingsRootView(model: model))
        // Don't let the hosting controller drive the window size from SwiftUI's ideal — the window is
        // fixed (above), and a NavigationSplitView's ideal would otherwise collapse it to a sliver.
        hosting.sizingOptions = []
        window.contentViewController = hosting
    }

    /// Show or re-focus the window. Re-syncs every field from `PersistedConfig`/the system into the
    /// model, brings the app forward, and centres it on the first display of a session. Calling this
    /// while the window is already on screen just focuses it.
    func show() {
        model.syncFromConfig()
        // Reflect the latest known update state whenever the window opens (#37) is already carried by
        // `updateAvailability`, called by `AppDelegate.openSettings` before `show()`.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        // Fix the content size to the full 857×520 *before* centring. The `NSHostingController` content
        // has no intrinsic size, so at first show the window is still a zero-width title-bar sliver;
        // centring it while zero-width lands the left edge near the screen centre, and growing to 857
        // afterwards pushes the right half off-screen. Sizing first makes `center()` centre correctly.
        window?.setContentSize(NSSize(width: Metrics.contentWidth, height: Metrics.contentHeight))
        // Always open centred on the first show of a session (later shows leave the user's position
        // alone, #131). We deliberately don't persist/restore the frame across launches: a saved
        // position can outlive the display layout it was valid for (a monitor was disconnected, the
        // resolution or scale changed) and reopen the window off-screen. Centring is always on-screen
        // and needs no per-launch validation.
        if !hasBeenPositioned {
            hasBeenPositioned = true
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
        // Dev helper: `TOKENPACE_SETTINGS_SECTION=<index>` opens straight to a given pane (0-based).
        if let raw = ProcessInfo.processInfo.environment["TOKENPACE_SETTINGS_SECTION"],
           let idx = Int(raw), let section = SettingsSection(rawValue: idx) {
            model.selection = section
        }
    }

    /// Reflect the current update state (#37). Safe to call while the window is closed — it mutates
    /// model state, which lives independent of any view (ADR-0042).
    func updateAvailability(_ release: GitHubRelease?) {
        model.updateAvailability(release)
    }

    /// Reflect the current archive state (#110). Safe to call while the window is closed.
    func updateArchiveStatus() {
        model.refreshArchiveStatus()
    }
}
