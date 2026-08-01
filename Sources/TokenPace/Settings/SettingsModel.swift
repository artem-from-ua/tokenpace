import Foundation
import Observation
import TokenPaceKit

// MARK: - SettingsModel (#168, ADR-0042)

/// The observable state behind the Settings window. It lives as long as `SettingsWindowController`
/// (created in its `init`, **not** inside any SwiftUI view), so the background poll/archive callbacks
/// (`updateAvailability`/`updateArchiveStatus`) always have somewhere to write even while the window
/// is closed. That is what lets the SwiftUI panes build lazily — the eager-build invariant that the
/// old AppKit design needed (nil outlets on a closed window) is gone: these methods mutate model
/// state, not a view.
///
/// The AppDelegate contract (the 10 callbacks + `archiveSummaryProvider`) actually lives here;
/// `SettingsWindowController` just forwards its same-named properties into this model, so
/// `AppDelegate.openSettings` is unchanged.
///
/// **Ordering invariant:** every setter writes `PersistedConfig` *first*, then fires the callback —
/// exactly as the old `@objc` actions did. Views never bind `PersistedConfig` directly; they call
/// these `set…` methods (via `Binding(get:set:)`), so SwiftUI can't reorder persist vs callback.
/// `syncFromConfig()` reads the store back into the model without going through the setters, so a
/// re-sync never re-persists or re-fires a callback.
@MainActor
@Observable
final class SettingsModel {

    // MARK: Callbacks (the AppDelegate contract — set by the window controller's forwarders)

    var onMonitoredServicesChange: ((MonitoredServices) -> Void)?
    var onCheckForUpdatesNow: (() -> Void)?
    var onCalmColorsChange: ((Bool) -> Void)?
    var onResetCountdownModeMenuBarChange: ((ResetCountdownMode) -> Void)?
    var onServiceDotChange: ((Bool) -> Void)?
    var onExtraUsageChange: ((Bool) -> Void)?
    var onShowModelSpecificLimitsChange: ((Bool) -> Void)?
    var onHideCalmSevenDayChange: ((Bool) -> Void)?
    var onHideBarsWhenBlockedChange: ((Bool) -> Void)?
    var onShowBlockedPauseChange: ((Bool) -> Void)?
    var onPausePollingChange: ((Bool) -> Void)?
    var onArchiveNow: (() -> Void)?
    var onBackToWorkEnabled: ((@escaping @MainActor (BackToWorkNotifier.AuthState) -> Void) -> Void)?
    /// Fire the "Back to work!" notification immediately, bypassing the edge-detection and quiet-hours
    /// gates (those live in `AppDelegate`, not the notifier) — the Settings "Try" button (#193).
    var onTryBackToWork: (() -> Void)?
    /// Fire the "Switching to Extra Usage" notification immediately from its Settings "Try" button —
    /// the shell reads the latest snapshot's spend for the amount/limit body (ADR-0050).
    var onTryExtraUsage: (() -> Void)?
    var archiveSummaryProvider: (() -> LogArchiver.Summary?)?

    // MARK: Selection (dev hook)

    /// The section the root view should show. Seeded once from `TOKENPACE_SETTINGS_SECTION` on `show()`.
    var selection: SettingsSection = .about

    /// Live sidebar icon sizing, keyed off the system "Sidebar icon size" (System Settings). Lives here
    /// so it persists with the window and keeps observing while open.
    let sidebarIcons = SidebarIconMetrics()

    // MARK: General

    private(set) var launchAtLogin = false
    /// Whether the last launch-at-login toggle failed in an `.app` bundle (drives the recovery hint,
    /// #69); reset on a successful toggle or a fresh `show()`.
    private(set) var launchToggleFailed = false
    var pausePolling = false

    // MARK: Appearance (menu-bar widget)

