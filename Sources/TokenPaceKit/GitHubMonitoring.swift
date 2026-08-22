import Foundation

// MARK: - GitHubMonitoring

/// What TokenPace watches for the **GitHub** provider (#454) — today a single logical service,
/// `Development services`.
///
/// Deliberately a struct with one flag rather than a bare `Bool` in `PersistedConfig`. Config types
/// here grow: `MonitoredServices` began as two flags and gained `webDesktopMode` later, and #454
/// already names a plausible next member (a `Copilot services` group for people who use it). A
/// struct absorbs that as a new key with a default; a bare `Bool` would force a second, unrelated
/// key beside it and leave the two to drift.
///
/// It is a **separate** persisted key from `monitoredServices`, never folded into that blob — the
/// same rule `ProviderMonitoring` states for the usage flag: an older build that rewrites the blob
/// knows nothing of this provider and would silently erase the user's choice. Two keys survive a
/// downgrade; one blob does not.
///
/// There is no provider-level master switch and no derived lock. With one service the switch **is**
/// the provider, and nothing here underpins anything else the way `Claude API` underpins the Claude
/// services (`ProviderMonitoring.claudeApiLocked`).
public struct GitHubMonitoring: Sendable, Equatable, Codable {
    /// Whether the `Development services` group is monitored — `Git Operations`, `API Requests`,
    /// `Issues`, `Pull Requests`, `Actions`, aggregated worst-of-5.
    public var developmentServicesEnabled: Bool

    public init(developmentServicesEnabled: Bool = false) {
        self.developmentServicesEnabled = developmentServicesEnabled
    }

    /// The first-run default: **off**. Unlike every other monitoring flag in the app, which is
    /// opt-out, a provider added to an existing install is opt-in — not everyone using TokenPace
    /// works against GitHub, and switching on a new status dot in someone's menu bar without being
    /// asked is a behaviour change, not a feature.
    public static let `default` = GitHubMonitoring()

    /// Whether this provider contributes anything at all.
    public var isMonitoringAnything: Bool { developmentServicesEnabled }

    private enum CodingKeys: String, CodingKey {
        case developmentServicesEnabled
    }

    /// Decode defensively, mirroring ``MonitoredServices/init(from:)``: an omitted key takes the
    /// default rather than failing the whole config, so a blob written by a build that predates a
    /// future key still loads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = GitHubMonitoring.default
        self.developmentServicesEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .developmentServicesEnabled)
            ?? d.developmentServicesEnabled
    }
}
