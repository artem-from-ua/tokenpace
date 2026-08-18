import Foundation
import TokenPaceKit

// MARK: - PersistedConfig

/// The app's persisted-settings store (#71) — a thin, side-effecting wrapper over
/// `UserDefaults.standard`.
///
/// This is the project's first persistence layer. `UserDefaults` is a system singleton (like
/// `SMAppService` behind `LaunchAtLoginController`), so it lives in the executable target and is
/// verified manually, per the pure-core / thin-shell convention (ADR-0009, ADR-0023). The testable
/// half — the decision of whether/what to migrate — lives in `MigrationPlan` (`TokenPaceKit`).
///
/// Phase 1 scope (this ticket) is deliberately minimal: a single ``lastRunVersion`` marker plus the
/// migration hook that reads and rewrites it (`AppDelegate.runConfigMigrationsIfNeeded`). A broader
/// typed config store is out of scope (#71); this type is the seam a later ticket extends with more
/// keys (e.g. the monitored-services config, #89).
@MainActor
enum PersistedConfig {
    private static let defaults = UserDefaults.standard

    private enum Key {
        /// The marketing version the settings were last written under — the input to
        /// `MigrationPlan.transition`. Absent (`nil`) on a fresh install or a pre-persistence build.
        static let lastRunVersion = "lastRunVersion"
        /// The monitored-services config (#89), stored as a JSON blob under this key.
        static let monitoredServices = "monitoredServices"
        /// Whether the usage API is polled at all (#341). Default-on (opt-out) — see the property.
        ///
        /// A **separate scalar key**, deliberately not folded into the ``monitoredServices`` blob: an
        /// older build that rewrites that blob knows nothing of this flag and would silently erase the
        /// user's choice. Two keys survive a downgrade; one blob does not.
        static let usageApiEnabled = "usageApiEnabled"
        /// The user's own Appearance setup, kept so the "Custom" segment can be returned to after a
        /// detour through the presets (#333). See ``customAppearanceValues``.
        static let customAppearanceValues = "customAppearanceValues"
        /// Whether the periodic update check runs (#37). Default-on (opt-out) — see the property.
        static let automaticUpdateChecks = "automaticUpdateChecks"
        /// Whether a found update is downloaded and installed automatically (#122). Default-**on**
        /// (opt-out) since #130 — the silent background update is the least-noisy channel; only
        /// meaningful while `automaticUpdateChecks` is on — see the property.
        static let installUpdatesAutomatically = "installUpdatesAutomatically"
        /// The tag of a successful auto-update whose "what's new" the user has not opened yet (#130),
        /// set just before the post-install relaunch — see the property.
        static let pendingWhatsNewVersion = "pendingWhatsNewVersion"
        /// The tag whose automatic install failed (#130) — gates a retry of exactly that tag; a newer
        /// tag is still attempted. See the property.
        static let lastFailedInstallVersion = "lastFailedInstallVersion"
        /// The pipeline **stage** the last failed auto-install broke at (#210), stored as the raw
        /// `LastUpdateFailure.Stage` string — surfaced on the About pane. See `lastUpdateFailure`.
        static let lastFailedInstallStage = "lastFailedInstallStage"
        /// The raw **reason** string of the last failed auto-install (#210) — surfaced on the About
        /// pane alongside the stage. See `lastUpdateFailure`.
        static let lastFailedInstallReason = "lastFailedInstallReason"
        /// Instant of the last update-check **attempt** (#37), gating the 12 h cadence.
        static let lastUpdateCheck = "lastUpdateCheck"
        /// The latest release tag last surfaced to the user (#37), so the same version is not
        /// notified twice.
        static let lastSeenLatestVersion = "lastSeenLatestVersion"
        /// What the menu bar's bar colours tell the user (#105, #224; renamed in #381), stored as the raw
        /// `ColorAdvice` string. Replaces the old `calmMenuBarColors` + `workHarderColors` pair —
        /// see the property.
        static let colorsTell = "menuBar.colorsTell"
        /// Legacy pre-#381 key for the same choice, when it was named after the colours it muted. Read
        /// once by ``PersistedConfig/migrateAppearanceKeysIfNeeded()`` to seed ``colorsTell``, then
        /// cleared. Do not read elsewhere.
        static let legacyCalmColorMode = "calmColorMode"
        /// Retired by ADR-0091. Was "Show reset countdown: Always / Smart / Never" (#103), the raw
        /// `ResetCountdownMode` string deciding when a countdown appeared beside the bars. The countdown
        /// now appears only where there are no bars, so there is nothing left to choose. Kept as a
        /// constant so an Appearance reset still sweeps a stored value, as ``retiredFarBehindInterval``
        /// does.
        static let retiredResetCountdownModeMenuBar = "resetCountdownModeMenuBar"
        /// How the **menu-bar widget** presents its pacing bars (#224, split per surface in #329),
        /// stored as the raw `BarStyle` string. Default `.gauge` (from the `.workHarder` preset) —
        /// see the property.
        static let menuBarStyle = "menuBar.style"
        /// How the **dropdown popup** presents its pacing bars (#329), stored as the raw `BarStyle`
        /// string. Default `.gauge` — see the property.
        static let dropdownStyle = "dropdown.style"
        /// Legacy pre-#381 keys for the two styles, before the surface became a key prefix. Read once by
        /// ``PersistedConfig/migrateAppearanceKeysIfNeeded()``, then cleared.
        static let legacyMenuBarStyle = "menuBarStyle"
        static let legacyDropdownStyle = "dropdownStyle"
        /// Legacy pre-#329 key — one style for both surfaces, including the `"mixed"` value that gave
        /// them different ones. Read once by ``PersistedConfig/migrateBarStyleIfNeeded()`` to seed the
        /// two per-surface keys, then cleared. Do not read elsewhere.
        static let legacyBarStyle = "barStyle"
        /// Whether the menu-bar widget draws the service-status dot on a service issue (#31).
        /// Default-on (opt-out) — see the property.
        static let showServiceStatusDot = "menuBar.showServiceStatusDot"
        /// Legacy pre-#381 key for the same toggle, before the surface became a key prefix.
        static let legacyShowServiceStatusDot = "showServiceStatusDot"
        /// Whether the **top (5-hour)** bar is hidden until it needs attention — stored as the raw
        /// `TopBarHiding` string (ADR-0086). Default `.untilItNeedsAttention` (from the `.workHarder`
        /// preset) — see the property.
        static let hideTop5hBar = "menuBar.hideTop5hBar"
        /// Legacy pre-#381 key for the same choice, when it was named after the "calm" data state. Read
        /// once by ``PersistedConfig/migrateAppearanceKeysIfNeeded()``, then cleared.
        static let legacyCalmBarHiding = "calmBarHiding"
        /// Legacy pre-ADR-0086 key — the boolean "hide the calm **7-day** bar" opt-out (#94). Read once
        /// by ``PersistedConfig/migrateTopBarHidingIfNeeded()`` to seed ``hideTop5hBar``, then cleared.
        /// Do not read elsewhere.
        static let legacyHideCalmSevenDayBar = "hideCalmSevenDayBar"
        /// **Retired** (ADR-0090). Whether the red "pause" icon hid the pacing bars while fully blocked
        /// (#194, #227). Hiding is now the only behaviour — a red 100 % bar carries no pacing
        /// information — so the choice is gone. The key is kept only so the Appearance reset can sweep
        /// away a stored value, as ``retiredFarBehindInterval`` does.
        static let retiredPauseHidesBars = "pauseHidesBars"
        /// Legacy pre-#227 keys. Their successor is retired too, so nothing reads them any more — they
        /// are swept by the Appearance reset alongside it. Do not read elsewhere.
        static let legacyHideBarsWhenBlocked = "hideBarsWhenBlocked"
        static let legacyShowBlockedPause = "showBlockedPause"
        /// **Retired** (ADR-0090). Whether the menu-bar widget drew the money-credits icon (#144). The
        /// icon is now decided by the data alone — it is already silent until credits are active and a
        /// base limit is exhausted — so the opt-out bought nothing. Swept, never read.
        static let retiredShowExtraUsage = "showExtraUsage"
        /// When the popup shows the per-model 7-day limit rows (`Opus`/`Sonnet`/`weekly_scoped`,
        /// e.g. `Fable`) below the `5h`/`7d` rows (#211), stored as the raw `PopupSectionVisibility`
        /// string. Default `.whenItNeedsAttention` — see the property.
        static let showPerModelLimits = "dropdown.showPerModelLimits"
        /// When the popup shows the "Extra usage" credits section, stored as the raw
        /// `PopupSectionVisibility` string. Default `.onceUsed` — see the property. Distinct from the
        /// **menu-bar** credits icon, which is data-driven and has no key of its own (ADR-0090).
        static let showExtraUsage = "dropdown.showExtraUsage"
        /// Legacy pre-#381 keys for the two visibility rows, before the surface became a key prefix.
        /// Read once by ``PersistedConfig/migrateAppearanceKeysIfNeeded()``, then cleared.
        static let legacyModelLimitsVisibility = "modelLimitsVisibility"
        static let legacyExtraUsageVisibility = "extraUsageVisibility"
        /// Retired markers of the two value-rewrite migrations #381 folded into
        /// ``PersistedConfig/migrateAppearanceKeysIfNeeded()``: `.nonCalm` → `.aboveZero` for Extra usage,
        /// and `.optionOnly` → `.aboveZero` for both rows (#374). Both rewrites now happen through
        /// `PopupSectionVisibility.legacyRawValues` while the key itself moves, so completion is
        /// self-evident from the old key being gone and no marker is needed. Kept as constants only so an
        /// Appearance reset still sweeps a stored value, as ``retiredFarBehindInterval`` does.
        static let retiredExtraUsageVisibilityMigrated = "extraUsageVisibilityMigratedFromNonCalm"
        static let retiredOptionOnlyVisibilityMigrated = "sectionVisibilityMigratedFromOptionOnly"
        /// Legacy pre-tri-state key (the boolean "Show model & service limits" opt-out), read once by
        /// ``PersistedConfig/migrateModelLimitsVisibilityIfNeeded()`` to seed
        /// ``modelLimitsVisibility``, then cleared. Do not read elsewhere.
        static let legacyShowModelSpecificLimits = "showModelSpecificLimits"
        /// **Retired.** Whether the popup draws the under-bar tick ruler on the pacing bars (#224).
        /// The ruler is no longer optional — it draws in every dropdown bar — so there is nothing left
        /// to store. The key is kept only so the Appearance reset can sweep a stored value away.
        static let retiredShowTicks = "showTicks"
        /// **Retired.** The far-behind (green→blue) threshold interval (#224) — the green→blue width is
        /// now the fixed shipped ×2 (`PacingModel.farBehindWidthMultiplier`), and whether blue applies
        /// at all is decided by the data (`PacingModel.weeklyHasHeadroom`), not by a preference. The key
        /// is kept only so the retiring migration and the Appearance reset can sweep it away.
        static let retiredFarBehindInterval = "farBehindInterval"
        /// Whether polling pauses while the screen is locked / off / running a screensaver (#114).
        /// Default-on (opt-out) — see the property.
        static let pausePollingWhenScreenLocked = "pausePollingWhenScreenLocked"
        /// Whether the session-log archiver runs (#110). Default-off (opt-in) — see the property.
        static let archiveEnabled = "archiveEnabled"
        /// Whether the "sessions awaiting input" indicator is shown (#233). Default-off (opt-in) —
        /// master toggle on the Appearance page; placement on its Menu bar child page. See the property.
        static let awaitingInputEnabled = "awaitingInputEnabled"
        /// **Retired** (ADR-0090). Whether the awaiting-input indicator also appeared in the menu bar
        /// (#233). Switching the feature on now places it on both surfaces: the separate placement
        /// choice asked the user to decide twice about one thing. Swept, never read.
        static let retiredAwaitingInputInMenuBar = "awaitingInputInMenuBar"
        /// Filesystem path of the user-chosen archive folder (#110), or absent if not yet set.
        static let archiveDestination = "archiveDestination"
        /// Instant of the last **successful** archive sync (#110), gating the 24 h cadence.
        static let lastArchiveSync = "lastArchiveSync"
        /// Whether the "Back to work!" notification fires when a usage limit becomes usable again
        /// (#160). Default-off (opt-in) — see the property.
        static let backToWorkEnabled = "backToWorkEnabled"
        /// Start of the allowed-notification window (#160), as minute-of-day `0…1439` local time.
        /// Default 480 (08:00) — see the property.
        static let notifyWindowStartMinute = "notifyWindowStartMinute"
        /// End of the allowed-notification window (#160), as minute-of-day `0…1439` local time.
        /// Default 1020 (17:00) — see the property.
        static let notifyWindowEndMinute = "notifyWindowEndMinute"
        /// Which weekday pair the "Back to work!" notification is suppressed on (#160), stored as the
        /// raw `SuppressDays` string. Default `.never` — see the property.
        static let notifySuppressDays = "notifySuppressDays"
        /// Persisted "was blocked" edge state for the "Back to work!" notification (#160). Survives
        /// app restart and toggle off→on so the blocked→unblocked edge is never missed — see the
        /// property.
        static let backToWorkWasBlocked = "backToWorkWasBlocked"
        /// Whether the "Now using Extra Usage Credit" notification fires when work starts overflowing
        /// onto paid credit. Default-off (opt-in) — see the property.
        static let extraUsageNotifyEnabled = "extraUsageNotifyEnabled"
        /// Persisted "was on credits" edge state for the Extra Usage notification. Survives app restart
        /// and toggle off→on so the not-spending→spending edge is never missed — see the property.
        static let extraUsageWasOnCredits = "extraUsageWasOnCredits"
        /// Whether the ⌥-revealed "Development tools…" menu / live colour tuner is unlocked (#185).
        /// Default-off (opt-in) — see the property.
        static let devToolsEnabled = "devToolsEnabled"
        /// Whether the usage journal records each poll to an append-only JSONL file (#242). Default-off
        /// (opt-in) — writing to disk without asking is a habit we don't start. See the property.
        static let journalEnabled = "journalEnabled"
        /// Whether raw status-page payloads are logged to a dev-only JSONL (#279, ADR-0071 §10).
        /// Default-off, dev-tools only — see the property.
        static let statusPayloadLogEnabled = "statusPayloadLogEnabled"
        /// The user's subscription to the current status-page episode (#279), as a JSON blob. See
        /// the property.
        static let episodeSubscription = "episodeSubscription"
        /// The weekly-utilization reconstruction state (#386), as a JSON blob. See the property.
        static let weeklyInterpolator = "weeklyInterpolator"
        /// The last server-supplied `seven_day.resets_at`, as an ISO-8601 string (ADR-0106). See
        /// the property.
        static let lastSevenDayReset = "lastSevenDayReset"
        /// Hide incidents older than this many hours; `0` means no limit (#279, ADR-0071 §9).
        static let incidentMaxAgeHours = "incidentMaxAgeHours"
        /// The Settings window's last frame, `[x, y, width, height]` in screen coordinates (ADR-0069).
        /// See the property.
        static let settingsWindowFrame = "settingsWindowFrame"
    }

