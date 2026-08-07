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
    var onInstallUpdateNow: (() -> Void)?
    var onCalmColorModeChange: ((CalmColorMode) -> Void)?
    var onResetCountdownModeMenuBarChange: ((ResetCountdownMode) -> Void)?
    var onBarStyleChange: ((BarStyle) -> Void)?
    var onShowTicksChange: ((Bool) -> Void)?
    var onFarBehindIntervalChange: ((FarBehindInterval) -> Void)?
    var onServiceDotChange: ((Bool) -> Void)?
    var onExtraUsageChange: ((Bool) -> Void)?
    var onModelLimitsVisibilityChange: ((PopupSectionVisibility) -> Void)?
    var onExtraUsageVisibilityChange: ((PopupSectionVisibility) -> Void)?
    var onHideCalmSevenDayChange: ((Bool) -> Void)?
    var onPauseHidesBarsChange: ((Bool) -> Void)?
    var onPausePollingChange: ((Bool) -> Void)?
    /// Master toggle for the awaiting-input indicator flipped (#233) — the shell starts/stops the
    /// `AwaitingInputWatcher` and re-renders.
    var onAwaitingInputEnabledChange: ((Bool) -> Void)?
    /// An awaiting-input **appearance** option changed (e.g. left-of-pause placement, #233) — the
    /// shell just re-renders from the last snapshot; no watcher restart needed.
    var onAwaitingInputAppearanceChange: (() -> Void)?
    var onArchiveNow: (() -> Void)?
    var onBackToWorkEnabled: ((@escaping @MainActor (BackToWorkNotifier.AuthState) -> Void) -> Void)?
    /// Fire the "Back to work!" notification immediately, bypassing the edge-detection and quiet-hours
    /// gates (those live in `AppDelegate`, not the notifier) — the Settings "Try" button (#193).
    var onTryBackToWork: (() -> Void)?
    /// Fire the "Switching to Extra Usage" notification immediately from its Settings "Try" button —
    /// the shell reads the latest snapshot's spend for the amount/limit body (ADR-0050).
    var onTryExtraUsage: (() -> Void)?
    /// Fire one of every incident banner on demand, for the "Preview" button beside the incident
    /// hint (#279).
    var onPreviewIncidents: (() -> Void)?
    var archiveSummaryProvider: (() -> LogArchiver.Summary?)?

    // MARK: Selection (dev hook)

    /// The section the root view should show. Seeded once from `TOKENPACE_SETTINGS_SECTION` on `show()`.
    var selection: SettingsSection = .about

    /// Whether a data stub (`TOKENPACE_STUB`, or the dev-tools selector) is driving the app rather than
    /// the real network. Owned by the shell, which pushes the live value on every `openSettings` and
    /// again whenever the dev-tools selector switches scenarios (#187) — it can't be derived from
    /// `ProcessInfo` here, since the launch env goes stale the moment the selector is used.
    ///
    /// Drives the ⚠️ "Stubbed in this development build." hints: under a stub the service statuses are
    /// canned rather than fetched, and the awaiting-input watcher doesn't run at all. The toggles stay
    /// enabled — the stored preferences still apply to the next real run.
    var stubScenarioActive = false

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

    var calmColorMode: CalmColorMode = .yellowGreenBlue
    var hideCalmSevenDay = false
    var pauseHidesBars = false
    var showExtraUsage = false
    /// When the popup lists the per-model 7-day limit rows (Opus/Sonnet/scoped, #211). A popup
    /// concern, not a menu-bar one — shown under the separate "Dropdown Widget" section of the pane.
    var modelLimitsVisibility: PopupSectionVisibility = .nonCalm
    /// When the popup shows the "Extra usage" credits section. Separate from ``showExtraUsage``, which
    /// governs the menu-bar credits icon.
    var extraUsageVisibility: PopupSectionVisibility = .nonCalm
    var showServiceDot = false
    /// The reset-countdown choice (always / smart / never), shown as a menu picker.
    var resetRadio: ResetRadio = .smart
    /// The bar presentation style (pacing / simple), shown as a segmented control (#224). Governs
    /// both the menu-bar widget and the dropdown popup.
    var barStyle: BarStyle = .progress
    /// Whether the popup draws the under-bar tick ruler on the pacing bars (#224). A popup concern,
    /// shown under the "Dropdown Widget" section.
    var showTicks = false
    /// The far-behind (green→blue) threshold interval (#224), shown as a menu picker.
    var farBehindInterval: FarBehindInterval = .medium

    // MARK: Monitored Services

    var claudeCodeEnabled = true
    var webDesktopEnabled = true
    var webDesktopMode: WebDesktopMode = .chatOnly

    // MARK: Notifications (#160)

    var backToWorkEnabled = false
    var extraUsageNotifyEnabled = false
    /// Hide incidents older than this many hours in the popup; `0` = no limit (#279).
    var incidentMaxAgeHours = 0
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

    /// Whether the last archive run refused for lack of free space (#306), pushed by the shell after
    /// each run. Seeded from the stub so a forced verification state survives the first push.
    private(set) var archiveSpaceBlock: ArchiveSpaceVerdict =
        SettingsModel.forcedArchiveGate?.space ?? .proceed

    // MARK: Insights — usage journal (#242)

    /// Whether the usage journal records each poll to an append-only JSONL file. Default-off (opt-in).
    var journalEnabled = false

    // MARK: Awaiting-input indicator (#233, ADR-0066)

    /// Master toggle: show the "N sessions awaiting input" indicator. Default-off. Placement is
    /// configured separately in Appearance and only matters while this is on.
    var awaitingInputEnabled = false
    /// Appearance option: also show the indicator in the menu bar (first leading element, bare icon,
    /// no count), in addition to the popup. Default-off. Only meaningful while ``awaitingInputEnabled``
    /// is on.
    var awaitingInputInMenuBar = false

    // MARK: About / Updates (#37)

    var automaticUpdateChecks = false
    var installAutomatically = false
    private(set) var latestRelease: GitHubRelease?
    /// The most recent failed auto-install (#210) — tag + stage + reason — or `nil`. Read from
    /// `PersistedConfig` in `syncFromConfig()` (so it refreshes each time the window opens); a past
    /// event, so no live update is needed. Drives the ⚠️ "Update … failed" row on the About pane.
    private(set) var lastUpdateFailure: LastUpdateFailure?
    /// Every environment condition currently holding back an available update (#221), or `[]` when
    /// nothing blocks. Pushed in by the AppDelegate on each install evaluation, so it tracks the live
    /// state rather than a snapshot taken when the window opened. Drives the ⚠️ "Update pending
    /// because …" row on the About pane.
    private(set) var deferralReasons: [UpdateDeferralReason] = SettingsModel.forcedDeferralReasons ?? []

    // MARK: Static build facts

    /// A real `.app` bundle (not a `swift run` dev build). Gates launch-at-login, auto-install, and the
    /// "Back to work" master switch (ADR-0012 §4, ADR-0018).
    let inAppBundle = LaunchAtLoginController.isAppBundle
    let versionText = SettingsModel.makeVersionText()
    /// The GitHub release tag of the **installed** version (`vX.Y.Z`) — used by the About pane's
    /// "release notes" link beside the version (#224). Shown only in a real `.app` bundle (`inAppBundle`);
    /// a dev build has no published release to point at.
    let currentVersionTag = "v\(TokenPaceKit.version)"

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

    /// Forced deferral reasons for live verification of the About pane (#221), from
    /// `TOKENPACE_FAKE_DEFERRAL=battery,metered,space` (any subset, in any order — the row renders
    /// them in `allCases` order regardless). Like `TOKENPACE_FAKE_FAILURE` it never writes
    /// UserDefaults, and it exists because the real reasons need a `.app` bundle plus an actual
    /// unplugged/metered/full-disk Mac to reproduce. `nil` for a normal run; unknown tokens are ignored.
    static let forcedDeferralReasons: [UpdateDeferralReason]? = {
        guard let raw = ProcessInfo.processInfo.environment["TOKENPACE_FAKE_DEFERRAL"], !raw.isEmpty
        else { return nil }
        let tokens = Set(raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        })
        let reasons = UpdateDeferralReason.allCases.filter { reason in
            switch reason {
            case .onBattery:         return tokens.contains("battery")
            case .meteredNetwork:    return tokens.contains("metered")
            case .insufficientSpace: return tokens.contains("space")
            }
        }
        return reasons.isEmpty ? nil : reasons
    }()

    /// Forced archive gates for live verification of the Sessions-backup hints (#306), from
    /// `TOKENPACE_FAKE_ARCHIVE_GATE=battery,space` (either, both, in any order). Like
    /// `TOKENPACE_FAKE_DEFERRAL` it never writes UserDefaults, and it exists because the real gates
    /// need an unplugged laptop and a genuinely full destination volume to reproduce. `nil` for a
    /// normal run; unknown tokens are ignored.
    ///
    /// It forces only the **display**: the poll still runs and "Archive Now" still archives, matching
    /// `TOKENPACE_FAKE_DEFERRAL` (which doesn't block a real install either). A stub that also broke
    /// the feature would make the button untestable in the same run.
    static let forcedArchiveGate: (battery: Bool, space: ArchiveSpaceVerdict)? = {
        guard let raw = ProcessInfo.processInfo.environment["TOKENPACE_FAKE_ARCHIVE_GATE"], !raw.isEmpty
        else { return nil }
        let tokens = Set(raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        })
        // Plausible figures, so the forced state reads like a real one in the log line beside it.
        let space: ArchiveSpaceVerdict = tokens.contains("space")
            ? .blockedInsufficientSpace(needBytes: 12_000_000_000, freeBytes: 3_000_000_000)
            : .proceed
        let battery = tokens.contains("battery")
        guard battery || space != .proceed else { return nil }
        return (battery, space)
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

    /// The live Appearance config assembled from the model's own (observable) fields — the model-side
    /// mirror of `PersistedConfig.currentAppearanceValues`. Reads the stored fields rather than
    /// `PersistedConfig` so it stays reactive under `@Observable`: any toggle/picker change invalidates
    /// it and re-lights the preset control. The two `hide…` fields are in the same *hide* form as
    /// `AppearancePresetValues` (see `syncFromConfig`).
    private var liveAppearanceValues: AppearancePresetValues {
        AppearancePresetValues(
            calmColorMode: calmColorMode,
            hideCalmSevenDayBar: hideCalmSevenDay,
            pauseHidesBars: pauseHidesBars,
            showExtraUsage: showExtraUsage,
            showServiceStatusDot: showServiceDot,
            awaitingInputInMenuBar: awaitingInputInMenuBar,
            modelLimitsVisibility: modelLimitsVisibility,
            extraUsageVisibility: extraUsageVisibility,
            resetCountdownModeMenuBar: ResetCountdownMode.from(radio: resetRadio),
            barStyle: barStyle,
            showTicks: showTicks,
            farBehindInterval: farBehindInterval)
    }

    /// Which preset the live config matches, or `nil` for the "Custom" state (#215, #224). Drives the
    /// Appearance preset segmented control's active segment: after any manual change the config drifts
    /// off every preset and this becomes `nil`, so the control honestly shows "Custom". Reactive because
    /// it reads the observable fields via `liveAppearanceValues`.
    var activePreset: AppearancePreset? { AppearancePreset.matching(liveAppearanceValues) }

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

    /// The ⚠️ line explaining why an available update hasn't installed (#221), or `nil` when nothing
    /// blocks it. Wording comes from the kit so it stays testable; the view supplies the icon and dot.
    var deferralExplanation: String? {
        UpdateDeferralReason.pendingExplanation(for: deferralReasons)
    }

    /// The ⚠️ line explaining a backup blocked for lack of disk space (#306), or `""` when nothing
    /// blocks it — the empty-string idiom, so `SettingsHint` renders nothing at all.
    var archiveSpaceHint: String {
        ArchiveSpacePlan.blockedExplanation(for: archiveSpaceBlock) ?? ""
    }

    /// Whether the daily backup is currently held back by the battery gate (#306).
    ///
    /// Read live rather than pushed: that gate lives in `pollArchiveIfDue` and returns before the
    /// archiver runs, so there is no outcome that could carry it back. `@Observable` will not
    /// re-render when the power state changes, and that is accepted — the line refreshes on the next
    /// `refreshArchiveStatus()` (window open, toggle, finished sync). **Don't** "fix" this with an
    /// IOKit notification observer: a neutral hint lagging a few seconds is not worth a new
    /// subscription lifecycle in this model.
    var archiveOnBattery: Bool {
        if let forced = SettingsModel.forcedArchiveGate { return forced.battery }
        return archiveEnabled && archiveDestination != nil && !PowerSource.isOnACPower
    }

    /// The neutral (no ⚠️) line explaining a battery-deferred backup, or `""`.
    ///
    /// Suppressed while a space block is showing. Unlike `UpdateDeferralReason.pendingExplanation`,
    /// which joins every clause because all of them must be cleared, these two are not peers: a full
    /// disk is a hard stop and the battery is a soft one, so showing both would imply that plugging in
    /// helps — which it does not.
    var archiveBatteryHint: String {
        guard archiveSpaceHint.isEmpty, archiveOnBattery else { return "" }
        return "Backup will resume when you plug in."
    }

    /// Whether "Update Now" can do anything — a known release, and a real `.app` to replace. The
    /// power/metered gates are deliberately **not** consulted: bypassing them is the button's whole
    /// purpose. A disk too full still lets the user click; the install then declines and logs why,
    /// which beats an unexplained dead button.
    var canInstallNow: Bool {
        // Under `TOKENPACE_FAKE_DEFERRAL` show the button regardless of the build: the whole point of
        // that stub is to review this row on a dev build, and the real bundle check would hide the
        // very control being verified. Clicking it there still declines (`skipNotAppBundle`) and logs.
        if SettingsModel.forcedDeferralReasons != nil { return true }
        guard inAppBundle, let release = latestRelease else { return false }
        return UpdateAssetSelector.selectZIP(from: release) != nil
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

        calmColorMode = PersistedConfig.calmColorMode
        hideCalmSevenDay = PersistedConfig.hideCalmSevenDayBar
        pauseHidesBars = PersistedConfig.pauseHidesBars
        showExtraUsage = PersistedConfig.showExtraUsage
        modelLimitsVisibility = PersistedConfig.modelLimitsVisibility
        extraUsageVisibility = PersistedConfig.extraUsageVisibility
        showServiceDot = PersistedConfig.showServiceStatusDot
        resetRadio = PersistedConfig.resetCountdownModeMenuBar.radio
        barStyle = PersistedConfig.barStyle
        showTicks = PersistedConfig.showTicks
        farBehindInterval = PersistedConfig.farBehindInterval

        let ms = PersistedConfig.monitoredServices
        claudeCodeEnabled = ms.claudeCodeEnabled
        webDesktopEnabled = ms.webDesktopEnabled
        webDesktopMode = ms.webDesktopMode

        backToWorkEnabled = PersistedConfig.backToWorkEnabled
        extraUsageNotifyEnabled = PersistedConfig.extraUsageNotifyEnabled
        incidentMaxAgeHours = PersistedConfig.incidentMaxAge.map { Int(($0 / 3600).rounded()) } ?? 0
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

        awaitingInputEnabled = PersistedConfig.awaitingInputEnabled
        awaitingInputInMenuBar = PersistedConfig.awaitingInputInMenuBar

        journalEnabled = PersistedConfig.journalEnabled
    }

    // MARK: Setters (persist first, then fire the callback — the ordering invariant)

    func setPausePolling(_ on: Bool) {
        pausePolling = on
        PersistedConfig.pausePollingWhenScreenLocked = on
        AppLogger.lifecycle.notice("screen-lock-pause: setting set \(on, privacy: .public)")
        onPausePollingChange?(on)
    }

    func setAwaitingInputEnabled(_ on: Bool) {
        awaitingInputEnabled = on
        PersistedConfig.awaitingInputEnabled = on
        onAwaitingInputEnabledChange?(on)
    }

    /// Toggle the usage journal (#242). No callback: the poll seam reads `PersistedConfig.journalEnabled`
    /// live on each write, so a change takes effect on the next poll without a restart or a wiring hop.
    func setJournalEnabled(_ on: Bool) {
        journalEnabled = on
        PersistedConfig.journalEnabled = on
        AppLogger.lifecycle.notice("journal: enabled set \(on, privacy: .public)")
    }

    func setAwaitingInputInMenuBar(_ on: Bool) {
        awaitingInputInMenuBar = on
        PersistedConfig.awaitingInputInMenuBar = on
        onAwaitingInputAppearanceChange?()
    }

    func setCalmColorMode(_ mode: CalmColorMode) {
        calmColorMode = mode
        PersistedConfig.calmColorMode = mode
        AppLogger.lifecycle.notice("calm-color-mode: set \(mode.rawValue, privacy: .public)")
        onCalmColorModeChange?(mode)
    }

    func setHideCalmSevenDay(_ on: Bool) {
        hideCalmSevenDay = on
        PersistedConfig.hideCalmSevenDayBar = on
        AppLogger.lifecycle.notice("hide-calm-7d: menu-bar set \(on, privacy: .public)")
        onHideCalmSevenDayChange?(on)
    }

    func setPauseHidesBars(_ on: Bool) {
        pauseHidesBars = on
        PersistedConfig.pauseHidesBars = on
        AppLogger.lifecycle.notice("pause-hides-bars: menu-bar set \(on, privacy: .public)")
        onPauseHidesBarsChange?(on)
    }

    func setShowExtraUsage(_ on: Bool) {
        showExtraUsage = on
        PersistedConfig.showExtraUsage = on
        AppLogger.lifecycle.notice("extra-usage-icon: menu-bar set \(on, privacy: .public)")
        onExtraUsageChange?(on)
    }

    func setModelLimitsVisibility(_ mode: PopupSectionVisibility) {
        modelLimitsVisibility = mode
        PersistedConfig.modelLimitsVisibility = mode
        AppLogger.lifecycle.notice("model-specific-limits: popup set \(mode.rawValue, privacy: .public)")
        onModelLimitsVisibilityChange?(mode)
    }

    func setExtraUsageVisibility(_ mode: PopupSectionVisibility) {
        extraUsageVisibility = mode
        PersistedConfig.extraUsageVisibility = mode
        AppLogger.lifecycle.notice("extra-usage-section: popup set \(mode.rawValue, privacy: .public)")
        onExtraUsageVisibilityChange?(mode)
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

    /// Persist the bar presentation style (#224) and fire the callback. The segmented control writes
    /// `barStyle` directly (via the binding), then calls this. Governs both surfaces.
    func setBarStyle(_ style: BarStyle) {
        barStyle = style
        PersistedConfig.barStyle = style
        AppLogger.lifecycle.notice("bar-style: set \(style.rawValue, privacy: .public)")
        onBarStyleChange?(style)
    }

    /// Persist the popup tick-ruler toggle (#224) and fire the callback.
    func setShowTicks(_ on: Bool) {
        showTicks = on
        PersistedConfig.showTicks = on
        AppLogger.lifecycle.notice("show-ticks: popup set \(on, privacy: .public)")
        onShowTicksChange?(on)
    }

    /// Persist the far-behind (green→blue) interval (#224) and fire the callback. The picker writes
    /// `farBehindInterval` directly (via the binding), then calls this. Governs both surfaces.
    func setFarBehindInterval(_ interval: FarBehindInterval) {
        farBehindInterval = interval
        PersistedConfig.farBehindInterval = interval
        AppLogger.lifecycle.notice("far-behind-interval: set \(interval.rawValue, privacy: .public)")
        onFarBehindIntervalChange?(interval)
    }

    /// Revert every Appearance-pane setting to its factory default (the "Reset" button). Clears the
    /// stored keys, re-syncs the model so the controls repaint, then fires each pane callback with the
    /// now-default value so the menu-bar widget rebuilds — the same notifications the individual setters
    /// send, so a reset looks exactly like the user having toggled each control back by hand.
    func resetAppearanceToDefaults() {
        PersistedConfig.resetAppearanceToDefaults()
        syncFromConfig()   // re-reads the (now absent) keys → default getters; refreshes the bound controls
        AppLogger.lifecycle.notice("appearance settings reset to defaults")
        fireAppearanceCallbacks()
    }

    /// Apply a named Appearance **preset** (#215, #224) — the general form of
    /// `resetAppearanceToDefaults()`. Writes all twelve keys from the preset's fixed value set, re-syncs
    /// the model so the controls repaint (the preset segmented control re-lights via `activePreset`),
    /// then fires each pane callback so both surfaces rebuild. The segmented control in `AppearancePane`
    /// calls this.
    func apply(_ preset: AppearancePreset) {
        PersistedConfig.apply(preset)
        syncFromConfig()
        AppLogger.lifecycle.notice("appearance preset applied: \(preset.rawValue, privacy: .public)")
        fireAppearanceCallbacks()
    }

    /// The live Appearance config as clipboard-ready pretty-printed JSON (#257) — the payload behind
    /// the copy button in the pane's preset row. Read-only: unlike every setter above it writes nothing
    /// to `PersistedConfig` and fires no callback, so it sits outside the "persist, then notify"
    /// contract this class otherwise follows.
    ///
    /// Returns the string rather than writing the pasteboard itself, which keeps this class free of
    /// AppKit (it imports only Foundation / Observation / the kit); the pane owns the `NSPasteboard`
    /// write. Reads `liveAppearanceValues`, so the dump always matches what the controls show —
    /// including the "Custom" state, which exports as `"preset": "custom"`.
    func appearanceConfigJSON() -> String {
        AppearanceConfigExport.json(
            values: liveAppearanceValues,
            preset: activePreset,
            appVersion: TokenPaceKit.version)
    }

    /// Fire every Appearance-pane callback with the model's current (freshly-synced) value, so the
    /// menu-bar widget rebuilds — the same notifications the individual setters send. Shared by the
    /// reset and preset paths, which both mutate all keys at once and then re-render as a batch.
    private func fireAppearanceCallbacks() {
        onCalmColorModeChange?(calmColorMode)
        onHideCalmSevenDayChange?(hideCalmSevenDay)
        onPauseHidesBarsChange?(pauseHidesBars)
        onExtraUsageChange?(showExtraUsage)
        onModelLimitsVisibilityChange?(modelLimitsVisibility)
        onExtraUsageVisibilityChange?(extraUsageVisibility)
        onServiceDotChange?(showServiceDot)
        onResetCountdownModeMenuBarChange?(ResetCountdownMode.from(radio: resetRadio))
        onBarStyleChange?(barStyle)
        onShowTicksChange?(showTicks)
        onFarBehindIntervalChange?(farBehindInterval)
        onAwaitingInputAppearanceChange?()   // #233: a preset/reset may flip the menu-bar copy
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

    /// Show every incident banner the app can produce, from the Settings "Preview" button. Unlike
    /// the other two previews this fires **three** notifications — the update, the fix-deployed
    /// ending and the recovered ending — because judging their wording means seeing them together.
    func previewIncidentNotifications() {
        onPreviewIncidents?()
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

    /// Set the popup's incident age cut-off (#279). `0` means no limit.
    func setIncidentMaxAgeHours(_ hours: Int) {
        incidentMaxAgeHours = hours
        PersistedConfig.incidentMaxAge = hours > 0 ? TimeInterval(hours) * 3600 : nil
        AppLogger.lifecycle.notice("incident: max age set \(hours, privacy: .public)h")
        // Reuse the monitored-services callback: the app re-resolves the status (and with it the
        // visible incidents) on that signal, which is exactly what a changed age cut-off needs.
        commitMonitoredServices()
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

    func installUpdateNow() {
        AppLogger.lifecycle.notice("update-install: user requested an immediate install")
        onInstallUpdateNow?()
    }

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
    /// row's "release notes" link, which carries that release's own tag. Since the "Download" button
    /// was dropped (#221) this is also the manual fallback: the release page is where a hand-download
    /// starts, which matters where auto-install can't run (dev build, or a release with no asset).
    func openReleaseNotes(tag: String) {
        NSWorkspaceOpener.open(GitHubReleaseClient.releaseNotesURL(tag: tag).absoluteString)
    }

    // MARK: Background-driven mutators (safe while the window is closed — they touch model state only)

    /// Reflect the current update state (#37): the model exposes `latestRelease`; the About pane shows
    /// "Update available: vX.Y.Z" + Download when non-nil.
    func updateAvailability(_ release: GitHubRelease?) {
        latestRelease = release
    }

    /// Reflect why an available update hasn't installed (#221): the About pane turns these into the
    /// "Update pending because …" row. A forced set from `TOKENPACE_FAKE_DEFERRAL` wins, so live
    /// verification isn't overwritten by the real (unblocked) environment on the next check.
    func updateDeferral(_ reasons: [UpdateDeferralReason]) {
        deferralReasons = SettingsModel.forcedDeferralReasons ?? reasons
    }

    /// Reflect the last archive run's low-space verdict (#306). A forced value from
    /// `TOKENPACE_FAKE_ARCHIVE_GATE` wins, so a real (unblocked) run can't wipe the state being
    /// verified — the same contract as `updateDeferral`.
    func updateArchiveBlock(_ verdict: ArchiveSpaceVerdict) {
        archiveSpaceBlock = SettingsModel.forcedArchiveGate?.space ?? verdict
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
