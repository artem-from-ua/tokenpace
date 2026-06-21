import Foundation

// MARK: - UsageWindow

/// One rolling-limit window from `GET /api/oauth/usage` — `five_hour`, `seven_day`,
/// `seven_day_opus`, or `seven_day_sonnet`. All four share this shape.
///
/// `resetsAt` is the **raw** API string (ISO-8601 with microseconds and a `+00:00`
/// offset, e.g. `2026-06-21T05:30:00.619428+00:00`). It is deliberately **not** parsed
/// here: date normalization lives in exactly one place, ``ResetClock/parse(_:)`` (#7),
/// so this layer stays a thin, allocation-free decode. Callers forward the string to
/// `ResetClock.parse` when they need a `Date`.
public struct UsageWindow: Sendable, Equatable, Decodable {
    /// `utilization` — percent in `[0, 100]` (e.g. `13.0`). The server may emit values
    /// outside that band; no clamping happens here (the pacing layer decides).
    public let utilization: Double
    /// Raw `resets_at` ISO-8601 string, forwarded verbatim to ``ResetClock/parse(_:)``.
    public let resetsAt: String

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    public init(utilization: Double, resetsAt: String) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

// MARK: - UsageLimit

/// One entry of the API `limits[]` array — the server-side pacing/severity signal.
///
/// The server already computes a `severity` tier per active limit; it is kept for the
/// popup (#11) to cross-check against the local ``PacingModel/limitIndicator(utilization:timePercent:)``
/// formula. Like ``UsageWindow``, `resetsAt` stays a raw string for ``ResetClock``.
public struct UsageLimit: Sendable, Equatable, Decodable {
    public let kind: String
    public let group: String
    public let percent: Double
    public let severity: String
    public let resetsAt: String
    public let isActive: Bool

    private enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }

    public init(
        kind: String,
        group: String,
        percent: Double,
        severity: String,
        resetsAt: String,
        isActive: Bool
    ) {
        self.kind = kind
        self.group = group
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.isActive = isActive
    }
}

// MARK: - UsageSnapshot

/// Decoded, immutable result of one successful usage poll.
///
/// `fiveHour` / `sevenDay` are required — a response without the two core windows is
/// unusable, so a missing/`null` value surfaces as a decode failure (mapped to
/// ``UsageError/decode`` by ``UsageClient/decode(from:)``).
///
/// `sevenDayOpus` / `sevenDaySonnet` are optional — the API omits them or sends `null`
/// when that model was not used in the window (issue #9 acceptance: "не падати"). Both
/// an explicit `null` and an absent key decode to `nil` via the synthesized
/// `decodeIfPresent`.
///
/// `extra_usage` / `spend` are intentionally **not** modeled — `Decodable` ignores
/// unknown keys, so their presence is tolerated without any work (issue #9 scope).
///
/// The custom ``init(from:)`` hardens `limits`: an omitted array decodes to `[]` rather
/// than failing the whole snapshot. The memberwise ``init(fiveHour:sevenDay:sevenDayOpus:sevenDaySonnet:limits:)``
/// is kept so tests can build fixtures directly.
public struct UsageSnapshot: Sendable, Equatable, Decodable {
    public let fiveHour: UsageWindow
    public let sevenDay: UsageWindow
    public let sevenDayOpus: UsageWindow?
    public let sevenDaySonnet: UsageWindow?
    public let limits: [UsageLimit]

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case limits
    }

    public init(
        fiveHour: UsageWindow,
        sevenDay: UsageWindow,
        sevenDayOpus: UsageWindow? = nil,
        sevenDaySonnet: UsageWindow? = nil,
        limits: [UsageLimit] = []
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.limits = limits
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fiveHour = try container.decode(UsageWindow.self, forKey: .fiveHour)
        self.sevenDay = try container.decode(UsageWindow.self, forKey: .sevenDay)
        self.sevenDayOpus = try container.decodeIfPresent(UsageWindow.self, forKey: .sevenDayOpus)
        self.sevenDaySonnet = try container.decodeIfPresent(UsageWindow.self, forKey: .sevenDaySonnet)
        // An omitted `limits` array decodes to `[]` instead of failing the snapshot —
        // Phase-0 confirmed it is always present, but a server omission should not be fatal.
        self.limits = try container.decodeIfPresent([UsageLimit].self, forKey: .limits) ?? []
    }
}