    /// The marketing version the config was last written under, or `nil` if none has been recorded
    /// yet (first run after this feature shipped). Written back on every launch by the migration hook.
    static var lastRunVersion: String? {
        get { defaults.string(forKey: Key.lastRunVersion) }
        set { defaults.set(newValue, forKey: Key.lastRunVersion) }
    }

    /// The monitored-services config (#89) — which logical services to watch on the status page.
    /// Persisted as JSON so the `Codable` shape can grow. Reads fall back to
    /// ``MonitoredServices/default`` when the key is absent (first run) or the blob fails to decode
    /// (corrupt / an incompatible older shape) — an honest default rather than a crash, matching the
    /// forward-compatible decoding in `MonitoredServices` itself.
    static var monitoredServices: MonitoredServices {
        get {
            guard let data = defaults.data(forKey: Key.monitoredServices),
                  let decoded = try? JSONDecoder().decode(MonitoredServices.self, from: data)
            else { return .default }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.monitoredServices)
        }
    }

    /// Whether the usage API is polled at all (#341) — the switch behind the bars.
    ///
    /// Default-on via the `object(forKey:) as? Bool ?? true` idiom, like every other opt-out here:
    /// `bool(forKey:)` would read an absent key and an explicit `false` identically and defeat the
    /// opt-out. Stored as its own scalar rather than inside the ``monitoredServices`` blob — see
    /// `Key.usageApiEnabled` for why a downgrade makes that distinction matter.
    ///
    /// Turning this off is a legitimate choice, not a broken state: the status-page services keep
    /// being monitored and the menu bar says so with its own glyph, rather than an error.
    static var usageApiEnabled: Bool {
        get { defaults.object(forKey: Key.usageApiEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.usageApiEnabled) }
    }

    /// The same read, callable off the main actor — the polling engine's seam reads this on every
    /// iteration from its own task, and this type is `@MainActor`.
    ///
    /// `nonisolated` and going straight to `UserDefaults` (which is thread-safe) rather than
    /// duplicating the key string at the call site: one source of truth for both the key and the
    /// opt-out default, so the two readers cannot drift apart.
    nonisolated static func usageApiEnabledUnsafe() -> Bool {
        UserDefaults.standard.object(forKey: Key.usageApiEnabled) as? Bool ?? true
    }

    /// The two halves above read as one value — what the provider pages edit and what the polling and
    /// status layers consume. A computed composite rather than a stored one: there is nothing extra to
    /// persist, and `claudeApiLocked` stays derived.
    static var providerMonitoring: ProviderMonitoring {
        get { ProviderMonitoring(usageApiEnabled: usageApiEnabled, services: monitoredServices) }
        set {
            usageApiEnabled = newValue.usageApiEnabled
            monitoredServices = newValue.services
        }
    }

    /// Whether TokenPace checks GitHub Releases for a newer version twice a day (#37). **Default-on**
    /// (opt-out): an absent key reads as `true`. `object(forKey:) as? Bool ?? true` distinguishes
    /// "unset" (→ true) from an explicit `false` the user chose — `bool(forKey:)` would collapse both
    /// to `false` and silently defeat the opt-out default.
    static var automaticUpdateChecks: Bool {
        get { defaults.object(forKey: Key.automaticUpdateChecks) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.automaticUpdateChecks) }
    }

    /// Whether a found update is **downloaded and installed automatically** (#122, ADR-0033/0034).
    /// **Default-on** (opt-out) since #130: an absent key reads as `true`, because a silent background
    /// update that just relaunches is the *least*-noisy channel now that the banner is gone — the goal
    /// is to interrupt as little as possible until the App Store build. `object(forKey:) as? Bool ??
    /// true` distinguishes "unset" (→ true) from an explicit `false` the user chose — `bool(forKey:)`
    /// would collapse both to `false` and defeat the opt-out. Only meaningful while
    /// ``automaticUpdateChecks`` is on (the installer rides the same found-update path); the Settings
    /// checkbox is nested under it. The full flow additionally requires a real `.app` in
    /// `/Applications` — see `UpdateInstallPlan` — so a dev build's checkbox is disabled regardless.
    static var installUpdatesAutomatically: Bool {
        get { defaults.object(forKey: Key.installUpdatesAutomatically) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.installUpdatesAutomatically) }
    }

    /// The tag of a **successful** auto-update whose "what's new" the user has not yet opened (#130),
    /// or `nil`. Set just before the post-install relaunch (`AppDelegate.startInstall`), so it survives
    /// the restart and drives the blue `whatsNew` menu item (`UpdateMenuState`). Cleared when the user
    /// opens the item (which links to the releases page) or when a release newer than the installed
    /// build appears (that supersedes it — see `handleUpdateFound`).
    static var pendingWhatsNewVersion: String? {
        get { defaults.string(forKey: Key.pendingWhatsNewVersion) }
        set { defaults.set(newValue, forKey: Key.pendingWhatsNewVersion) }
    }

    /// The tag whose automatic install **failed** and must not be retried (#130), or `nil`. Set when
    /// an install attempt returns a failure outcome (`AppDelegate.startInstall`); it gates a retry of
    /// exactly that tag (the red `updateFailed` menu item), while a *newer* tag is still attempted —
    /// `UpdateMenuState` only matches this against the current latest. A one-off retry is available by
    /// clearing it manually; a normal newer release clears the gate implicitly by not matching.
    static var lastFailedInstallVersion: String? {
        get { defaults.string(forKey: Key.lastFailedInstallVersion) }
        set { defaults.set(newValue, forKey: Key.lastFailedInstallVersion) }
    }

    /// The pipeline stage the last failed auto-install broke at (#210), as the raw
    /// `LastUpdateFailure.Stage` string, or `nil`. Written together with ``lastFailedInstallVersion``
    /// and ``lastFailedInstallReason`` in `AppDelegate.startInstall`; prefer the ``lastUpdateFailure``
    /// accessor, which reads all three atomically.
    static var lastFailedInstallStage: String? {
        get { defaults.string(forKey: Key.lastFailedInstallStage) }
        set { defaults.set(newValue, forKey: Key.lastFailedInstallStage) }
    }

    /// The raw reason string of the last failed auto-install (#210), or `nil`. See
    /// ``lastFailedInstallStage`` / ``lastUpdateFailure``.
    static var lastFailedInstallReason: String? {
        get { defaults.string(forKey: Key.lastFailedInstallReason) }
        set { defaults.set(newValue, forKey: Key.lastFailedInstallReason) }
    }

    /// The last failed auto-install as a single value (#210), assembled from the three persisted
    /// fields (tag + stage + reason). Returns `nil` unless **all three** are present and the stage
    /// parses — a partial/legacy write (e.g. a pre-#210 `lastFailedInstallVersion` with no stage)
    /// reads as "no detailed failure to show", so the About pane simply omits the row.
    ///
    /// The setter is a convenience for clearing (`= nil` wipes all three keys); a non-nil set writes
    /// the three fields together. `lastFailedInstallVersion` stays the source of truth the menu-item
    /// state machine reads, so it is written/cleared in lockstep here.
    static var lastUpdateFailure: LastUpdateFailure? {
        get {
            guard let tag = lastFailedInstallVersion,
                  let rawStage = lastFailedInstallStage,
                  let stage = LastUpdateFailure.Stage(rawValue: rawStage),
                  let reason = lastFailedInstallReason
            else { return nil }
            return LastUpdateFailure(tag: tag, stage: stage, reason: reason)
        }
        set {
            lastFailedInstallVersion = newValue?.tag
            lastFailedInstallStage = newValue?.stage.rawValue
            lastFailedInstallReason = newValue?.reason
        }
    }

    /// Instant of the last update-check **attempt** (success or graceful failure), or `nil` if none
    /// has run yet. Advanced on every attempt so a private-repo 404 does not retry each heartbeat —
    /// the 12 h gate is on the *attempt*, not the *success* (`UpdateCheckCadence`, ADR-0025).
    static var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    /// The latest release tag last surfaced to the user (e.g. `"v0.20.0"`), or `nil` if none yet.
    /// Guards the notification against re-firing daily for the same un-upgraded version — the banner
    /// posts only when the freshly-found tag differs from this.
    static var lastSeenLatestVersion: String? {
        get { defaults.string(forKey: Key.lastSeenLatestVersion) }
        set { defaults.set(newValue, forKey: Key.lastSeenLatestVersion) }
    }

    /// How much of the menu-bar widget's **soft** pacing palette mutes to white (#105, #224, ADR-0061)
    /// — the single three-way ``ColorAdvice`` that replaces the old `calmMenuBarColors` +
    /// `workHarderColors` pair. `.off` keeps every colour; `.yellowGreen` mutes the greens/yellows but
    /// keeps the far-behind blue coloured (the old "Work harder"); `.yellowGreenBlue` mutes the blue
    /// too (the quietest). Stored as the raw string; an absent key or an unrecognised value (a newer
    /// build's) falls back to the factory default (`AppearancePreset.default`). The strong warnings
    /// (orange/red), the time-indicator dot, and the error triangle are unaffected; the popup keeps its
    /// full colour too.
    static var colorsTell: ColorAdvice {
        get {
            let raw = defaults.string(forKey: Key.colorsTell) ?? ""
            return ColorAdvice(rawValue: raw)
                ?? ColorAdvice.legacyRawValues[raw]
                ?? AppearancePreset.defaultValues.colorsTell
        }
        set { defaults.set(newValue.rawValue, forKey: Key.colorsTell) }
    }

    /// How the **menu-bar widget** presents its pacing bars (#224, per-surface since #329). Stored as
    /// the raw `BarStyle` string; an absent key or an unrecognised value (a newer build's) reads as
    /// the preset default — ``BarStyle/gauge``, from `.workHarder`. Render-only: never changes the
    /// underlying layout, severity, or which bars are shown.
    ///
    /// The getter looks up `rawValue` **only**, not `BarStyle`'s legacy-aware `Codable` decode, so a
    /// value written by an older build (`"pacing"`, `"simple"`, `"mixed"`) would silently read as the
    /// default. That is why ``migrateBarStyleIfNeeded()`` must run before the first read — see there.
    static var menuBarStyle: BarStyle {
        get { BarStyle(rawValue: defaults.string(forKey: Key.menuBarStyle) ?? "") ?? AppearancePreset.defaultValues.menuBarStyle }
        set { defaults.set(newValue.rawValue, forKey: Key.menuBarStyle) }
    }

    /// How the **dropdown popup** presents its pacing bars (#329) — chosen independently of
    /// ``menuBarStyle``, so the compact bar and the roomy popup can differ. Same storage, same
    /// preset-default fallback, and the same dependence on ``migrateBarStyleIfNeeded()``.
    static var dropdownStyle: BarStyle {
        get { BarStyle(rawValue: defaults.string(forKey: Key.dropdownStyle) ?? "") ?? AppearancePreset.defaultValues.dropdownStyle }
        set { defaults.set(newValue.rawValue, forKey: Key.dropdownStyle) }
    }

    /// Whether the **menu-bar** widget draws the service-status dot when a monitored service has a
    /// non-operational issue (#31). **Default-on** (opt-out): an absent key reads as `true`, so the
    /// dot shows out of the box. `object(forKey:) as? Bool ?? true` distinguishes "unset" (→ true)
    /// from an explicit `false` the user chose — `bool(forKey:)` would collapse both to `false` and
    /// silently defeat the opt-out default. Menu-bar only: the popup's service-status rows are
    /// unaffected.
    static var showServiceStatusDot: Bool {
        get { defaults.object(forKey: Key.showServiceStatusDot) as? Bool ?? AppearancePreset.defaultValues.showServiceStatusDot }
        set { defaults.set(newValue, forKey: Key.showServiceStatusDot) }
    }

    /// Which **menu-bar** bar is hidden while it is calm — green (on pace or behind), mild-ahead yellow,
    /// or far-behind blue (`BarView.isCalm`) — leaving the other one as the single, vertically centred
    /// bar (ADR-0086, supersedes the boolean of #94). Default `.fiveHour` from the `.workHarder` preset:
    /// out of the box the 5-hour bar steps aside while quiet and the 7-day one stays.
    ///
    /// An **orange/red** bar always stays visible, and at most one bar is ever hidden, so the widget
    /// never empties. The error state (⚠️ + stale bars, #12) is unaffected — both bars are kept there
    /// for diagnostics regardless of this choice. An absent or unrecognised value falls back to the
    /// preset default; ``migrateTopBarHidingIfNeeded()`` carries an explicit pre-ADR-0086 boolean over.
    static var hideTop5hBar: TopBarHiding {
        get {
            let raw = defaults.string(forKey: Key.hideTop5hBar) ?? ""
            return TopBarHiding(rawValue: raw)
                ?? TopBarHiding.legacyRawValues[raw]
                ?? AppearancePreset.defaultValues.hideTop5hBar
        }
        set { defaults.set(newValue.rawValue, forKey: Key.hideTop5hBar) }
    }

    /// When the **popup** lists the per-model 7-day limit rows — the legacy `Opus`/`Sonnet`
    /// sub-windows and the `weekly_scoped` models from `limits[]` (e.g. `Fable`, #65) — below the
    /// `5h`/`7d` rows (#211). Governs the popup only; the menu-bar widget is unaffected.
    ///
    /// Was a boolean opt-out before the tri-state (`PopupSectionVisibility`): `.always` is the old
    /// "on", the retired `.optionOnly` the old "off", and the `.whenItNeedsAttention` default shows the
    /// rows only while one of them is orange/red (or ⌥ is held). Existing explicit choices are carried
    /// over by ``migrateModelLimitsVisibilityIfNeeded()``. An absent value falls back to the factory
    /// preset's value; a pre-#381 raw resolves through `PopupSectionVisibility.legacyRawValues`.
    static var showPerModelLimits: PopupSectionVisibility {
        get {
            let raw = defaults.string(forKey: Key.showPerModelLimits) ?? ""
            return PopupSectionVisibility(rawValue: raw)
                ?? PopupSectionVisibility.legacyRawValues[raw]
                ?? AppearancePreset.defaultValues.modelLimitsVisibility
        }
        set { defaults.set(newValue.rawValue, forKey: Key.showPerModelLimits) }
    }

    /// When the **popup** shows the "Extra usage" money-credits section (`PopupLayout.credits`).
    /// Governs the popup only — the menu-bar credits icon (¤) has no user gate at all since ADR-0090,
    /// because the two surfaces answer different questions: the icon is a glanceable badge, this is the
    /// detail section the user opened the dropdown to read.
    ///
    /// This row offers `.always` / `.onceUsed` — **no** `.whenItNeedsAttention`. Money has no quiet
    /// reading to gate on: an unlimited cap yields no bar and hence no severity at all, and with a cap
    /// "spent > 0" always precedes orange. An absent value falls back to the factory preset's value; a
    /// pre-#381 raw (including the retired `nonCalm` and `optionOnly`) resolves through
    /// `PopupSectionVisibility.legacyRawValues`, which lands both on `.onceUsed`.
    static var showExtraUsage: PopupSectionVisibility {
        get {
            let raw = defaults.string(forKey: Key.showExtraUsage) ?? ""
            let stored = PopupSectionVisibility(rawValue: raw)
                ?? PopupSectionVisibility.legacyRawValues[raw]
                ?? AppearancePreset.defaultValues.extraUsageVisibility
            // Fold the one mode this row does not offer, wherever it came from — the key migration handles
            // an upgrade, but a **hand-edited or imported** config can carry it too, and the control would
            // then open with no segment highlighted.
            return stored.foldedForCredits
        }
        set { defaults.set(newValue.rawValue, forKey: Key.showExtraUsage) }
    }

    /// Revert every setting the **Appearance** pane owns to its factory default — the menu-bar widget
    /// toggles, the wallpaper-brightness theme, the reset-countdown mode, and the dropdown's per-model
    /// toggle. Done by **removing** each key (not writing an explicit default), so each property's getter
    /// falls back to its own default and the two never drift apart. Only these keys are cleared — never
    /// the whole domain (which would also wipe unrelated panes' settings). The caller re-syncs the model
    /// and re-applies the values to the widget.
    static func resetAppearanceToDefaults() {
        for key in [
            Key.colorsTell,
            Key.showServiceStatusDot,
            Key.hideTop5hBar,
            // Cleared too, for the same reason as `legacyBarStyle` below: a Reset must also sweep a
            // pre-ADR-0086 boolean the migration may not have reached yet, or it would sit there ready
            // to re-seed `hideTop5hBar` on a later launch.
            Key.legacyHideCalmSevenDayBar,
            Key.showPerModelLimits,
            Key.showExtraUsage,
            Key.menuBarStyle,
            Key.dropdownStyle,
            // The pre-#381 flat keys, swept for the same reason: a Reset must not leave one waiting to
            // re-seed its renamed successor on a later launch.
            Key.legacyCalmColorMode,
            Key.legacyCalmBarHiding,
            Key.legacyShowServiceStatusDot,
            Key.legacyModelLimitsVisibility,
            Key.legacyExtraUsageVisibility,
            Key.legacyMenuBarStyle,
            Key.legacyDropdownStyle,
            // The two retired migration markers (#381 folded both rewrites into the key move), swept so
            // a Reset leaves no stale bookkeeping behind.
            Key.retiredExtraUsageVisibilityMigrated,
            Key.retiredOptionOnlyVisibilityMigrated,
            // Cleared too, so a reset also sweeps away a pre-#329 value the migration may not have
            // reached yet — otherwise it would be waiting to re-seed the two keys on a later launch.
            Key.legacyBarStyle,
            // Retired keys, still swept so a Reset also clears them for anyone who never launched the
            // retiring build (see each `Key.retired…` for what it used to mean).
            Key.retiredShowTicks,
            Key.retiredFarBehindInterval,
            Key.retiredPauseHidesBars,
            Key.retiredShowExtraUsage,
            Key.retiredAwaitingInputInMenuBar,
            Key.retiredResetCountdownModeMenuBar,
            // The pre-#227 pair the retired pause key once inherited from — swept here too, since the
            // migration that used to clear them retired along with it.
            Key.legacyHideBarsWhenBlocked,
            Key.legacyShowBlockedPause,
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Sweep away the pause-related keys retired by ADR-0090 — the unified `pauseHidesBars` and the two
    /// pre-#227 booleans it once inherited from (`hideBarsWhenBlocked`, `showBlockedPause`).
    ///
    /// Nothing reads any of them any more: hiding the bars while blocked is the only behaviour, so the
    /// choice they encoded no longer exists. This is the same shape as ``retireFarBehindIntervalIfNeeded()``
    /// — an unconditional `removeObject`, idempotent by construction, kept so an upgrading install does
    /// not carry dead values forever. It also inherits the legacy pair's only cleaner: the migration that
    /// used to sweep them is gone with the key it fed.
    static func retirePauseKeysIfNeeded() {
        defaults.removeObject(forKey: Key.retiredPauseHidesBars)
        defaults.removeObject(forKey: Key.legacyHideBarsWhenBlocked)
        defaults.removeObject(forKey: Key.legacyShowBlockedPause)
    }

    /// Retire the "Far behind pace interval" key. The option is gone: the green→blue width is the fixed
    /// shipped ×2 (`PacingModel.farBehindWidthMultiplier`), and whether blue applies at all is now
    /// decided by the data (`PacingModel.weeklyHasHeadroom`) rather than by a preference.
    ///
    /// There is **no successor to seed** — unlike the pause/bar-style migrations, the stored value maps
    /// onto nothing, so this simply clears it (the `clearLegacyPauseKeys` shape). Idempotent; runs on
    /// every launch and does nothing once the key is gone.
    ///
    /// Note for anyone reading a `defaults export` afterwards: users who had picked
    /// *"Less blue, please!"* (the retired `off`) will start seeing the far-behind blue again in the
    /// dropdown. On the menu bar the shipped calm default still mutes it to white.
    static func retireFarBehindIntervalIfNeeded() {
        defaults.removeObject(forKey: Key.retiredFarBehindInterval)
    }

    /// Retire the "Show reset countdown" key (ADR-0091). The option is gone: a countdown now appears
    /// exactly where there are no bars — blocked, or paying — and nowhere else, so none of its three
    /// values has anything left to select.
    ///
    /// **No successor to seed**, like ``retireFarBehindIntervalIfNeeded()``: every stored value maps onto
    /// the one remaining behaviour. Idempotent; runs on every launch and does nothing once the key is gone.
    ///
    /// Worth knowing when reading a `defaults export` afterwards: this is visible to *everyone*, not
    /// just to whoever changed the setting. On the shipped default (`smart`) a countdown used to appear
    /// beside the bars whenever a window ran well ahead of pace; it no longer does.
    static func retireResetCountdownModeIfNeeded() {
        defaults.removeObject(forKey: Key.retiredResetCountdownModeMenuBar)
    }

    /// One-time upgrade of the boolean "Show model & service limits" opt-out to the tri-state
    /// ``modelLimitsVisibility`` (#211). The old key answered "show the per-model rows or not"; the new
    /// one answers "when", so an explicit choice maps onto the two endpoints:
    ///
    /// - `true` (rows were always shown) → ``PopupSectionVisibility/always``
    /// - `false` (rows were hidden) → ``PopupSectionVisibility/onceUsed``. This used to land on
    ///   `.optionOnly` (hidden, but ⌥ Option retrieved them); #381 deleted that case, and the legacy
    ///   raw now resolves through ``PopupSectionVisibility/legacyRawValues`` like every other one.
    ///
    /// Runs on every launch and is idempotent: it does nothing once the new key exists (the legacy key is
    /// cleared either way). Only an **explicit** legacy value migrates — someone who never touched the
    /// old toggle gets the new ``PopupSectionVisibility/whenItNeedsAttention`` default from the
    /// getter's preset fallback.
    ///
    /// There is no counterpart for the Extra-usage section: it had no popup-side setting before, so
    /// everyone starts on the preset default.
    /// One-time upgrade of the boolean "hide the calm **7-day** bar" opt-out (#94) to the tri-state
    /// ``hideTop5hBar`` (ADR-0086). The old key could only ever hide the 7-day bar, so an explicit
    /// choice maps onto two of the three cases — `true` → `.sevenDay`, `false` → `.never` — each
    /// preserving exactly what the user was looking at. The mapping itself lives in
    /// `TopBarHiding.migrated(fromLegacyHide:)` so it is unit-testable from the Kit and shared with the
    /// exported-config decode.
    ///
    /// Runs on every launch and is idempotent: it does nothing once the new key exists (the legacy key is
    /// cleared either way). Only an **explicit** legacy value migrates. Someone who never touched the old
    /// toggle has nothing stored, so they pick up the new ``TopBarHiding/untilItNeedsAttention``
    /// default from the getter's preset
    /// fallback — a deliberate shift of the out-of-the-box look (the 7-day bar now stays and the 5-hour
    /// one steps aside while calm), the same way ADR-0080 moved the factory bar style.
    static func migrateTopBarHidingIfNeeded() {
        // Already migrated (or new key explicitly set) → nothing to do. Both the #381 key and its
        // pre-#381 predecessor count as "set": `migrateAppearanceKeysIfNeeded()` moves the latter onto
        // the former, and it must not be pre-empted by a boolean two generations older.
        guard defaults.object(forKey: Key.hideTop5hBar) == nil,
              defaults.object(forKey: Key.legacyCalmBarHiding) == nil else {
            defaults.removeObject(forKey: Key.legacyHideCalmSevenDayBar)
            return
        }
        if let legacyHide = defaults.object(forKey: Key.legacyHideCalmSevenDayBar) as? Bool {
            let migrated = TopBarHiding.migrated(fromLegacyHide: legacyHide)
            hideTop5hBar = migrated
            AppLogger.lifecycle.notice(
                "hide-top-5h-bar: migrated \(legacyHide, privacy: .public) → \(migrated.rawValue, privacy: .public)")
        }
        defaults.removeObject(forKey: Key.legacyHideCalmSevenDayBar)
    }

    static func migrateModelLimitsVisibilityIfNeeded() {
        // Already migrated (or either generation of the key explicitly set) → nothing to do.
        guard defaults.object(forKey: Key.showPerModelLimits) == nil,
              defaults.object(forKey: Key.legacyModelLimitsVisibility) == nil else {
            defaults.removeObject(forKey: Key.legacyShowModelSpecificLimits)
            return
        }
        if let legacyShow = defaults.object(forKey: Key.legacyShowModelSpecificLimits) as? Bool {
            // `false` used to land on the retired `.optionOnly` (#374, removed outright in #381).
            // `.whenItNeedsAttention` is this row's default and the nearest reading of the old intent:
            // the user had the group switched off, so it should stay folded — but it now comes back on
            // its own when a row turns orange, instead of only under ⌥.
            showPerModelLimits = legacyShow ? .always : .whenItNeedsAttention
        }
        defaults.removeObject(forKey: Key.legacyShowModelSpecificLimits)
    }

    /// Move all seven Appearance keys onto their #381 names — the surface-prefixed
    /// `menuBar.*` / `dropdown.*` form — carrying each stored **value** through its type's
    /// `legacyRawValues` on the way.
    ///
    /// One migration for seven keys rather than seven migrations: they move together, in one release, so
    /// a single event describes it and a single pass is atomic. Per key: if the new key is absent and the
    /// old one is present, read the old raw, resolve it through the type (so `aboveZero` → `onceUsed`,
    /// `yellowGreen` → `slowDownOrSpeedUp`, `fiveHour` → `untilItNeedsAttention`), write the new key,
    /// delete the old one, log it.
    ///
    /// **An absent old key is left absent** — the value then keeps tracking the preset default, exactly
    /// as the sibling legacy migrations do.
    ///
    /// **Idempotent by construction, no marker key.** Each key's rewrite is guarded on "new key absent"
    /// and consumes the old key, so completion is self-evident from the old key being gone. That is why
    /// #381 could fold in the two marker-keyed *value* rewrites this replaces —
    /// `.nonCalm` → `.aboveZero` for Extra usage, and `.optionOnly` → `.aboveZero` for both rows (#374).
    /// Both now happen through `PopupSectionVisibility.legacyRawValues` while the key itself moves:
    /// `optionOnly` and `nonCalm` both resolve to `.onceUsed` there, and neither raw survives as a case,
    /// so there is nothing left for a later import to reintroduce. Their markers are retired
    /// (`Key.retired…Migrated`) and only swept by an Appearance reset.
    ///
    /// Reads raw strings rather than the typed getters: a getter resolves an unrecognised raw to the
    /// preset default, which would hide the very value being migrated.
    static func migrateAppearanceKeysIfNeeded() {
        migrateRawKey(from: Key.legacyMenuBarStyle, to: Key.menuBarStyle, label: "menu-bar-style") {
            BarStyle(rawValue: $0)?.rawValue ?? BarStyle.legacyRawValues[$0]?.rawValue
        }
        migrateRawKey(from: Key.legacyDropdownStyle, to: Key.dropdownStyle, label: "dropdown-style") {
            BarStyle(rawValue: $0)?.rawValue ?? BarStyle.legacyRawValues[$0]?.rawValue
        }
        migrateRawKey(from: Key.legacyCalmColorMode, to: Key.colorsTell, label: "colors-tell") {
            ColorAdvice(rawValue: $0)?.rawValue ?? ColorAdvice.legacyRawValues[$0]?.rawValue
        }
        migrateRawKey(from: Key.legacyCalmBarHiding, to: Key.hideTop5hBar, label: "hide-top-5h-bar") {
            TopBarHiding(rawValue: $0)?.rawValue ?? TopBarHiding.legacyRawValues[$0]?.rawValue
        }
        migrateRawKey(
            from: Key.legacyModelLimitsVisibility, to: Key.showPerModelLimits,
            label: "show-per-model-limits"
        ) {
            PopupSectionVisibility(rawValue: $0)?.rawValue
                ?? PopupSectionVisibility.legacyRawValues[$0]?.rawValue
        }
        migrateRawKey(
            from: Key.legacyExtraUsageVisibility, to: Key.showExtraUsage, label: "show-extra-usage"
        ) {
            // Folded for this row: it offers only `.onceUsed` / `.always`, so a stored (or
            // legacy-resolved) `.whenItNeedsAttention` has to land on `.onceUsed`. The shared legacy table
            // cannot do it — it does not know which row is reading — and without the fold the control opens
            // with **no segment highlighted**, the exact defect the retired
            // `migrateExtraUsageVisibilityIfNeeded()` existed to prevent.
            (PopupSectionVisibility(rawValue: $0) ?? PopupSectionVisibility.legacyRawValues[$0])?
                .foldedForCredits.rawValue
        }

        // The one `Bool`, so it needs its own two lines rather than the string helper.
        if defaults.object(forKey: Key.showServiceStatusDot) == nil,
           let old = defaults.object(forKey: Key.legacyShowServiceStatusDot) as? Bool {
            defaults.set(old, forKey: Key.showServiceStatusDot)
            AppLogger.lifecycle.notice(
                "service-status-dot: migrated key → \(Key.showServiceStatusDot, privacy: .public)")
        }
        defaults.removeObject(forKey: Key.legacyShowServiceStatusDot)
    }

    /// One key's half of ``migrateAppearanceKeysIfNeeded()``: move a raw string from `from` to `to`,
    /// mapping the value through `resolve` (the type's own current-or-legacy lookup).
    ///
    /// A raw that `resolve` cannot place is **dropped rather than copied**: it belongs to no case this
    /// build knows, so writing it through would only make the new key fail its own decode. Dropping lets
    /// the getter fall back to the preset default, which is the same thing an unreadable value has always
    /// meant here.
    private static func migrateRawKey(
        from old: String, to new: String, label: String,
        resolve: (String) -> String?
    ) {
        defer { defaults.removeObject(forKey: old) }
        guard defaults.object(forKey: new) == nil,
              let oldRaw = defaults.string(forKey: old) else { return }
        guard let newRaw = resolve(oldRaw) else {
            AppLogger.lifecycle.notice(
                "\(label, privacy: .public): dropped unrecognised legacy value \(oldRaw, privacy: .public)")
            return
        }
        defaults.set(newRaw, forKey: new)
        AppLogger.lifecycle.notice(
            "\(label, privacy: .public): migrated \(oldRaw, privacy: .public) → \(newRaw, privacy: .public)")
    }

    /// Split the pre-#329 single `barStyle` key into the per-surface ``menuBarStyle`` /
    /// ``dropdownStyle`` pair, reproducing exactly what the old value drew — including the pre-#307
    /// renames, since a value can be both old *and* unsplit. The mapping lives in
    /// `BarStyle.legacySurfaceStyles(for:)`, shared with the exported-config decode.
    ///
    /// | stored `barStyle` | menu bar | dropdown |
    /// |---|---|---|
    /// | `"mixed"` | `.pressure` | `.progress` |
    /// | `"pacing"` / `"progress"` | `.progress` | `.progress` |
    /// | `"simple"` / `"pressure"` | `.pressure` | `.pressure` |
    /// | `"gauge"` | `.gauge` | `.gauge` |
    ///
    /// **Why it is not optional.** Both getters resolve an unrecognised raw to the preset default,
    /// silently — and after #329 *every* stored `barStyle` is unrecognised, since the key itself is
    /// gone. Without this pass each user's deliberate choice would be replaced by whatever the
    /// default preset says, with no error and no trace. Splitting `"mixed"` across the two surfaces
    /// rather than collapsing it to one style is what keeps that upgrade visually invisible.
    ///
    /// **A user who never set the key is not migrated at all** — nothing is written, both getters
    /// fall back to `.workHarder`, and that user sees the new default (Gauge). That is intended: the
    /// default moved, and only people who never expressed a preference follow it.
    ///
    /// Runs on every launch and is idempotent: once either new key exists the legacy key is cleared
    /// and the pass does nothing, and an absent legacy key stays absent.
    static func migrateBarStyleIfNeeded() {
        // Already migrated (or a new key explicitly set) → drop the stale legacy value and stop.
        // Either generation of either key counts as "already split": `migrateAppearanceKeysIfNeeded()`
        // moves the pre-#381 flat names onto the prefixed ones, and a pre-#329 single value must not
        // pre-empt that.
        guard defaults.object(forKey: Key.menuBarStyle) == nil,
              defaults.object(forKey: Key.dropdownStyle) == nil,
              defaults.object(forKey: Key.legacyMenuBarStyle) == nil,
              defaults.object(forKey: Key.legacyDropdownStyle) == nil else {
            defaults.removeObject(forKey: Key.legacyBarStyle)
            return
        }
        guard let raw = defaults.string(forKey: Key.legacyBarStyle) else { return }  // never set → preset default
        guard let split = BarStyle.legacySurfaceStyles(for: raw) else {              // unknown → getters' fallback
            defaults.removeObject(forKey: Key.legacyBarStyle)
            return
        }
        menuBarStyle = split.menuBar
        dropdownStyle = split.dropdown
        defaults.removeObject(forKey: Key.legacyBarStyle)
        AppLogger.lifecycle.notice(
            """
            bar-style: migrated \(raw, privacy: .public) → menu-bar \
            \(split.menuBar.rawValue, privacy: .public), dropdown \
            \(split.dropdown.rawValue, privacy: .public)
            """)
    }

    /// Write every **Appearance**-pane key from a named preset's fixed value set (#215, #224) — the
    /// general form of `resetAppearanceToDefaults()`. Unlike reset (which *removes* keys so getters fall
    /// back to their defaults), this writes explicit values, because a preset can differ from the
    /// factory defaults (e.g. `.controlFreak` turns calm off; `.chill` opts into `.pressure` bars while
    /// the default `.workHarder` preset uses `.gauge`). The caller re-syncs the model and re-applies the
    /// values to the widget.
    static func apply(_ preset: AppearancePreset) { applyValues(preset.values) }

    /// The user's own Appearance setup — the values the **Custom** segment restores (#333).
    ///
    /// Custom used to be an indicator: it lit up when the live config matched no preset, and clicking
    /// it did nothing, so trying a preset destroyed a hand-made setup with no way back. Keeping a
    /// snapshot makes it a real slot — try Chill, then return to exactly what you had.
    ///
    /// Written whenever the live config drifts off every preset (that drift *is* the user's custom
    /// setup), never by applying a preset. `nil` until such a drift exists, which is what keeps the
    /// segment unselectable on a fresh install: there is nothing to go back to yet.
    static var customAppearanceValues: AppearancePresetValues? {
        get {
            guard let data = defaults.data(forKey: Key.customAppearanceValues),
                  let decoded = try? JSONDecoder().decode(AppearancePresetValues.self, from: data)
            else { return nil }
            return decoded
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Key.customAppearanceValues)
                return
            }
            defaults.set(data, forKey: Key.customAppearanceValues)
        }
    }

    /// Write every Appearance key from an arbitrary value set — the general form of ``apply(_:)``,
    /// used to restore the saved Custom setup (#333).
    static func applyValues(_ v: AppearancePresetValues) {
        colorsTell = v.colorsTell
        hideTop5hBar = v.hideTop5hBar
        showServiceStatusDot = v.showServiceStatusDot
        showPerModelLimits = v.modelLimitsVisibility
        showExtraUsage = v.extraUsageVisibility
        menuBarStyle = v.menuBarStyle
        dropdownStyle = v.dropdownStyle
    }

    /// The live Appearance config assembled into an `AppearancePresetValues` — the read-mirror of
    /// ``apply(_:)`` (#224). Used by the Settings model to light the preset segmented control's active
    /// segment via `AppearancePreset.matching(_:)`: equal to a preset's `.values` → that preset is
    /// active; equal to none → the "Custom" slot.
    static var currentAppearanceValues: AppearancePresetValues {
        AppearancePresetValues(
            colorsTell: colorsTell,
            hideTop5hBar: hideTop5hBar,
            showServiceStatusDot: showServiceStatusDot,
            modelLimitsVisibility: showPerModelLimits,
            extraUsageVisibility: showExtraUsage,
            menuBarStyle: menuBarStyle,
            dropdownStyle: dropdownStyle)
    }

    /// Whether polling pauses while the screen is **locked, off, or running a screensaver** (#114,
    /// ADR-0032). **Default-on** (opt-out): an absent key reads as `true`, so a screen-off Mac stops
    /// spending usage-API quota on refreshes nobody sees, resuming with an immediate poll on wake.
    /// `object(forKey:) as? Bool ?? true` distinguishes "unset" (→ true) from an explicit `false` the
    /// user chose — `bool(forKey:)` would collapse both to `false` and silently defeat the opt-out.
    /// Read live by ``ScreenLockObserver`` on each lock/unlock, so a Settings change needs no restart.
    /// Whole-system sleep/wake (``WorkspaceSleepWake``) is unaffected — it always parks.
    static var pausePollingWhenScreenLocked: Bool {
        get { defaults.object(forKey: Key.pausePollingWhenScreenLocked) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.pausePollingWhenScreenLocked) }
    }

    /// Whether the session-log archiver mirrors Claude Code's raw logs to a folder (#110).
    /// **Default-off** (opt-in): an absent key reads as `false`, so nothing is copied until the user
    /// turns it on *and* picks a destination. `object(forKey:) as? Bool ?? false` distinguishes
    /// "unset" from an explicit choice, consistent with the other opt-in toggles.
    static var archiveEnabled: Bool {
        get { defaults.object(forKey: Key.archiveEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.archiveEnabled) }
    }

    /// Whether the usage journal records each poll to an append-only JSONL file (#242). **Default-off**
    /// (opt-in): an absent key reads as `false`, so nothing is written until the user turns it on. The
    /// journal stores percentages/amounts (not transcripts), so its privacy surface is lighter than the
    /// archiver's — but writing to disk without asking is a habit we don't start. `object(forKey:) as?
    /// Bool ?? false` distinguishes "unset" from an explicit choice, like the other opt-in toggles.
    static var journalEnabled: Bool {
        get { defaults.object(forKey: Key.journalEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.journalEnabled) }
    }

    /// The user's subscription to the current status-page episode (#279), or the empty state when
    /// they are not following anything.
    ///
    /// Persisted rather than held in memory because incidents run for hours — the live measurement
    /// was 429 minutes — so a subscription that did not survive a relaunch would routinely be lost
    /// mid-outage, which is precisely when it matters. A JSON blob for the same reason
    /// ``monitoredServices`` is one: it is a small record with sub-state, and a decode failure
    /// degrades to "not following" rather than corrupting anything.
    static var episodeSubscription: EpisodeSubscription {
        get {
            guard let data = defaults.data(forKey: Key.episodeSubscription),
                  let decoded = try? JSONDecoder().decode(EpisodeSubscription.self, from: data)
            else { return .none }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.episodeSubscription)
        }
    }

    /// The weekly-utilization reconstruction state (#386): the rolling estimate of the 5h↔7d
    /// exchange rate plus the accumulation since the last observed weekly bump.
    ///
    /// Persisted rather than held in memory because the ratio window takes **~20 h of active work**
    /// to fill (measured: 5 segments in 1.9 h, 15 in 20.2 h). An in-memory-only estimate would reset
    /// on every relaunch — and with 61 polling gaps observed over 13 days, that is often — so the
    /// feature would spend much of its life cold. That is the same reasoning as
    /// ``episodeSubscription``: a small record whose value is precisely that it survives a restart.
    ///
    /// A JSON blob for the same reason ``monitoredServices`` is one, and a decode failure degrades
    /// to a fresh estimator (the reconstruction reseeds and warms up again) rather than corrupting
    /// anything. **Not** stored in the usage journal: that is default-off, and reading it back would
    /// mean parsing 4.6 MB at launch to recover ~15 numbers.
    ///
    /// What survives a long break is decided by ``WeeklyInterpolator/resumed(at:)``, not here: the
    /// ratio always, the accumulation only if the break was short.
    static var weeklyInterpolator: WeeklyInterpolator {
        get {
            guard let data = defaults.data(forKey: Key.weeklyInterpolator),
                  let decoded = try? JSONDecoder().decode(WeeklyInterpolator.self, from: data)
            else { return WeeklyInterpolator() }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.weeklyInterpolator)
        }
    }

    /// ``weeklyInterpolator`` read from the polling engine's own task, which is not main-actor
    /// isolated — the same `nonisolated` escape hatch (and the same key) as
    /// ``usageApiEnabledUnsafe()``. A missing or unreadable blob degrades to a fresh estimator.
    nonisolated static func weeklyInterpolatorUnsafe() -> WeeklyInterpolator {
        guard let data = UserDefaults.standard.data(forKey: Key.weeklyInterpolator),
              let decoded = try? JSONDecoder().decode(WeeklyInterpolator.self, from: data)
        else { return WeeklyInterpolator() }
        return decoded
    }

    /// The write half of ``weeklyInterpolatorUnsafe()``, called once per poll that moves the state.
    /// Failure is silent: losing a persisted estimate costs a warm-up, never correctness.
    nonisolated static func setWeeklyInterpolatorUnsafe(_ value: WeeklyInterpolator) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: Key.weeklyInterpolator)
    }

    /// The last `seven_day.resets_at` the **server** sent — the anchor the decoder rolls forward
    /// while the API withholds one (ADR-0106).
    ///
    /// Persisted because the blackout it covers lasts 4-6 hours and the app restarts inside it: the
    /// journal shows five polling gaps within one 2026-08-04 blackout, the longest 104 minutes. An
    /// in-memory-only anchor would be gone exactly when it is needed, and the app would fall back to
    /// the honest but useless "reset time unknown".
    ///
    /// Stored as the **ISO-8601 string**, not an epoch number or a JSON blob: it round-trips through
    /// the same ``ResetClock/parse(_:)`` / `isoString` pair as every other date in the app, and it
    /// stays readable in `defaults read` — which matters for a value worth inspecting mid-blackout.
    /// There is no structure here to justify a blob.
    static var lastSevenDayReset: Date? {
        get {
            defaults.string(forKey: Key.lastSevenDayReset).flatMap(ResetClock.parse)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.lastSevenDayReset)
                return
            }
            defaults.set(ResetClock.isoString(from: newValue), forKey: Key.lastSevenDayReset)
        }
    }

    /// ``lastSevenDayReset`` read from the polling engine's own task, which is not main-actor
    /// isolated — the same `nonisolated` escape hatch (and the same key) as
    /// ``weeklyInterpolatorUnsafe()``. An absent or unparseable value degrades to `nil`, which is
    /// the cold-start path: nothing is reconstructed and the UI says the reset time is unknown.
    nonisolated static func lastSevenDayResetUnsafe() -> Date? {
        UserDefaults.standard.string(forKey: Key.lastSevenDayReset).flatMap(ResetClock.parse)
    }

    /// The write half of ``lastSevenDayResetUnsafe()``, called only when the value actually changes
    /// — roughly once a week, against ~480 polls a day. Failure is silent for the same reason as the
    /// interpolator's: losing the anchor costs a reconstruction, never correctness.
    nonisolated static func setLastSevenDayResetUnsafe(_ value: Date) {
        UserDefaults.standard.set(ResetClock.isoString(from: value), forKey: Key.lastSevenDayReset)
    }

    /// Hide incidents older than this (#279, ADR-0071 §9), or `nil` for no limit.
    ///
    /// Exists because the page keeps "zombies" open for days — the sample held one for 2741 minutes —
    /// and a two-day-old incident says nothing about whether work is possible right now. Stored in
    /// hours; `0` means no limit, so an unset key reads as "no limit" rather than "hide everything".
    static var incidentMaxAge: TimeInterval? {
        get {
            let hours = defaults.object(forKey: Key.incidentMaxAgeHours) as? Int ?? 0
            return hours > 0 ? TimeInterval(hours) * 3600 : nil
        }
        set {
            let hours = newValue.map { Int(($0 / 3600).rounded()) } ?? 0
            defaults.set(hours, forKey: Key.incidentMaxAgeHours)
        }
    }

    /// Whether raw `status.claude.com` payloads are recorded to a dev-only JSONL when their material
    /// content changes (#279, ADR-0071 §10). **Default-off**, and reachable only from Development
    /// tools (⌥ + `devToolsEnabled`) — it exists to answer the ADR's deliberately-open questions from
    /// real traffic, not as a user-facing feature. The payloads are public data, but writing to disk
    /// without asking is a habit we don't start (same reasoning as ``journalEnabled``).
    static var statusPayloadLogEnabled: Bool {
        get { defaults.object(forKey: Key.statusPayloadLogEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.statusPayloadLogEnabled) }
    }

    /// The Settings window's last frame as `[x, y, width, height]` in screen coordinates (ADR-0069),
    /// or `nil` when nothing usable is stored. Plain `Double`s rather than `NSStringFromRect` so this
    /// file stays AppKit-free (it is Foundation + kit only), and so a hand-edited or truncated value
    /// is rejected here rather than decoded into a garbage rect.
    ///
    /// The window is the only geometry we persist, and unlike every other key here it describes
    /// *system* state rather than a preference (ADR-0023 draws that line). It earns its place because
    /// the value must be **validated before it is applied** — `WindowFrameValidator` checks it against
    /// the live screen layout — and `setFrameAutosaveName` restores a frame before any such check can
    /// run. That is exactly the failure ADR-0035 removed autosave over.
    static var settingsWindowFrame: [Double]? {
        get {
            guard let raw = defaults.array(forKey: Key.settingsWindowFrame) as? [Double],
                  raw.count == 4 else { return nil }
            return raw
        }
        set {
            if let newValue, newValue.count == 4 {
                defaults.set(newValue, forKey: Key.settingsWindowFrame)
            } else {
                defaults.removeObject(forKey: Key.settingsWindowFrame)
            }
        }
    }

    /// Whether the menu-bar / popup "sessions awaiting input" indicator is shown (#233, ADR-0066).
    /// **Default-off** (opt-in): an absent key reads as `false`, so nothing is watched or drawn until
    /// the user turns it on. Master toggle in Settings → General; the indicator's placement is
    /// configured in Settings → Appearance (and is meaningful only while this is on). Gates whether
    /// the ``AwaitingInputWatcher`` runs at all. `object(forKey:) as? Bool ?? false` distinguishes
    /// "unset" from an explicit choice, consistent with the other opt-in toggles.
    static var awaitingInputEnabled: Bool {
        get { defaults.object(forKey: Key.awaitingInputEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.awaitingInputEnabled) }
    }

    /// Filesystem path of the archive folder the user chose (#110), or `nil` if none picked yet.
    /// Stored as a plain path (no security-scoped bookmark: the app is not sandboxed — ADR-0030).
    /// The archiver stays inert while this is `nil` even when ``archiveEnabled`` is `true`.
    static var archiveDestination: String? {
        get { defaults.string(forKey: Key.archiveDestination) }
        set { defaults.set(newValue, forKey: Key.archiveDestination) }
    }

    /// Instant of the last **successful** archive sync (#110), or `nil` if none yet. Advanced only on
    /// success, so a failed sync (unwritable destination) stays due and retries next heartbeat
    /// (`ArchiveCadence`). Drives the "Last archived …" status line in Settings.
    static var lastArchiveSync: Date? {
        get { defaults.object(forKey: Key.lastArchiveSync) as? Date }
        set { defaults.set(newValue, forKey: Key.lastArchiveSync) }
    }

    // MARK: - Back-to-work notification (#160)

    /// Whether the "Back to work!" notification fires when a usage limit becomes usable again (#160).
    /// **Default-off** (opt-in): an absent key reads as `false`, so nothing is ever posted until the
    /// user turns it on (and grants notification authorization). `object(forKey:) as? Bool ?? false`
    /// distinguishes "unset" from an explicit choice, consistent with the other opt-in toggles.
    static var backToWorkEnabled: Bool {
        get { defaults.object(forKey: Key.backToWorkEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.backToWorkEnabled) }
    }

    /// Start of the allowed-notification window (#160), as minute-of-day `0…1439` in local wall-clock
    /// time. **Default 480 (08:00).** Clamped to the valid range on read so a corrupt value can never
    /// feed an out-of-range minute into `NotificationSchedule`. The Settings time picker is display
    /// only — the stored form is this Int (see the Notifications pane).
    static var notifyWindowStartMinute: Int {
        get { min(1439, max(0, defaults.object(forKey: Key.notifyWindowStartMinute) as? Int ?? 480)) }
        set { defaults.set(newValue, forKey: Key.notifyWindowStartMinute) }
    }

    /// End of the allowed-notification window (#160), as minute-of-day `0…1439` local time.
    /// **Default 1020 (17:00).** A value ≤ the start makes the window wrap across midnight; equal
    /// endpoints mean the whole day (see ``NotificationSchedule``). Clamped on read like the start.
    static var notifyWindowEndMinute: Int {
        get { min(1439, max(0, defaults.object(forKey: Key.notifyWindowEndMinute) as? Int ?? 1020)) }
        set { defaults.set(newValue, forKey: Key.notifyWindowEndMinute) }
    }

    /// Which weekday pair the "Back to work!" notification is suppressed on (#160). **Default
    /// `.never`.** Stored as the raw `SuppressDays` string with a forward-compatible decode (an
    /// unknown raw reads as `.never`), mirroring ``resetCountdownModeMenuBar``.
    static var notifySuppressDays: SuppressDays {
        get { SuppressDays(rawValue: defaults.string(forKey: Key.notifySuppressDays) ?? "") ?? .never }
        set { defaults.set(newValue.rawValue, forKey: Key.notifySuppressDays) }
    }

    /// Persisted "was blocked" edge state for the "Back to work!" notification (#160). **Default
    /// false.** This is **internal state, not a user setting** — it is not shown in Settings.
    ///
    /// It must be persisted (not an in-memory flag) so the blocked→unblocked edge survives an app
    /// restart or a Mac sleep/reboot between the block and the reset: on the first successful poll
    /// after relaunch, a still-`true` value plus a now-workable snapshot is a genuine edge that fires
    /// the notification. It is updated **every** successful poll regardless of ``backToWorkEnabled``
    /// (so toggling the feature off→on never forgets a pending edge, and never fires a stale one for a
    /// reset that happened while the feature was off); the toggle gates only the posting.
    static var backToWorkWasBlocked: Bool {
        get { defaults.object(forKey: Key.backToWorkWasBlocked) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.backToWorkWasBlocked) }
    }

    // MARK: - Extra Usage Credit notification

    /// Whether the "Now using Extra Usage Credit" notification fires when work starts overflowing onto
    /// paid credit (a plan limit is spent and credits begin covering). **Default-off** (opt-in): an
    /// absent key reads as `false`, so nothing is ever posted until the user turns it on (and grants
    /// notification authorization), consistent with ``backToWorkEnabled``. Gated by the same
    /// authorization + quiet-hours machinery.
    static var extraUsageNotifyEnabled: Bool {
        get { defaults.object(forKey: Key.extraUsageNotifyEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.extraUsageNotifyEnabled) }
    }

    /// Persisted "was on credits" edge state for the Extra Usage notification. **Default false.**
    /// **Internal state, not a user setting** — mirrors ``backToWorkWasBlocked``.
    ///
    /// Persisted (not in-memory) so the not-spending→spending edge survives an app restart or a Mac
    /// sleep between polls, and updated on **every** successful poll regardless of
    /// ``extraUsageNotifyEnabled`` (so toggling off→on never forgets a pending edge, and never fires a
    /// stale one for a switch that happened while the feature was off); the toggle gates only the posting.
    static var extraUsageWasOnCredits: Bool {
        get { defaults.object(forKey: Key.extraUsageWasOnCredits) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.extraUsageWasOnCredits) }
    }

    /// Whether the ⌥-revealed "Development tools…" menu item and its live colour tuner (#185) are
    /// unlocked. **Default-off** (opt-in): an absent key reads as `false`, so a normal launch never
    /// exposes the dev tools. `object(forKey:) as? Bool ?? false` distinguishes "unset" from an
    /// explicit `false`, consistent with the other opt-in toggles. Set it on the installed `.app` with
    /// `defaults write com.artem-n.tokenpace devToolsEnabled -bool true` — this is a maintainer/dev
    /// switch with no Settings UI (the menu item stays ⌥-gated on top of this flag).
    static var devToolsEnabled: Bool {
        get { defaults.object(forKey: Key.devToolsEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.devToolsEnabled) }
    }
}