    var calmColors = false
    var hideCalmSevenDay = false
    var hideBarsWhenBlocked = false
    var showBlockedPause = false
    var showExtraUsage = false
    /// Whether the popup lists the per-model 7-day limit rows (Opus/Sonnet/scoped, #211). A popup
    /// concern, not a menu-bar one — shown under the separate "Dropdown" section of the pane.
    var showModelSpecificLimits = false
    var showServiceDot = false
    /// The reset-countdown choice (always / smart / never), shown as a menu picker.
    var resetRadio: ResetRadio = .smart

    // MARK: Monitored Services

    var claudeCodeEnabled = true
    var webDesktopEnabled = true
    var webDesktopMode: WebDesktopMode = .chatOnly

    // MARK: Notifications (#160)

    var backToWorkEnabled = false
    var extraUsageNotifyEnabled = false
    var notifyStartMinute = 0
    var notifyEndMinute = 0
    var suppressDays: SuppressDays = .never
    /// Notification-authorization state, driving the hint row and the master switch's enablement.
    /// Updated asynchronously by `refreshAuthState()` / the `onBackToWorkEnabled` completion.
    private(set) var authState: BackToWorkNotifier.AuthState = .notDetermined

    // MARK: Session Logs (#110)

    var archiveEnabled = false
    private(set) var archiveDestination: String?
    private(set) var archiveStatusText = ""

    // MARK: About / Updates (#37)

    var automaticUpdateChecks = false
    var installAutomatically = false
    private(set) var latestRelease: GitHubRelease?
    /// The most recent failed auto-install (#210) — tag + stage + reason — or `nil`. Read from
    /// `PersistedConfig` in `syncFromConfig()` (so it refreshes each time the window opens); a past
    /// event, so no live update is needed. Drives the ⚠️ "Update … failed" row on the About pane.
    private(set) var lastUpdateFailure: LastUpdateFailure?

    // MARK: Static build facts

    /// A real `.app` bundle (not a `swift run` dev build). Gates launch-at-login, auto-install, and the
    /// "Back to work" master switch (ADR-0012 §4, ADR-0018).
    let inAppBundle = LaunchAtLoginController.isAppBundle
    let versionText = SettingsModel.makeVersionText()

    /// A forced install-failure for live verification of the About pane (#210), from
    /// `TOKENPACE_FAKE_FAILURE=<stage>:<reason>` (e.g. `verify:team id mismatch (expected …)`); the
    /// tag comes from `TOKENPACE_FAKE_LATEST` or a placeholder. A maintainer aid like
    /// `TOKENPACE_UPDATE_STATE` — it never writes UserDefaults; `nil` for a normal run or an
    /// unparsable value (unknown stage / missing reason).
    static let forcedUpdateFailure: LastUpdateFailure? = {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["TOKENPACE_FAKE_FAILURE"], !raw.isEmpty,
              let sep = raw.firstIndex(of: ":") else { return nil }
        let stageRaw = String(raw[raw.startIndex..<sep])
        let reason = String(raw[raw.index(after: sep)...])
        guard let stage = LastUpdateFailure.Stage(rawValue: stageRaw), !reason.isEmpty else { return nil }
        let tag = env["TOKENPACE_FAKE_LATEST"].flatMap { $0.isEmpty ? nil : $0 } ?? "v\(TokenPaceKit.version)"
        return LastUpdateFailure(tag: tag, stage: stage, reason: reason)
    }()

    // MARK: Computed enablement (was the scattered imperative `updateX Availability()` methods)

    var launchToggleEnabled: Bool { inAppBundle }
    /// The hint under the launch-at-login switch, and whether it is the standard dev-build warning
    /// (⚠️ styling, same as auto-install / back-to-work). On a dev build the feature can never work, so
    /// it shows the shared "Unavailable in development builds." line; in a real `.app` it is empty
    /// unless a toggle failed, then a recovery hint (not a dev warning). Empty in the neutral case.
    var launchHint: (text: String, devBuild: Bool) {
        if !inAppBundle {
            return ("Unavailable in development builds.", true)
        }
        if launchToggleFailed {
            return ("Couldn't enable launch at login. Reinstall TokenPace.app in /Applications and "
                  + "open it from Finder/Launchpad, or add it manually in System Settings → General → "
                  + "Login Items.", false)
        }
        return ("", false)
    }

