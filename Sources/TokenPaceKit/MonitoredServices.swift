import Foundation

// MARK: - WebDesktopMode

/// The mode of the "Claude WEB/Desktop" logical service (#89): whether to include the
/// `Claude Cowork` component in its worst-of-N alongside `claude.ai`.
///
/// The raw values are stable snake-case strings **on purpose** — they are persisted in
/// `UserDefaults` as JSON (via `MonitoredServices`), so a readable, reorder-proof key survives a
/// config migration, exactly like the reasoning behind `ServiceStatus.init(rawAPIValue:)`. A
/// forward-compatible `init(from:)` maps an unknown raw string (a future mode, or a corrupted
/// default) to `.chatOnly` rather than throwing — the same "the config can grow, we don't break"
/// philosophy as `ServiceStatus.unknown`.
public enum WebDesktopMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// Monitor only `claude.ai` (the default).
    case chatOnly = "chat_only"
    /// Monitor `claude.ai` **and** `Claude Cowork` — worst-of-two.
    case chatAndCowork = "chat_and_cowork"

    /// Forward-compatible decode: an unrecognised raw string (a mode a future build wrote, or a
    /// corrupted default) falls back to `.chatOnly` instead of throwing, so a newer config never
    /// makes an older build fail to launch. Mirrors `ServiceStatus`'s unknown-bucket philosophy.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WebDesktopMode(rawValue: raw) ?? .chatOnly
    }
}

// MARK: - MonitoredServices

/// The user's choice of which Claude status-page services to monitor (#89) — the persisted config
/// that replaces the previously hard-coded set of components.
///
/// `Claude API (api.anthropic.com)` is deliberately **not** represented here: it is always monitored
/// and not user-configurable (TokenPace's own ability to call the usage API depends on it), so there
/// is no flag to store. This type carries only the two toggleable logical services plus the
/// WEB/Desktop mode.
///
/// `Codable` because it is persisted in `UserDefaults` as JSON (the `TokenPace` shell owns the
/// read/write via `PersistedConfig`; this layer only defines the shape). The custom ``init(from:)``
/// hardens each key with `decodeIfPresent` + the default, so a partial or older JSON blob (a build
/// that stored fewer keys) decodes to sensible defaults rather than failing — mirrors
/// ``StatusSummary``. `Sendable`/`Equatable` so the shell can compare "did the config change" and
/// hand it across actors safely.
public struct MonitoredServices: Sendable, Equatable, Codable {
    /// The "Claude Code" logical service (= the `Claude Code` component). Default: on.
    public var claudeCodeEnabled: Bool
    /// The "Claude WEB/Desktop" logical service (= `claude.ai`, plus `Claude Cowork` in
    /// ``WebDesktopMode/chatAndCowork``). Default: on.
    public var webDesktopEnabled: Bool
    /// Whether WEB/Desktop also monitors `Claude Cowork`. Default: ``WebDesktopMode/chatOnly``.
    /// Only meaningful while ``webDesktopEnabled`` is true (the radio is disabled otherwise in the UI).
    public var webDesktopMode: WebDesktopMode

    public init(
        claudeCodeEnabled: Bool = true,
        webDesktopEnabled: Bool = true,
        webDesktopMode: WebDesktopMode = .chatOnly
    ) {
        self.claudeCodeEnabled = claudeCodeEnabled
        self.webDesktopEnabled = webDesktopEnabled
        self.webDesktopMode = webDesktopMode
    }

    /// The default for a first run / an absent `UserDefaults` key: both toggleable services on,
    /// WEB/Desktop in "Chat only" — the same set the app monitored before it was configurable.
    public static let `default` = MonitoredServices()

    private enum CodingKeys: String, CodingKey {
        case claudeCodeEnabled
        case webDesktopEnabled
        case webDesktopMode
    }

    /// Decode each key defensively: an omitted key (an older blob that predates it) takes the
    /// default rather than failing the whole config, so a forward/backward schema change never
    /// bricks the stored settings. Mirrors ``StatusSummary/init(from:)``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = MonitoredServices.default
        self.claudeCodeEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .claudeCodeEnabled) ?? d.claudeCodeEnabled
        self.webDesktopEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .webDesktopEnabled) ?? d.webDesktopEnabled
        self.webDesktopMode =
            try container.decodeIfPresent(WebDesktopMode.self, forKey: .webDesktopMode) ?? d.webDesktopMode
    }
}
