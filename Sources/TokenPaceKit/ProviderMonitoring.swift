import Foundation

// MARK: - ProviderMonitoring

/// Everything TokenPace monitors for one provider (#341): the usage collection and the status-page
/// services, kept as two separate things rather than one "provider is on" flag.
///
/// The distinction is the whole point of the type. ``usageApiEnabled`` gates the `GET
/// /api/oauth/usage` poll — the data that feeds the bars. ``MonitoredServices`` gates which
/// status-page components are watched for incidents. They are independent subsystems: the services
/// can be monitored with the usage poll off (the menu bar then reports service health only), and the
/// usage poll works with every service switched off.
///
/// This is a **composite, not a merge**: ``services`` is stored verbatim, and its own docblock stays
/// true ("which Claude status-page services to monitor"). Folding the usage flag into that struct
/// would reproduce, one level down, exactly the conflation #341 exists to undo.
///
/// The two halves persist under **separate** `UserDefaults` keys (`PersistedConfig`), so an older
/// build that only knows `monitoredServices` cannot silently erase the usage choice by rewriting a
/// shared blob.
public struct ProviderMonitoring: Sendable, Equatable, Codable {
    /// Whether to poll the usage API — the data behind the bars. Default: on.
    public var usageApiEnabled: Bool
    /// Which status-page services to monitor. Unchanged by this type; see ``MonitoredServices``.
    public var services: MonitoredServices

    public init(usageApiEnabled: Bool = true, services: MonitoredServices = .default) {
        self.usageApiEnabled = usageApiEnabled
        self.services = services
    }

    /// The default for a first run: usage polling on, both toggleable services on — the behaviour the
    /// app had before any of this was configurable.
    public static let `default` = ProviderMonitoring()

    /// Whether the `Claude API` service is forced on and locked in the UI.
    ///
    /// **Computed on purpose, never stored.** `Claude API (api.anthropic.com)` underpins both halves:
    /// the usage poll talks to it directly, and a Claude Code / WEB outage is unreadable without
    /// knowing whether the API itself is up. So enabling *anything* implies monitoring it, and the
    /// only state where it is free to be off is the one where nothing else is on — where it is also
    /// pointless.
    ///
    /// Deriving it removes the impossible state at the root: there is no second copy to fall out of
    /// sync, no normalisation needed in `init(from:)`, and the memberwise `init` cannot construct a
    /// forbidden combination.
    public var claudeApiLocked: Bool {
        usageApiEnabled || services.claudeCodeEnabled || services.webDesktopEnabled
    }

    /// Whether TokenPace monitors anything at all. `false` is a legitimate user choice (#341) and the
    /// menu bar reports it with its own state rather than an error — nothing is broken, the user
    /// turned it off.
    public var isMonitoringAnything: Bool { claudeApiLocked }

    private enum CodingKeys: String, CodingKey {
        case usageApiEnabled
        case services
    }

    /// Decode defensively, mirroring ``MonitoredServices/init(from:)``: an omitted key takes the
    /// default rather than failing the whole config, so a blob written by a build that predates one
    /// of these keys still loads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProviderMonitoring.default
        self.usageApiEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .usageApiEnabled) ?? d.usageApiEnabled
        self.services =
            try container.decodeIfPresent(MonitoredServices.self, forKey: .services) ?? d.services
    }
}