    var webDesktopRadioEnabled: Bool { webDesktopEnabled }

    /// The master "Back to work" switch is disabled on a dev build (authorization is impossible there,
    /// so the feature can never work — like launch-at-login / auto-install).
    var backToWorkMasterEnabled: Bool { authState != .dev }
    var notifyDependentsEnabled: Bool { backToWorkMasterEnabled && backToWorkEnabled }
    /// True on a `swift run` dev build, where no notification can ever be delivered (authorization is
    /// impossible). The Notifications pane surfaces this once as a banner above the whole section — not
    /// per-switch — since it gates every notification alike (both toggles are disabled).
    var notificationsDevBuild: Bool { authState == .dev }
    /// The auth hint under the master switch; empty in the authorized / not-yet-decided case. The
    /// dev-build case is handled by the pane-level banner (`notificationsDevBuild`), not here.
    var backToWorkHint: String {
        switch authState {
        case .denied:
            return "Notifications are turned off for TokenPace. Enable them in System Settings → "
                 + "Notifications → TokenPace."
        case .dev, .authorized, .notDetermined:
            return ""
        }
    }
    /// Live "Nh window" / "Nh Mm window" duration label from the two pickers (handles wrap + whole-day).
    var notifyWindowLengthText: String {
        let minutes = NotificationSchedule.windowLengthMinutes(
            startMinute: notifyStartMinute, endMinute: notifyEndMinute)
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h)h window" : "\(h)h \(m)m window"
    }

    var installAutoEnabled: Bool { automaticUpdateChecks && inAppBundle }
    /// The hint under "Install updates automatically". The row is shown only when periodic checks are
    /// on (the view hides it otherwise), so the only cases here are a dev build (⚠️ — auto-install can
    /// never work) or the enabled description. A non-empty `devBuild` flag drives the ⚠️ styling.
    var installAutoHint: (text: String, devBuild: Bool) {
        if !inAppBundle {
            return ("Unavailable in development builds.", true)
        }
        return ("On by default: downloads and installs a newer release in the background, then "
              + "restarts. If anything fails, the menu shows a \u{201C}New version available\u{201D} "
              + "item linking to the release instead.", false)
    }

    // MARK: Sync from config / system (called by the controller's show())

    /// Re-read every field from `PersistedConfig` / the system into the model — the SwiftUI equivalent
    /// of the old `show()` block of `syncX FromConfig` calls. Goes straight to the stored properties,
    /// bypassing the `set…` methods, so a re-sync never re-persists or re-fires a callback.
    func syncFromConfig() {
        launchToggleFailed = false
        let status = LaunchAtLoginController.currentStatus()
        launchAtLogin = LaunchAtLogin.toggleState(for: status)
        pausePolling = PersistedConfig.pausePollingWhenScreenLocked

        calmColors = PersistedConfig.calmMenuBarColors
        hideCalmSevenDay = PersistedConfig.hideCalmSevenDayBar
        hideBarsWhenBlocked = PersistedConfig.hideBarsWhenBlocked
        showBlockedPause = PersistedConfig.showBlockedPause
        showExtraUsage = PersistedConfig.showExtraUsage
        showModelSpecificLimits = PersistedConfig.showModelSpecificLimits
        showServiceDot = PersistedConfig.showServiceStatusDot
        resetRadio = PersistedConfig.resetCountdownModeMenuBar.radio

        let ms = PersistedConfig.monitoredServices
        claudeCodeEnabled = ms.claudeCodeEnabled
        webDesktopEnabled = ms.webDesktopEnabled
        webDesktopMode = ms.webDesktopMode

        backToWorkEnabled = PersistedConfig.backToWorkEnabled
        extraUsageNotifyEnabled = PersistedConfig.extraUsageNotifyEnabled
        notifyStartMinute = PersistedConfig.notifyWindowStartMinute
        notifyEndMinute = PersistedConfig.notifyWindowEndMinute
        suppressDays = PersistedConfig.notifySuppressDays
        refreshAuthState()

        automaticUpdateChecks = PersistedConfig.automaticUpdateChecks
        installAutomatically = PersistedConfig.installUpdatesAutomatically
        // Real store, unless a verification stub forces a failure (see `forcedUpdateFailure`) — the
        // stub never writes UserDefaults, mirroring `TOKENPACE_UPDATE_STATE`.
        lastUpdateFailure = Self.forcedUpdateFailure ?? PersistedConfig.lastUpdateFailure

        archiveEnabled = PersistedConfig.archiveEnabled
        refreshArchiveStatus()
    }

    // MARK: Setters (persist first, then fire the callback — the ordering invariant)

    func setPausePolling(_ on: Bool) {
        pausePolling = on
        PersistedConfig.pausePollingWhenScreenLocked = on
        AppLogger.lifecycle.notice("screen-lock-pause: setting set \(on, privacy: .public)")
        onPausePollingChange?(on)
    }

    func setCalmColors(_ on: Bool) {
        calmColors = on
        PersistedConfig.calmMenuBarColors = on
        AppLogger.lifecycle.notice("calm-colors: menu-bar set \(on, privacy: .public)")
        onCalmColorsChange?(on)
    }

    func setHideCalmSevenDay(_ on: Bool) {
        hideCalmSevenDay = on
        PersistedConfig.hideCalmSevenDayBar = on
        AppLogger.lifecycle.notice("hide-calm-7d: menu-bar set \(on, privacy: .public)")
        onHideCalmSevenDayChange?(on)
    }

    func setHideBarsWhenBlocked(_ on: Bool) {
        hideBarsWhenBlocked = on
        PersistedConfig.hideBarsWhenBlocked = on
        AppLogger.lifecycle.notice("hide-bars-when-blocked: menu-bar set \(on, privacy: .public)")
        onHideBarsWhenBlockedChange?(on)
    }

    func setShowBlockedPause(_ on: Bool) {
        showBlockedPause = on
        PersistedConfig.showBlockedPause = on
        AppLogger.lifecycle.notice("show-blocked-pause: menu-bar set \(on, privacy: .public)")
        onShowBlockedPauseChange?(on)
    }

    func setShowExtraUsage(_ on: Bool) {
        showExtraUsage = on
        PersistedConfig.showExtraUsage = on
        AppLogger.lifecycle.notice("extra-usage-icon: menu-bar set \(on, privacy: .public)")
        onExtraUsageChange?(on)
    }

    func setShowModelSpecificLimits(_ on: Bool) {
        showModelSpecificLimits = on
        PersistedConfig.showModelSpecificLimits = on
        AppLogger.lifecycle.notice("model-specific-limits: popup set \(on, privacy: .public)")
        onShowModelSpecificLimitsChange?(on)
    }

    func setShowServiceDot(_ on: Bool) {
        showServiceDot = on
        PersistedConfig.showServiceStatusDot = on
        AppLogger.lifecycle.notice("service-status-dot: menu-bar set \(on, privacy: .public)")
        onServiceDotChange?(on)
    }

    /// Map the picker choice to a `ResetCountdownMode`, persist, and fire the callback.
    func commitResetCountdownMode() {
        let mode = ResetCountdownMode.from(radio: resetRadio)
        PersistedConfig.resetCountdownModeMenuBar = mode
        AppLogger.lifecycle.notice("reset-countdown: menu-bar mode set \(mode.rawValue, privacy: .public)")
        onResetCountdownModeMenuBarChange?(mode)
    }

    /// Build `MonitoredServices` from the current toggles/radio, persist, and fire the callback.
    func commitMonitoredServices() {
        let config = MonitoredServices(
            claudeCodeEnabled: claudeCodeEnabled,
            webDesktopEnabled: webDesktopEnabled,
            webDesktopMode: webDesktopMode)
        PersistedConfig.monitoredServices = config
        onMonitoredServicesChange?(config)
    }

    func toggleLaunchAtLogin(_ wantOn: Bool) {
        do {
            if wantOn { try LaunchAtLoginController.enable() }
            else      { try LaunchAtLoginController.disable() }
            launchToggleFailed = false
            AppLogger.lifecycle.notice("launch-at-login: user set \(wantOn, privacy: .public)")
        } catch {
            // Best-effort: remember the failure so the hint explains it (#69). The model prop rolls
            // back below from the re-read system status.
            launchToggleFailed = true
            AppLogger.lifecycle.error(
                "launch-at-login: toggle failed: \(error.localizedDescription, privacy: .public)")
        }
        let status = LaunchAtLoginController.currentStatus()
        if LaunchAtLogin.needsSystemSettings(status) {
            LaunchAtLoginController.openLoginItemsSettings()
        }
        launchAtLogin = LaunchAtLogin.toggleState(for: status)
    }

    func setBackToWork(_ on: Bool) {
        backToWorkEnabled = on
        PersistedConfig.backToWorkEnabled = on
        AppLogger.lifecycle.notice("back-to-work: enabled set \(on, privacy: .public)")
        if on {
            // Lazily request authorization on first enable, then refresh the hint with the result.
            onBackToWorkEnabled?({ [weak self] state in self?.applyAuthState(state) })
        } else {
            refreshAuthState()
        }
    }

    /// Fire the "Back to work!" notification on demand from the Settings "Try" button (#193). Forces a
    /// post through the normal delivery channel, bypassing the edge-detection and quiet-hours gates.
    func tryBackToWork() {
        AppLogger.lifecycle.notice("back-to-work: try (forced) notification")
        onTryBackToWork?()
    }

    /// Fire the "Switching to Extra Usage" notification on demand from its Settings "Try" button.
    /// Forces a post through the normal delivery channel, bypassing edge-detection and quiet hours.
    func tryExtraUsage() {
        AppLogger.lifecycle.notice("extra-usage: try (forced) notification")
        onTryExtraUsage?()
    }

    func setExtraUsageNotify(_ on: Bool) {
        extraUsageNotifyEnabled = on
        PersistedConfig.extraUsageNotifyEnabled = on
        AppLogger.lifecycle.notice("extra-usage: notify enabled set \(on, privacy: .public)")
        if on {
            // Shares one authorization grant with "Back to work" — request lazily on first enable of
            // either feature, then refresh the hint with the result.
            onBackToWorkEnabled?({ [weak self] state in self?.applyAuthState(state) })
        } else {
            refreshAuthState()
        }
    }

    func setNotifyWindow(start: Int, end: Int) {
        notifyStartMinute = start
        notifyEndMinute = end
        PersistedConfig.notifyWindowStartMinute = start
        PersistedConfig.notifyWindowEndMinute = end
        AppLogger.lifecycle.notice(
            "back-to-work: time window set \(start, privacy: .public)–\(end, privacy: .public)")
    }

    func setSuppressDays(_ days: SuppressDays) {
        suppressDays = days
        PersistedConfig.notifySuppressDays = days
        AppLogger.lifecycle.notice("back-to-work: suppress set \(days.rawValue, privacy: .public)")
    }

    func setAutomaticUpdateChecks(_ on: Bool) {
        automaticUpdateChecks = on
        PersistedConfig.automaticUpdateChecks = on
        AppLogger.lifecycle.notice("update: automatic checks set \(on, privacy: .public)")
        // `installAutoEnabled` / `installAutoHint` are computed, so the nested toggle updates itself.
    }

    func setInstallAutomatically(_ on: Bool) {
        installAutomatically = on
        PersistedConfig.installUpdatesAutomatically = on
        AppLogger.lifecycle.notice("update-install: auto set \(on, privacy: .public)")
    }

    func checkForUpdatesNow() { onCheckForUpdatesNow?() }

    func setArchiveEnabled(_ on: Bool) {
        if on, PersistedConfig.archiveDestination == nil {
            // Turning on with no folder yet → prompt. If the user cancels (still no folder), the
            // feature can't do anything, so flip the toggle back off rather than leaving it stuck on.
            chooseArchiveFolder()
            if PersistedConfig.archiveDestination == nil {
                archiveEnabled = false
                PersistedConfig.archiveEnabled = false
                refreshArchiveStatus()
                return
            }
        }
        archiveEnabled = on
        PersistedConfig.archiveEnabled = on
        AppLogger.lifecycle.notice("archive: enabled set \(on, privacy: .public)")
        refreshArchiveStatus()
    }

    /// Present the folder picker (imperative `NSOpenPanel`, invoked from a SwiftUI button action).
    func chooseArchiveFolder() {
        guard let path = FolderPicker.choose(current: PersistedConfig.archiveDestination) else { return }
        PersistedConfig.archiveDestination = path
        AppLogger.lifecycle.notice("archive: destination chosen")
        refreshArchiveStatus()
        // Archive into the newly chosen folder right away, so the status reflects a real sync instead
        // of sitting at "Not archived yet". The sync runs in the shell; its completion refreshes the
        // status (via updateArchiveStatus).
        onArchiveNow?()
    }

    func archiveNow() { onArchiveNow?() }

    func openRepo() { NSWorkspaceOpener.open(SettingsLinks.repoURL) }

    /// A release tag stripped of a leading `v`/`V` for display (`"v0.55.0"` → `"0.55.0"`) — the About
    /// pane shows bare `X.Y.Z` (#210), while URLs still use the real `vX.Y.Z` tag.
    static func displayTag(_ tag: String) -> String {
        guard let first = tag.first, first == "v" || first == "V" else { return tag }
        return String(tag.dropFirst())
    }

    /// Open the release-notes page for a specific tag (#210) — used by the "New version available"
    /// row's "Release notes" link, which carries that release's own tag.
    func openReleaseNotes(tag: String) {
        NSWorkspaceOpener.open(GitHubReleaseClient.releaseNotesURL(tag: tag).absoluteString)
    }

    func openDownload() {
        guard let release = latestRelease else { return }
        NSWorkspaceOpener.open(release.htmlURL)
    }

    // MARK: Background-driven mutators (safe while the window is closed — they touch model state only)

    /// Reflect the current update state (#37): the model exposes `latestRelease`; the About pane shows
    /// "Update available: vX.Y.Z" + Download when non-nil.
    func updateAvailability(_ release: GitHubRelease?) {
        latestRelease = release
    }

    /// Reflect the current archive state (#110): destination + the "Last archived …" status line.
    func refreshArchiveStatus() {
        archiveDestination = PersistedConfig.archiveDestination
        archiveStatusText = Self.composeArchiveStatus(
            destination: PersistedConfig.archiveDestination,
            lastSync: PersistedConfig.lastArchiveSync,
            summary: archiveSummaryProvider?())
    }

    // MARK: Auth-state plumbing

    private func refreshAuthState() {
        BackToWorkNotifier.currentAuthState { [weak self] state in self?.applyAuthState(state) }
    }

    private func applyAuthState(_ state: BackToWorkNotifier.AuthState) {
        authState = state
        // On a dev build authorization is impossible, so the master switch is disabled and both
        // notification toggles are forced off (the computed `backToWorkMasterEnabled` disables them;
        // force the stored values + store to off).
        if state == .dev {
            if backToWorkEnabled {
                backToWorkEnabled = false
                PersistedConfig.backToWorkEnabled = false
            }
            if extraUsageNotifyEnabled {
                extraUsageNotifyEnabled = false
                PersistedConfig.extraUsageNotifyEnabled = false
            }
        }
    }
}
