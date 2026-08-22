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

    public init(developmentServicesEnabled: Bool = true) {
        self.developmentServicesEnabled = developmentServicesEnabled
    }

    /// The default: **on**, like every other monitoring flag in the app.
    ///
    /// It shipped opt-in first, on the reasoning that a provider appearing on upgrade should wait to
    /// be asked. In practice the people running TokenPace are running it beside `gh` and a browser
    /// full of pull requests, so the provider that has to be discovered in Settings is the one that
    /// never gets turned on — and a monitor nobody enabled reports nothing, which is the same as not
    /// shipping it.
    ///
    /// The cost is named rather than waved away: an existing install gains a plate in the dropdown
    /// and, during a GitHub incident, a dot in the menu bar without having asked for either. That is
    /// a behaviour change, and it belongs in the release notes. An explicit `false` already in
    /// `UserDefaults` still wins — this default only decides what an **absent** key means, so nobody
    /// who has turned it off gets it back.
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
