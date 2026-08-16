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
    /// The utilization the app **acted on** — for the seven-day window that is the value
    /// reconstructed from the five-hour counter (#386); everywhere else it equals ``raw``.
    ///
    /// This is deliberately the *effective* number rather than the API's: every downstream reader
    /// (charts, #245) wants the series the bars actually drew, and having to know which field to
    /// prefer is exactly the trap a single field avoids. `v` says which generation a line belongs to,
    /// so the shift in meaning is legible rather than guessed.
    public let util: Double
    /// The API's value verbatim, before reconstruction. Equal to ``util`` on every window except a
    /// reconstructed `seven_day`. Kept so the record stays checkable against the server.
    public let raw: Double
    /// How ``util`` was produced (`WeeklyUtilization.Source`), or `nil` where nothing is
    /// reconstructed — the five-hour window, the per-model rows.
    public let src: String?
    /// The 5h↔7d exchange rate in force when this line was written (#386), or `nil` where it does not
    /// apply. Recorded on **every** sample, not just when it moves: the log gets only the changes
    /// (that would be ~341 lines a day), the journal gets the series, because a series is what can be
    /// analysed afterwards.
    public let n: Double?
    /// Raw `resets_at` ISO-8601 string (empty for an idle/absent reset), forwarded verbatim.
    public let reset: String
    /// Elapsed fraction of the window in [0, 1] (``PacingModel/elapsedFraction(resetsAt:now:window:)``).
    public let timePct: Double
    /// The objective 5-way pacing colour bucket (``PacingBucket/of(_:)``), CalmColorMode-independent.
    public let sev: PacingBucket

    /// - Parameter windowSeconds: the window this sample describes, which sets how many decimals
    ///   `timePct` keeps (``JournalPrecision``). Defaults to the seven-day length — the coarser of
    ///   the two, so a caller that forgets it errs toward *more* precision, never less.
    public init(
        util: Double,
        raw: Double? = nil,
        src: String? = nil,
        n: Double? = nil,
        reset: String,
        timePct: Double,
        sev: PacingBucket,
        windowSeconds: Int = LimitWindow.sevenDay.durationSeconds
    ) {
        // Rounded at construction, so every path into the journal is covered — including fixtures
        // and any future writer that bypasses the domain factory.
        self.util = JournalPrecision.round(util, decimals: JournalPrecision.percentPoints)
        self.raw = JournalPrecision.round(raw ?? util, decimals: JournalPrecision.percentPoints)
        self.src = src
        self.n = JournalPrecision.round(n, decimals: JournalPrecision.percentPoints)
        self.reset = reset
        self.timePct = JournalPrecision.round(
            timePct, decimals: JournalPrecision.forFraction(ofWindowSeconds: windowSeconds))
        self.sev = sev
    }

    private enum CodingKeys: String, CodingKey { case util, raw, src, n, reset, timePct, sev }

    /// Tolerant decode — every field defaults so a partial line never fails the whole record.
    ///
    /// `raw` falls back to `util`, which is exactly right for a v1 line: before #386 the two were the
    /// same number. That makes the old shape readable without a version branch here, while `v` on the
    /// record still tells a *reader* which generation it is looking at.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.util = try c.decodeIfPresent(Double.self, forKey: .util) ?? 0
        self.raw = try c.decodeIfPresent(Double.self, forKey: .raw) ?? util
        self.src = try c.decodeIfPresent(String.self, forKey: .src)
        self.n = try c.decodeIfPresent(Double.self, forKey: .n)
        self.reset = try c.decodeIfPresent(String.self, forKey: .reset) ?? ""
        self.timePct = try c.decodeIfPresent(Double.self, forKey: .timePct) ?? 0
        self.sev = try c.decodeIfPresent(PacingBucket.self, forKey: .sev) ?? .green
    }

    /// The pacing **gap** in percentage points: `timePct·100 − util`. Positive = headroom (behind
    /// pace); negative = ahead of pace.
    ///
    /// **Derived, no longer stored** (#386). It used to be a field, written with fifteen decimals
    /// while all of its uncertainty sat in a `util` quantised to whole percent — 0.2 MB of a 4.6 MB
    /// file spent on digits that meant nothing. Nothing read it: it was written and asserted on, and
    /// never consumed. Now it is computed on demand, which also keeps it honest when `util` is the
    /// reconstructed value.
    public var gap: Double { timePct * 100 - util }
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
    /// Objective 5-way pacing bucket for this model's 7-day-paced bar.
    public let sev: PacingBucket

    public init(name: String, pct: Double, reset: String, timePct: Double, sev: PacingBucket) {
        self.name = name
        self.pct = JournalPrecision.round(pct, decimals: JournalPrecision.percentPoints)
        self.reset = reset
        // Scoped rows are all seven-day-paced (they borrow that window's reset), so they take the
        // seven-day precision.
        self.timePct = JournalPrecision.round(
            timePct,
            decimals: JournalPrecision.forFraction(
                ofWindowSeconds: LimitWindow.sevenDay.durationSeconds))
        self.sev = sev
    }

    private enum CodingKeys: String, CodingKey { case name, pct, reset, timePct, sev }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.pct = try c.decodeIfPresent(Double.self, forKey: .pct) ?? 0
        self.reset = try c.decodeIfPresent(String.self, forKey: .reset) ?? ""
        self.timePct = try c.decodeIfPresent(Double.self, forKey: .timePct) ?? 0
        self.sev = try c.decodeIfPresent(PacingBucket.self, forKey: .sev) ?? .green
    }

    /// Pacing gap in percentage points — derived, not stored, for the same reason as
    /// ``WindowSample/gap``. Scoped rows are **never** reconstructed (a single `N` cannot describe
    /// windows that meter different spend and have no five-hour counter of their own), so `pct` here
    /// is always the API's own number.
    public var gap: Double { timePct * 100 - pct }
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

    public init(
        used: MoneySample? = nil,
        limit: MoneySample? = nil,
        enabled: Bool = false,
        spendLimitReached: Bool = false,
        usedCredits: Double? = nil,
        currency: String? = nil,
        decimalPlaces: Int? = nil,
        spentFrac: Double? = nil,
        monthPct: Double = 0
    ) {
        self.used = used
        self.limit = limit
        self.enabled = enabled
        self.spendLimitReached = spendLimitReached
        self.usedCredits = usedCredits
        self.currency = currency
        self.decimalPlaces = decimalPlaces
        self.spentFrac = JournalPrecision.round(spentFrac, decimals: JournalPrecision.moneyFraction)
        // The month is the window here, so its precision follows the same one-second rule.
        self.monthPct = JournalPrecision.round(
            monthPct, decimals: JournalPrecision.forFraction(ofWindowSeconds: 31 * 24 * 3600))
    }

    /// Credits pacing gap in percentage points: `monthPct·100 − spentFrac·100` (same sign as
    /// ``WindowSample/gap`` — positive = under budget for the month, negative = overspending pace).
    /// `nil` when there is **no** monthly cap (`spend.limit == nil`) — a gap needs a limit to pace
    /// against.
    ///
    /// Derived rather than stored, for the same reason as ``WindowSample/gap``: it was written with
    /// fifteen decimals, read by nothing, and is one subtraction away from the two fields beside it.
    public var creditGap: Double? {
        spentFrac.map { monthPct * 100 - $0 * 100 }
    }

    private enum CodingKeys: String, CodingKey {
        case used, limit, enabled, spendLimitReached, usedCredits, currency, decimalPlaces
        case spentFrac, monthPct
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
    }

    /// Build from a domain ``SpendInfo`` plus the derived credits-pacing numbers.
    init(_ spend: SpendInfo, now: Date) {
        let spentFrac = CreditsPacing.spentFraction(of: spend)
        let monthPct = CreditsPacing.monthElapsedFraction(now: now)
        self.init(
            used: spend.used.map(MoneySample.init),
            limit: spend.limit.map(MoneySample.init),
            enabled: spend.enabled,
            spendLimitReached: spend.spendLimitReached,
            usedCredits: spend.usedCredits,
            currency: spend.currency,
            decimalPlaces: spend.decimalPlaces,
            spentFrac: spentFrac,
            monthPct: monthPct)
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
