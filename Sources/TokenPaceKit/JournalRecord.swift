import Foundation

// MARK: - JournalRecord

/// One line of the append-only usage journal (#242) — a tagged, forward-compatible value that the
/// downstream Insights features (#239/#240/#241) read back.
///
/// The journal is a heterogeneous JSONL: every line carries a `kind` discriminator and one of four
/// shapes. Decoding is **tolerant** in the same spirit as ``MonitoredServices`` / ``StatusSummary``:
/// an unknown `kind` (a shape a future build wrote) decodes to ``unknown`` rather than throwing, and
/// every optional field uses `decodeIfPresent` with a default, so a newer line never breaks an older
/// reader. New fields are added as new keys, never by changing existing ones.
///
/// The value types are **pure and testable** (no AppKit, no clock of their own): the shell's
/// `UsageJournal` only serialises what the ``usage(from:now:)`` / ``status(from:health:now:)`` /
/// ``error(diagnostics:now:)`` factories produce, so all the domain→line mapping (which calls
/// ``PacingModel`` / ``CreditsPacing`` / ``BlockingReset`` / ``PacingBucket``) lives here and is
/// covered by unit tests.
public enum JournalRecord: Sendable, Equatable {
    /// A successful usage poll — the windows, credits, and the derived states the UI shows.
    case usage(UsageSample)
    /// A successful service-status poll — a separate data sample (status rides a different poll loop
    /// than usage, ADR-0013), tagged so a reader can keep the two series apart.
    case status(StatusSample)
    /// A failed usage poll — 429 / timeout / network / auth / malformed body. Recorded so a reader
    /// can distinguish "the API failed" from "we weren't looking" (see ``ResumeMarker``).
    case error(ErrorSample)
    /// A resume marker written after a sampling gap longer than the expected interval, so a reader
    /// can tell "nothing happened" from "we weren't polling" and never interpolate across the hole.
    case resume(ResumeMarker)
    /// An unrecognised line — an unknown `kind` a future build wrote. Kept as a case (not dropped) so
    /// the reader can count/skip it without failing the whole file.
    case unknown
}

// MARK: - Codable (tagged)

extension JournalRecord: Codable {
    private enum Kind: String, Codable {
        case usage, status, error, resume
    }

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A missing/unknown `kind` is not an error — it decodes to `.unknown`, mirroring
        // `WebDesktopMode`'s unknown-string fallback. `decodeIfPresent` guards an absent key.
        let raw = try container.decodeIfPresent(String.self, forKey: .kind)
        switch raw.flatMap(Kind.init(rawValue:)) {
        case .usage:  self = .usage(try UsageSample(from: decoder))
        case .status: self = .status(try StatusSample(from: decoder))
        case .error:  self = .error(try ErrorSample(from: decoder))
        case .resume: self = .resume(try ResumeMarker(from: decoder))
        case nil:     self = .unknown
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .usage(sample):
            try container.encode(Kind.usage.rawValue, forKey: .kind)
            try sample.encode(to: encoder)
        case let .status(sample):
            try container.encode(Kind.status.rawValue, forKey: .kind)
            try sample.encode(to: encoder)
        case let .error(sample):
            try container.encode(Kind.error.rawValue, forKey: .kind)
            try sample.encode(to: encoder)
        case let .resume(marker):
            try container.encode(Kind.resume.rawValue, forKey: .kind)
            try marker.encode(to: encoder)
        case .unknown:
            // An `.unknown` is a read-only artefact; we never author one, so there is nothing to
            // encode beyond an empty object. (Round-tripping `.unknown` is not a use case.)
            break
        }
    }
}

// MARK: - WindowSample

/// One usage window as journalled: its utilisation, raw reset string, elapsed-time fraction, and the
/// objective pacing colour bucket (``PacingBucket``). Used for `h5`/`d7`/`opus`/`sonnet`.
public struct WindowSample: Sendable, Equatable, Codable {
    /// `utilization` percent in [0, 100].
    public let util: Double
    /// Raw `resets_at` ISO-8601 string (empty for an idle/absent reset), forwarded verbatim.
    public let reset: String
    /// Elapsed fraction of the window in [0, 1] (``PacingModel/elapsedFraction(resetsAt:now:window:)``).
    public let timePct: Double
    /// The pacing **gap** in percentage points: `timePct·100 − util`. Positive = headroom (behind pace,
    /// spending slower than the clock); negative = ahead of pace (spending faster). Precomputed because
    /// it is expected to be a common downstream metric (a chart of how far ahead/behind you ran). It is
    /// derivable from `timePct` and `util`, but stored so a reader need not recompute it per point.
    public let gap: Double
    /// The objective 5-way pacing colour bucket (``PacingBucket/of(_:)``), CalmColorMode-independent.
    public let sev: PacingBucket

