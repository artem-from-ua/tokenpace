import Foundation

// MARK: - StatusComponent

/// One entry of the `components[]` array from `GET https://status.claude.com/api/v2/summary.json`
/// (Statuspage.io summary format).
///
/// `status` is the **raw** API string — `operational`, `degraded_performance`, `partial_outage`,
/// `major_outage`, or `under_maintenance`. It is deliberately **not** mapped to a semantic enum
/// here: that mapping lives in exactly one place, ``ServiceStatus/init(rawAPIValue:)``, so this
/// layer stays a thin, allocation-free decode (mirrors how ``UsageWindow`` forwards its raw
/// `resets_at` string to ``ResetClock``).
///
/// Statuspage emits many more per-component keys (`id`, `position`, `group_id`, `showcase`, …);
/// `Decodable` ignores unknown keys, so they are tolerated without any work.
public struct StatusComponent: Sendable, Equatable, Decodable {
    /// Human-readable component name, matched verbatim against the two we care about
    /// (`"Claude Code"`, `"Claude API (api.anthropic.com)"`) in ``StatusHealth/from(_:)``.
    public let name: String
    /// Raw Statuspage status string, forwarded verbatim to ``ServiceStatus/init(rawAPIValue:)``.
    public let status: String

    public init(name: String, status: String) {
        self.name = name
        self.status = status
    }
}

// MARK: - StatusSummary

/// Decoded, immutable result of one successful poll of the Claude status page.
///
/// Only `components[]` is modeled. The endpoint also carries `status` (overall indicator),
/// `incidents[]`, `scheduled_maintenances[]`, and `page` — all **intentionally not decoded**
/// (ADR-0013): the popup's status lines are driven **solely** by the per-component `status`,
/// which matches the colour Statuspage shows next to each component and automatically ignores
/// "known exceptions" (e.g. a `major` incident that suspends a model while both components stay
/// `operational`). `Decodable` drops the unmodeled keys for free.
///
/// The custom ``init(from:)`` hardens `components`: an omitted array decodes to `[]` rather than
/// failing the whole summary (mirrors ``UsageSnapshot``'s handling of `limits`). The memberwise
/// initializer is kept so tests can build fixtures directly.
public struct StatusSummary: Sendable, Equatable, Decodable {
    public let components: [StatusComponent]

    private enum CodingKeys: String, CodingKey {
        case components
    }

    public init(components: [StatusComponent]) {
        self.components = components
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An omitted/`null` `components` array decodes to `[]` instead of failing — a malformed
        // summary then yields two `.unknown` lines (honest "don't know") rather than a hard error.
        self.components = try container.decodeIfPresent([StatusComponent].self, forKey: .components) ?? []
    }
}
