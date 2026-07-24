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
        /// Whether the daily update check runs (#37). Default-on (opt-out) — see the property.
        static let automaticUpdateChecks = "automaticUpdateChecks"
        /// Instant of the last update-check **attempt** (#37), gating the 24 h cadence.
        static let lastUpdateCheck = "lastUpdateCheck"
        /// The latest release tag last surfaced to the user (#37), so the same version is not
        /// notified twice.
        static let lastSeenLatestVersion = "lastSeenLatestVersion"
        /// Whether the menu-bar widget mutes its soft pacing colours to white (#105). Default-off
        /// (opt-in) — see the property.
        static let calmMenuBarColors = "calmMenuBarColors"
        /// How the menu-bar widget picks/hides the reset countdown (#103), stored as the raw
        /// `ResetCountdownMode` string. Default `.showDistant7d` — see the property.
        static let resetCountdownModeMenuBar = "resetCountdownModeMenuBar"
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

    /// Whether TokenPace checks GitHub Releases for a newer version once a day (#37). **Default-on**
    /// (opt-out): an absent key reads as `true`. `object(forKey:) as? Bool ?? true` distinguishes
    /// "unset" (→ true) from an explicit `false` the user chose — `bool(forKey:)` would collapse both
    /// to `false` and silently defeat the opt-out default.
    static var automaticUpdateChecks: Bool {
        get { defaults.object(forKey: Key.automaticUpdateChecks) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.automaticUpdateChecks) }
    }

    /// Instant of the last update-check **attempt** (success or graceful failure), or `nil` if none
    /// has run yet. Advanced on every attempt so a private-repo 404 does not retry each heartbeat —
    /// the 24 h gate is on the *attempt*, not the *success* (`UpdateCheckCadence`, ADR-0025).
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
    /// blue track, the on-pace green, and the mild ahead-of-pace yellow. **Default-off** (opt-in):
    /// an absent key reads as `false`, so the vivid statusline colours are the out-of-the-box look.
    /// `object(forKey:) as? Bool ?? false` distinguishes "unset" (→ false) from an explicit choice.
    /// The strong warnings (orange/red), the time-indicator dot, the service-status dot, and the
    /// error triangle are unaffected; the popup keeps its full colour too.
    static var calmMenuBarColors: Bool {
        get { defaults.object(forKey: Key.calmMenuBarColors) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.calmMenuBarColors) }
    }

    /// How the **menu-bar** widget picks or hides the reset countdown (#103, ADR-0029). Named for the
    /// menu bar specifically because the popup has its own countdown logic. Stored as the raw
    /// `ResetCountdownMode` string; an absent key or an unrecognised value (e.g. one a newer build
    /// wrote) reads as the default ``ResetCountdownMode/showDistant7d`` — same forward-compatible
    /// fallback the type's own decoder uses, so an older build never trips on a future value.
    static var resetCountdownModeMenuBar: ResetCountdownMode {
        get { ResetCountdownMode(rawValue: defaults.string(forKey: Key.resetCountdownModeMenuBar) ?? "") ?? .showDistant7d }
        set { defaults.set(newValue.rawValue, forKey: Key.resetCountdownModeMenuBar) }
    }
}