    public init(util: Double, reset: String, timePct: Double, gap: Double, sev: PacingBucket) {
        self.util = util
        self.reset = reset
        self.timePct = timePct
        self.gap = gap
        self.sev = sev
    }

    private enum CodingKeys: String, CodingKey { case util, reset, timePct, gap, sev }

    /// Tolerant decode — every field defaults so a partial line never fails the whole record. `gap`
    /// defaults to the derived `timePct·100 − util` when absent (an older line predating the field).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.util = try c.decodeIfPresent(Double.self, forKey: .util) ?? 0
        self.reset = try c.decodeIfPresent(String.self, forKey: .reset) ?? ""
        self.timePct = try c.decodeIfPresent(Double.self, forKey: .timePct) ?? 0
        self.gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? (timePct * 100 - util)
        self.sev = try c.decodeIfPresent(PacingBucket.self, forKey: .sev) ?? .green
    }
}

// MARK: - ScopedSample

/// One per-model weekly limit as journalled (from ``ScopedModelWindow``): the model name, its
/// percent, raw reset, and objective bucket. No `timePct` — scoped windows borrow `seven_day`'s
/// reset and are all 7-day-paced, so `d7.timePct` already carries their elapsed fraction.
public struct ScopedSample: Sendable, Equatable, Codable {
    /// `scope.model.display_name`, e.g. `"Fable"`.
    public let name: String
    /// `percent` in [0, 100].
    public let pct: Double
    /// Raw reset string (borrowed from `seven_day` when the entry had none).
    public let reset: String
    /// Elapsed fraction of the (7-day-paced) window in [0, 1].
    public let timePct: Double
    /// Pacing gap in percentage points: `timePct·100 − pct` (same sign convention as ``WindowSample/gap``).
    public let gap: Double
    /// Objective 5-way pacing bucket for this model's 7-day-paced bar.
    public let sev: PacingBucket

    public init(name: String, pct: Double, reset: String, timePct: Double, gap: Double, sev: PacingBucket) {
        self.name = name
        self.pct = pct
        self.reset = reset
        self.timePct = timePct
        self.gap = gap
        self.sev = sev
    }

    private enum CodingKeys: String, CodingKey { case name, pct, reset, timePct, gap, sev }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.pct = try c.decodeIfPresent(Double.self, forKey: .pct) ?? 0
        self.reset = try c.decodeIfPresent(String.self, forKey: .reset) ?? ""
        self.timePct = try c.decodeIfPresent(Double.self, forKey: .timePct) ?? 0
        self.gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? (timePct * 100 - pct)
        self.sev = try c.decodeIfPresent(PacingBucket.self, forKey: .sev) ?? .green
    }
}

// MARK: - MoneySample

/// An exact money amount as journalled — the integer minor-unit form of ``Money``, kept verbatim so
/// no cent is lost to floating point (a €10.77 is `{minor:1077, cur:"EUR", exp:2}`).
public struct MoneySample: Sendable, Equatable, Codable {
    public let minor: Int
    public let cur: String
    public let exp: Int

    public init(minor: Int, cur: String, exp: Int) {
        self.minor = minor
        self.cur = cur
        self.exp = exp
    }

    private enum CodingKeys: String, CodingKey { case minor, cur, exp }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.minor = try c.decodeIfPresent(Int.self, forKey: .minor) ?? 0
        self.cur = try c.decodeIfPresent(String.self, forKey: .cur) ?? ""
        self.exp = try c.decodeIfPresent(Int.self, forKey: .exp) ?? 0
    }

    /// Build from a domain ``Money``.
    init(_ money: Money) {
        self.init(minor: money.amountMinor, cur: money.currency, exp: money.exponent)
    }
}

// MARK: - SpendSample

/// The money-credits ("extra usage") state as journalled — the full ``SpendInfo`` plus the two
/// derived credits-pacing numbers the UI shows (`spentFrac`, `monthPct`).
public struct SpendSample: Sendable, Equatable, Codable {
    public let used: MoneySample?
    public let limit: MoneySample?
    public let enabled: Bool
    public let spendLimitReached: Bool
    public let usedCredits: Double?
    public let currency: String?
    public let decimalPlaces: Int?
    /// `used / limit` fraction (``CreditsPacing/spentFraction(of:)``), or `nil` when there is no cap.
    public let spentFrac: Double?
    /// Elapsed fraction of the calendar month (``CreditsPacing/monthElapsedFraction(now:timeZone:)``).
    public let monthPct: Double
    /// Credits pacing gap in percentage points: `monthPct·100 − spentFrac·100` (same sign as
    /// ``WindowSample/gap`` — positive = under budget for the month, negative = overspending pace).
    /// `nil` when there is **no** monthly cap (`spend.limit == nil`) — a gap needs a limit to pace
    /// against, matching Artem's "only when a limit was set".
    public let creditGap: Double?

