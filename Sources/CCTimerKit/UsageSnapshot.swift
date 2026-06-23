import Foundation

// MARK: - Decoder context

extension CodingUserInfoKey {
    /// Threads the polling loop's `now` into ``UsageSnapshot/init(from:)`` so the reset-boundary
    /// synthesis (a `null` window → a fresh `utilization: 0` window) can compute a fallback
    /// `resets_at` via ``ResetClock/nextReset(now:window:)`` **without** calling `Date()` inside the
    /// decode layer. ``UsageClient/decode(from:now:)`` sets it; if absent, the synthesis falls back
    /// to `Date()` (the value only feeds a last-resort estimate, never a parsed instant).
    static let usageNow = CodingUserInfoKey(rawValue: "cc.usageNow")!
}

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
    ///
    /// Empty (`""`) marks a window whose `resets_at` was missing/`null` in the API body — the
    /// synthesis layer (``UsageSnapshot/init(from:)``) treats that as "no usable reset" and fills
    /// one in. `ResetClock.parse("")` already returns `nil`, so an empty value never produces a
    /// bogus instant downstream.
    public let resetsAt: String

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    public init(utilization: Double, resetsAt: String) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    /// Tolerant decode of a **present** window object. On a reset boundary the API may send a
    /// window with `utilization: null` (and occasionally a missing `resets_at`); decoding those as
    /// required values is what crashed the whole snapshot (issue: false "Usage API unavailable").
    /// Here `utilization` defaults to `0` (a just-reset window has zero usage) and `resets_at`
    /// defaults to `""` (the snapshot layer then synthesizes a real one). A window object that is
    /// entirely `null` is handled one level up, in ``UsageSnapshot/init(from:)``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.utilization = try container.decodeIfPresent(Double.self, forKey: .utilization) ?? 0
        self.resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt) ?? ""
    }

    /// Whether this window already carries a usable `resets_at` (non-empty). Drives the
    /// synthesis decision in ``UsageSnapshot/init(from:)``.
    var hasResetsAt: Bool { !resetsAt.isEmpty }
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

    /// Tolerant decode: every field defaults rather than failing. `limits[]` is currently a
    /// decoded-but-unused future-proofing carrier (no downstream consumer) **except** as a fallback
    /// source of `resets_at` for ``UsageSnapshot``'s reset-boundary synthesis — so a `null`
    /// `percent`/`severity`/`is_active` on one entry must never fail the whole snapshot. Newer API
    /// fields (`scope`, …) are ignored as before.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        self.group = try container.decodeIfPresent(String.self, forKey: .group) ?? ""
        self.percent = try container.decodeIfPresent(Double.self, forKey: .percent) ?? 0
        self.severity = try container.decodeIfPresent(String.self, forKey: .severity) ?? "normal"
        self.resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt) ?? ""
        self.isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
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

        // Decode `limits` first: it is both the future-proofing carrier **and** the preferred
        // fallback source of `resets_at` when a core window arrives `null` on a reset boundary.
        // An omitted/`null` array decodes to `[]` (a server omission must not be fatal).
        let limits = try container.decodeIfPresent([UsageLimit].self, forKey: .limits) ?? []
        self.limits = limits

        // `now` for the last-resort reset estimate — injected by `UsageClient.decode(from:now:)`
        // via `userInfo` so the decode layer never calls `Date()` (testability, ADR-0009 spirit).
        let now = (decoder.userInfo[.usageNow] as? Date) ?? Date()

        // The two core windows are required by the model, but on a reset boundary the API may send
        // them as `null` (or with `utilization: null`). Synthesize a fresh zero-usage window in that
        // case instead of failing the whole snapshot (which surfaced as a false "Usage API
        // unavailable"). See `Self.window(...)`.
        self.fiveHour = try Self.window(
            in: container, key: .fiveHour, window: .fiveHour,
            limitKinds: ["session", "five_hour"], limits: limits, now: now)
        self.sevenDay = try Self.window(
            in: container, key: .sevenDay, window: .sevenDay,
            limitKinds: ["weekly_all", "seven_day"], limits: limits, now: now)

        // Per-model sub-windows stay optional: absent/`null` → `nil` (model unused this window).
        self.sevenDayOpus = try container.decodeIfPresent(UsageWindow.self, forKey: .sevenDayOpus)
        self.sevenDaySonnet = try container.decodeIfPresent(UsageWindow.self, forKey: .sevenDaySonnet)
    }

    /// Decode a core window, synthesizing a fresh zero-usage window when the API omits its
    /// `resets_at` on a reset boundary (the object is `null`, missing, or present-but-without a
    /// `resets_at`). The `utilization` is `0` — a just-reset window has zero usage — and the
    /// `resets_at` is resolved by a fallback chain:
    ///
    /// 1. the window object's own `resets_at`, if present (the `utilization: null` case);
    /// 2. the first `limits[]` entry whose `kind` matches `limitKinds` and carries a `resets_at`
    ///    (live API uses `"session"`/`"weekly_all"`; the test fixtures use `"five_hour"`/`"seven_day"`);
    /// 3. a local estimate, ``ResetClock/nextReset(now:window:)`` (`now + duration`, rounded to 10 min).
    ///
    /// Every synthesis is logged once so a genuine future schema change is diagnosable from the logs.
    private static func window(
        in container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        window: LimitWindow,
        limitKinds: [String],
        limits: [UsageLimit],
        now: Date
    ) throws -> UsageWindow {
        // A present, well-formed window with its own `resets_at` is the common path — return as-is.
        if let decoded = try container.decodeIfPresent(UsageWindow.self, forKey: key),
           decoded.hasResetsAt {
            return decoded
        }

        // Otherwise synthesize. Resolve the reset string via the fallback chain.
        let source: String
        let resetsAt: String
        if let fromLimit = limits.first(where: { limitKinds.contains($0.kind) && !$0.resetsAt.isEmpty })?.resetsAt {
            source = "limits[]"
            resetsAt = fromLimit
        } else {
            source = "local-estimate"
            resetsAt = Self.isoString(from: ResetClock.nextReset(now: now, window: window))
        }

        AppLogger.network.notice(
            "synthesized \(key.stringValue, privacy: .public) window on reset boundary (utilization=0, resets_at source=\(source, privacy: .public))")
        return UsageWindow(utilization: 0, resetsAt: resetsAt)
    }

    /// Render a `Date` back into the API's `resets_at` string shape (`…+00:00`, no fractional
    /// seconds) so the synthesized value round-trips through ``ResetClock/parse(_:)`` identically to
    /// a real one. Only used for the local-estimate fallback.
    private static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]   // no fractional seconds — `ResetClock` strips them anyway
        return formatter.string(from: date)
    }
}
