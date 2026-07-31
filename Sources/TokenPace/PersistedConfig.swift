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
        /// Instant of the last update-check **attempt** (#37), gating the 12 h cadence.
        static let lastUpdateCheck = "lastUpdateCheck"
        /// The latest release tag last surfaced to the user (#37), so the same version is not
        /// notified twice.
        static let lastSeenLatestVersion = "lastSeenLatestVersion"
        /// Whether the menu-bar widget mutes its soft pacing colours to white (#105). Default-off
        /// (opt-in) — see the property.
        static let calmMenuBarColors = "calmMenuBarColors"
        /// How the menu-bar widget picks/hides the reset countdown (#103), stored as the raw
        /// `ResetCountdownMode` string. Default `.smart` — see the property.
        static let resetCountdownModeMenuBar = "resetCountdownModeMenuBar"
        /// Whether the menu-bar widget draws the service-status dot on a service issue (#31).
        /// Default-on (opt-out) — see the property.
        static let showServiceStatusDot = "showServiceStatusDot"
        /// Whether the menu-bar widget hides the 7-day bar while it is calm (green/yellow),
        /// centring the 5h bar alone (#94). Default-on (opt-out) — see the property.
        static let hideCalmSevenDayBar = "hideCalmSevenDayBar"
        /// Whether the menu-bar widget hides *both* pacing bars while a main window is exhausted
        /// (blocked), leaving only the reset countdown (#194). Default-on (opt-out) — see the property.
        static let hideBarsWhenBlocked = "hideBarsWhenBlocked"
        /// Whether the menu-bar widget draws the orange "pause" glyph to the left of the bars when the
        /// user is fully blocked (`CreditsPacing.isBlocked`) and the bars are kept visible (#199).
        /// Default-on (opt-out) — see the property.
        static let showBlockedPause = "showBlockedPause"
        /// Whether the menu-bar widget draws the money-credits ("extra usage") icon when credits are
        /// active and a base limit is exhausted (#144). Default-on (opt-out) — see the property.
        static let showExtraUsage = "showExtraUsage"
        /// Whether polling pauses while the screen is locked / off / running a screensaver (#114).
        /// Default-on (opt-out) — see the property.
        static let pausePollingWhenScreenLocked = "pausePollingWhenScreenLocked"
        /// Whether the session-log archiver runs (#110). Default-off (opt-in) — see the property.
        static let archiveEnabled = "archiveEnabled"
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

    /// Whether the menu-bar widget renders its **soft** pacing colours as white (#105) — the idle
    /// blue track, the on-pace green, and the mild ahead-of-pace yellow. **Default-on** (opt-out, #168):
    /// an absent key reads as `true`, so the calm/non-critical look is the out-of-the-box default.
    /// `object(forKey:) as? Bool ?? true` distinguishes "unset" (→ true) from an explicit choice.
    /// The strong warnings (orange/red), the time-indicator dot, the service-status dot, and the
    /// error triangle are unaffected; the popup keeps its full colour too.
    static var calmMenuBarColors: Bool {
        get { defaults.object(forKey: Key.calmMenuBarColors) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.calmMenuBarColors) }
    }

    /// How the **menu-bar** widget picks or hides the reset countdown (#103, ADR-0029). Named for the
    /// menu bar specifically because the popup has its own countdown logic. Stored as the raw
    /// `ResetCountdownMode` string; an absent key or an unrecognised value (a newer build's value, or a
    /// legacy `show_distant_7d`/`hide_distant_7d` from before #168) reads as the default
    /// ``ResetCountdownMode/smart`` — so an older build never trips on a future value.
    static var resetCountdownModeMenuBar: ResetCountdownMode {
        get { ResetCountdownMode(rawValue: defaults.string(forKey: Key.resetCountdownModeMenuBar) ?? "") ?? .smart }
        set { defaults.set(newValue.rawValue, forKey: Key.resetCountdownModeMenuBar) }
    }

    /// Whether the **menu-bar** widget draws the service-status dot when a monitored service has a
    /// non-operational issue (#31). **Default-on** (opt-out): an absent key reads as `true`, so the
    /// dot shows out of the box. `object(forKey:) as? Bool ?? true` distinguishes "unset" (→ true)
    /// from an explicit `false` the user chose — `bool(forKey:)` would collapse both to `false` and
    /// silently defeat the opt-out default. Menu-bar only: the popup's service-status rows are
    /// unaffected.
    static var showServiceStatusDot: Bool {
        get { defaults.object(forKey: Key.showServiceStatusDot) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showServiceStatusDot) }
    }

    /// Whether the **menu-bar** widget hides the **7-day** bar while it is calm — green (on pace or
    /// behind) or mild-ahead yellow (`BarView.isCalm`) — leaving the 5h bar as the single, vertically
    /// centred bar (#94). **Default-on** (opt-out): an absent key reads as `true`, so the quieter
    /// single-bar look is the out-of-the-box behaviour. `object(forKey:) as? Bool ?? true`
    /// distinguishes "unset" (→ true) from an explicit `false` the user chose — `bool(forKey:)` would
    /// collapse both to `false` and silently defeat the opt-out default. An **orange/red** 7-day bar
    /// always stays visible; the error state (⚠️ + stale bars, #12) is unaffected — the 7-day bar is
    /// kept there for diagnostics regardless of this toggle.
    static var hideCalmSevenDayBar: Bool {
        get { defaults.object(forKey: Key.hideCalmSevenDayBar) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.hideCalmSevenDayBar) }
    }

    /// Whether the **menu-bar** widget hides **both** pacing bars while the user is *blocked* — a main
    /// window (5h or 7d) is exhausted (`CreditsPacing.mainWindowExhausted`, credits coverage ignored) —
    /// leaving only the reset countdown (#194, `MenuBarMode.blockedReset`). **Default-on** (opt-out): an
    /// absent key reads as `true`, because a red 100 % bar carries no pacing information — the actionable
    /// signal is the time until the block clears. `object(forKey:) as? Bool ?? true` distinguishes
    /// "unset" (→ true) from an explicit `false` the user chose — `bool(forKey:)` would collapse both to
    /// `false` and silently defeat the opt-out default. Menu-bar only: the popup keeps its full bars.
    static var hideBarsWhenBlocked: Bool {
        get { defaults.object(forKey: Key.hideBarsWhenBlocked) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.hideBarsWhenBlocked) }
    }

    /// Whether the **menu-bar** widget draws the orange "pause" glyph as the **leading** element while
    /// the user is *fully blocked* — every limit exhausted **and** paid credits can't cover
    /// (`CreditsPacing.isBlocked`), so there is no path to work (#199). **Default-on** (opt-out): an
    /// absent key reads as `true`. **Independent** of the "Show pacing bars when 5h/7d limits reached"
    /// toggle: the glyph is drawn left of the bars when they are kept, and left of the countdown in the
    /// bars-less `.blockedReset` mode. `object(forKey:) as? Bool ?? true` distinguishes "unset" (→ true)
    /// from an explicit `false` the user chose. Menu-bar only.
    static var showBlockedPause: Bool {
        get { defaults.object(forKey: Key.showBlockedPause) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showBlockedPause) }
    }

    /// Whether the **menu-bar** widget draws the money-credits ("extra usage") icon — the trailing
    /// currency glyph (¤) shown when paid credits are active **and** a base limit is exhausted (#144,
    /// `MenuBarLayout.creditsMarker`). **Default-on** (opt-out): an absent key reads as `true`, so the
    /// icon appears out of the box, matching the service-status dot's default. `object(forKey:) as?
    /// Bool ?? true` distinguishes "unset" (→ true) from an explicit `false` the user chose —
    /// `bool(forKey:)` would collapse both to `false` and silently defeat the opt-out default.
    ///
    /// - Note: The Settings toggle for this lives in #146; until then the gate is read from this
    ///   default-on property, so the icon is on for everyone with credits.
    static var showExtraUsage: Bool {
        get { defaults.object(forKey: Key.showExtraUsage) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showExtraUsage) }
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
}