    public init(
        used: MoneySample? = nil,
        limit: MoneySample? = nil,
        enabled: Bool = false,
        spendLimitReached: Bool = false,
        usedCredits: Double? = nil,
        currency: String? = nil,
        decimalPlaces: Int? = nil,
        spentFrac: Double? = nil,
        monthPct: Double = 0,
        creditGap: Double? = nil
    ) {
        self.used = used
        self.limit = limit
        self.enabled = enabled
        self.spendLimitReached = spendLimitReached
        self.usedCredits = usedCredits
        self.currency = currency
        self.decimalPlaces = decimalPlaces
        self.spentFrac = spentFrac
        self.monthPct = monthPct
        self.creditGap = creditGap
    }

    private enum CodingKeys: String, CodingKey {
        case used, limit, enabled, spendLimitReached, usedCredits, currency, decimalPlaces
        case spentFrac, monthPct, creditGap
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.used = try c.decodeIfPresent(MoneySample.self, forKey: .used)
        self.limit = try c.decodeIfPresent(MoneySample.self, forKey: .limit)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.spendLimitReached = try c.decodeIfPresent(Bool.self, forKey: .spendLimitReached) ?? false
        self.usedCredits = try c.decodeIfPresent(Double.self, forKey: .usedCredits)
        self.currency = try c.decodeIfPresent(String.self, forKey: .currency)
        self.decimalPlaces = try c.decodeIfPresent(Int.self, forKey: .decimalPlaces)
        self.spentFrac = try c.decodeIfPresent(Double.self, forKey: .spentFrac)
        self.monthPct = try c.decodeIfPresent(Double.self, forKey: .monthPct) ?? 0
        self.creditGap = try c.decodeIfPresent(Double.self, forKey: .creditGap)
    }

    /// Build from a domain ``SpendInfo`` plus the derived credits-pacing numbers.
    init(_ spend: SpendInfo, now: Date) {
        let spentFrac = CreditsPacing.spentFraction(of: spend)
        let monthPct = CreditsPacing.monthElapsedFraction(now: now)
        // Credit gap only when a cap was set (`spentFrac != nil` iff `spend.limit` has a usable value).
        let creditGap = spentFrac.map { monthPct * 100 - $0 * 100 }
        self.init(
            used: spend.used.map(MoneySample.init),
            limit: spend.limit.map(MoneySample.init),
            enabled: spend.enabled,
            spendLimitReached: spend.spendLimitReached,
            usedCredits: spend.usedCredits,
            currency: spend.currency,
            decimalPlaces: spend.decimalPlaces,
            spentFrac: spentFrac,
            monthPct: monthPct,
            creditGap: creditGap)
    }
}

// MARK: - CreditsFlags

/// The credits icon's presentation state — the three booleans that drive whether/how it shows.
public struct CreditsFlags: Sendable, Equatable, Codable {
    /// ``CreditsPacing/isActive(_:)`` — credits are active (`enabled || spend_limit_reached`).
    public let active: Bool
    /// ``CreditsPacing/shouldShowIcon(_:baseLimitExhausted:)`` — the menu-bar icon is shown.
    public let showIcon: Bool
    /// ``ExtraUsageOnset/isOnCredits(_:)`` — work is currently spilling onto paid credits.
    public let onCredits: Bool

    public init(active: Bool, showIcon: Bool, onCredits: Bool) {
        self.active = active
        self.showIcon = showIcon
        self.onCredits = onCredits
    }

    private enum CodingKeys: String, CodingKey { case active, showIcon, onCredits }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        self.showIcon = try c.decodeIfPresent(Bool.self, forKey: .showIcon) ?? false
        self.onCredits = try c.decodeIfPresent(Bool.self, forKey: .onCredits) ?? false
    }
}

// MARK: - BlockingResetSample

/// Which reset is painted red as the blocked countdown (``BlockingReset/Choice``): a token window
/// (with its opaque id) or the credits window.
public struct BlockingResetSample: Sendable, Equatable, Codable {
    /// `"token"` or `"credits"`.
    public let via: String
    /// The token window id when `via == "token"`, else `nil`.
    public let id: Int?
    /// The chosen reset instant as an ISO-8601 string.
    public let reset: String

    public init(via: String, id: Int?, reset: String) {
        self.via = via
        self.id = id
        self.reset = reset
    }

    private enum CodingKeys: String, CodingKey { case via, id, reset }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.via = try c.decodeIfPresent(String.self, forKey: .via) ?? ""
        self.id = try c.decodeIfPresent(Int.self, forKey: .id)
        self.reset = try c.decodeIfPresent(String.self, forKey: .reset) ?? ""
    }

    /// Build from a domain ``BlockingReset/Choice``.
    init(_ choice: BlockingReset.Choice) {
        switch choice {
        case let .token(id, at):
            self.init(via: "token", id: id, reset: ResetClock.isoString(from: at))
        case let .credits(at):
            self.init(via: "credits", id: nil, reset: ResetClock.isoString(from: at))
        }
    }
}
