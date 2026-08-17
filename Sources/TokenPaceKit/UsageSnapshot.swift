import Foundation

// MARK: - Decoder context

extension CodingUserInfoKey {
    /// Threads the polling loop's `now` into ``UsageSnapshot/init(from:)`` so the reset-boundary
    /// synthesis (a `null` window → a fresh `utilization: 0` window) can compute a fallback
    /// `resets_at` via ``ResetClock/nextReset(now:window:)`` **without** calling `Date()` inside the
    /// decode layer. ``UsageClient/decode(from:now:)`` sets it; if absent, the synthesis falls back
    /// to `Date()` (the value only feeds a last-resort estimate, never a parsed instant).
    ///
    /// Only `seven_day` reaches the local estimate now (#100): the `five_hour` window opts out of it
    /// (`localEstimateAllowed: false`), reporting the honest ``UsageSnapshot/sessionIdle`` state
    /// instead of synthesizing a drifting `now + 5h` reset.
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
///
/// `weekly_scoped` entries additionally carry a `scope` object naming the model they cap
/// (`scope.model.display_name`, e.g. `"Fable"`). That name is the **only** identity the API gives
/// for models without a top-level `seven_day_*` window (#65), so it is flattened into
/// ``modelDisplayName``; the rest of `scope` (`model.id`, `surface`) stays ignored.
public struct UsageLimit: Sendable, Equatable, Decodable {
    public let kind: String
    public let group: String
    public let percent: Double
    public let severity: String
    public let resetsAt: String
    public let isActive: Bool
    /// `scope.model.display_name` of a `weekly_scoped` entry (e.g. `"Fable"`), or `nil` when the
    /// entry is unscoped (`scope: null` on `session`/`weekly_all`) or the name is absent. Feeds
    /// ``UsageSnapshot/scopedModelWindows``.
    public let modelDisplayName: String?

    private enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }

    /// Minimal mirror of the `scope` object — only the path to the model display name is decoded.
    private struct Scope: Decodable {
        let model: Model?
        struct Model: Decodable {
            let displayName: String?
            enum CodingKeys: String, CodingKey { case displayName = "display_name" }
        }
    }

    public init(
        kind: String,
        group: String,
        percent: Double,
        severity: String,
        resetsAt: String,
        isActive: Bool,
        modelDisplayName: String? = nil
    ) {
        self.kind = kind
        self.group = group
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.isActive = isActive
        self.modelDisplayName = modelDisplayName
    }

    /// Tolerant decode: every field defaults rather than failing. Beyond the `resets_at` fallback
    /// role for ``UsageSnapshot``'s reset-boundary synthesis, `limits[]` now also carries the
    /// per-model weekly limits (`weekly_scoped` + `scope.model.display_name`, #65) — so a `null`
    /// `percent`/`severity`/`is_active` on one entry must never fail the whole snapshot. The
    /// `scope` decode is `try?`-wrapped: a plain `decodeIfPresent` **throws** on a type mismatch
    /// (e.g. `scope` arriving as a string), and a malformed scope must degrade to `nil`, not kill
    /// the snapshot. Other newer API fields stay ignored.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        self.group = try container.decodeIfPresent(String.self, forKey: .group) ?? ""
        self.percent = try container.decodeIfPresent(Double.self, forKey: .percent) ?? 0
        self.severity = try container.decodeIfPresent(String.self, forKey: .severity) ?? "normal"
        self.resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt) ?? ""
        self.isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        self.modelDisplayName =
            ((try? container.decodeIfPresent(Scope.self, forKey: .scope)) ?? nil)?.model?.displayName
    }
}

// MARK: - Money

/// An exact money amount as delivered by the credits blocks of `GET /api/oauth/usage`
/// (`spend.used`, `spend.limit`, `spend.cap.money`).
///
/// The API sends money as an **integer minor unit** plus its currency and exponent — e.g.
/// `{"amount_minor":1077,"currency":"EUR","exponent":2}` is €10.77. We keep that integer form
/// verbatim rather than collapsing it to a `Double`: floating point cannot represent every decimal
/// cent exactly, and this value feeds a money label. The currency is **not** hard-coded to USD — the
/// spike (#142) observed EUR — so it travels with the amount.
///
/// `majorUnitValue` reconstitutes the human amount (`amount_minor / 10^exponent`) as a `Double`
/// **only** for pacing arithmetic (fraction against a limit); the display layer (#144/#145) should
/// format from the integer + exponent to avoid rounding the label.
public struct Money: Sendable, Equatable, Decodable {
    /// The amount in the currency's minor unit (e.g. cents): `1077` == €10.77 at `exponent: 2`.
    public let amountMinor: Int
    /// ISO currency code as sent, e.g. `"EUR"` — dynamic, never assumed to be USD.
    public let currency: String
    /// Number of fractional digits: `2` for EUR/USD. `amountMinor / 10^exponent` is the major value.
    public let exponent: Int

    private enum CodingKeys: String, CodingKey {
        case amountMinor = "amount_minor"
        case currency
        case exponent
    }

    public init(amountMinor: Int, currency: String, exponent: Int) {
        self.amountMinor = amountMinor
        self.currency = currency
        self.exponent = exponent
    }

    /// Tolerant decode: every field defaults rather than failing, matching the rest of this file.
    /// A malformed/partial money object degrades to zeros/`""` instead of killing the whole snapshot
    /// (the credits blocks are auxiliary; a schema wobble there must never lose the core windows).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.amountMinor = try container.decodeIfPresent(Int.self, forKey: .amountMinor) ?? 0
        self.currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? ""
        self.exponent = try container.decodeIfPresent(Int.self, forKey: .exponent) ?? 0
    }

    /// The amount as a major-unit `Double` (`amount_minor / 10^exponent`), e.g. `10.77` for
    /// `1077`/`exponent: 2`. **For pacing arithmetic only** — format the display label from the
    /// integer + exponent, not from this, to avoid representation error on the shown value.
    public var majorUnitValue: Double {
        Double(amountMinor) / pow(10, Double(exponent))
    }

    /// Whether this is a zero amount — tested on the **integer** minor units, never on
    /// ``majorUnitValue``, so it is exact at any exponent and immune to the float division above.
    /// Currency-agnostic: €0, $0 and a zero in an unknown currency are all zero.
    public var isZero: Bool { amountMinor == 0 }
}

// MARK: - SpendInfo

/// The "extra usage" money-credits state of one poll — the paid overspend that covers you past the
/// plan limits (Settings → *Usage credits*). Introduced by the spike (#142); rendered by #144/#145.
///
/// The API delivers this across **two parallel blocks**, and this type merges the useful half of
/// each (the raw blocks are private decode helpers below):
/// - **`spend`** is the primary, cleaner source: exact `used` / `limit` **money objects** and the
///   `enabled` flag.
/// - **`extra_usage`** is the reserve for the fields `spend` lacks: `spend_limit_reached` (the
///   over-limit signal the icon trigger needs), plus `currency` / `decimal_places` and the
///   `used_credits` scalar (the same amount as `spend.used`, kept as a cross-check / fallback).
///
/// **Deliberately not modeled** (spike findings, #142):
/// - The server `spend.severity` — the maintainer decided the icon colour is computed the same way as
///   the token bars (usage vs. time, ``CreditsPacing/barLayout(for:now:timeZone:)``), never the server tier.
/// - `spend.balance` / `spend.auto_reload` — Current balance is **not** delivered by this endpoint
///   (null in every observed state); balance-relative pacing is a future feature, out of scope.
///
/// Every field is optional-friendly and defaults so an unknown/partial credits payload never fails
/// the snapshot (the two blocks are auxiliary to the core windows).
public struct SpendInfo: Sendable, Equatable {
    /// `spend.used` — the exact amount spent this period (e.g. €10.77). Source of truth for "spent".
    public let used: Money?
    /// `spend.limit` — the money cap, or `nil` when the user set the monthly limit to *unlimited*
    /// (`spend.limit: null`). `nil` means **no pacing** — show the spent amount only, no bar/percent.
    public let limit: Money?
    /// `spend.enabled` — whether credits are actively covering overspend right now. The server flips
    /// this to **false** the moment the money cap is exceeded, which is why the icon trigger also
    /// checks ``spendLimitReached`` (see ``CreditsPacing/isActive(_:)``).
    public let enabled: Bool
    /// `extra_usage.spend_limit_reached` — `true` once the money cap is hit. Paired with `enabled`
    /// because the two never overlap: at the cap the server sends `enabled: false` +
    /// `spend_limit_reached: true`, so relying on `enabled` alone would hide the icon exactly when
    /// the user most needs it.
    public let spendLimitReached: Bool
    /// `extra_usage.used_credits` — the spent amount as a minor-unit scalar (e.g. `1077.0`), mirroring
    /// ``used``. Kept as a decimal cross-check / fallback; prefer ``used`` for exactness.
    public let usedCredits: Double?
    /// `extra_usage.currency` — currency code from the extra-usage block (e.g. `"EUR"`), a fallback
    /// for ``used``/``limit`` currency when a money object is absent.
    public let currency: String?
    /// `extra_usage.decimal_places` — fractional-digit count for `used_credits` (e.g. `2`), the
    /// exponent to apply to the scalar credits when no ``Money`` object carries one.
    public let decimalPlaces: Int?

    public init(
        used: Money? = nil,
        limit: Money? = nil,
        enabled: Bool = false,
        spendLimitReached: Bool = false,
        usedCredits: Double? = nil,
        currency: String? = nil,
        decimalPlaces: Int? = nil
    ) {
        self.used = used
        self.limit = limit
        self.enabled = enabled
        self.spendLimitReached = spendLimitReached
        self.usedCredits = usedCredits
        self.currency = currency
        self.decimalPlaces = decimalPlaces
    }

    /// The single resolved ISO currency code for display, with a fallback chain: the `spend.used`
    /// money object first (the amount actually shown), then `spend.limit`, then the `extra_usage`
    /// `currency` scalar. Empty string if none is present. Both the menu-bar glyph
    /// (``MenuBarLayout/CreditsMarker/currency``) and the popup money formatter read this so a single
    /// currency drives every rendering of the credits.
    public var currencyCode: String {
        if let c = used?.currency, !c.isEmpty { return c }
        if let c = limit?.currency, !c.isEmpty { return c }
        return currency ?? ""
    }

    // MARK: raw block decoders

    /// Minimal mirror of the top-level `spend` block — only the fields we surface are decoded, the
    /// rest (`percent`, `severity`, `cap`, `balance`, `auto_reload`, `disclaimer`, …) stay ignored.
    struct SpendBlock: Decodable {
        let used: Money?
        let limit: Money?
        let enabled: Bool

        private enum CodingKeys: String, CodingKey { case used, limit, enabled }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.used = try container.decodeIfPresent(Money.self, forKey: .used)
            self.limit = try container.decodeIfPresent(Money.self, forKey: .limit)
            self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        }
    }

    /// Minimal mirror of the top-level `extra_usage` block — only the fields `spend` lacks (or that
    /// serve as a fallback) are decoded; `is_enabled`, `utilization`, `monthly_limit`,
    /// `disabled_reason`, `user_disabled`, `credits_ever_enabled`, `daily`, `weekly`, … stay ignored.
    struct ExtraUsageBlock: Decodable {
        let spendLimitReached: Bool
        let usedCredits: Double?
        let currency: String?
        let decimalPlaces: Int?

        private enum CodingKeys: String, CodingKey {
            case spendLimitReached = "spend_limit_reached"
            case usedCredits = "used_credits"
            case currency
            case decimalPlaces = "decimal_places"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.spendLimitReached =
                try container.decodeIfPresent(Bool.self, forKey: .spendLimitReached) ?? false
            self.usedCredits = try container.decodeIfPresent(Double.self, forKey: .usedCredits)
            self.currency = try container.decodeIfPresent(String.self, forKey: .currency)
            self.decimalPlaces = try container.decodeIfPresent(Int.self, forKey: .decimalPlaces)
        }
    }

    /// Merge the two raw blocks into a `SpendInfo`. Returns `nil` only when **both** blocks are
    /// absent (a pre-credits payload) — a present-but-empty block still yields a value with defaults.
    static func merged(spend: SpendBlock?, extraUsage: ExtraUsageBlock?) -> SpendInfo? {
        guard spend != nil || extraUsage != nil else { return nil }
        return SpendInfo(
            used: spend?.used,
            limit: spend?.limit,
            enabled: spend?.enabled ?? false,
            spendLimitReached: extraUsage?.spendLimitReached ?? false,
            usedCredits: extraUsage?.usedCredits,
            currency: extraUsage?.currency,
            decimalPlaces: extraUsage?.decimalPlaces)
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
/// `spend` / `extra_usage` carry the money-credits state (#143) merged into the optional
/// ``spend`` field (``SpendInfo``). They stay **optional**: a pre-credits payload has neither
/// block, so `spend` decodes to `nil` and the (many) existing fixtures keep passing.
///
/// The custom ``init(from:)`` hardens `limits`: an omitted array decodes to `[]` rather
/// than failing the whole snapshot. The memberwise ``init(fiveHour:sevenDay:sevenDayOpus:sevenDaySonnet:limits:sessionIdle:spend:)``
/// is kept so tests can build fixtures directly; `spend` defaults to `nil` there.
public struct UsageSnapshot: Sendable, Equatable, Decodable {
    public let fiveHour: UsageWindow
    public let sevenDay: UsageWindow
    public let sevenDayOpus: UsageWindow?
    public let sevenDaySonnet: UsageWindow?
    public let limits: [UsageLimit]
    /// Whether the 5-hour window does **not** exist server-side right now — the honest "no active
    /// session" state (#100). Set when the `five_hour` window arrives without a usable `resets_at`
    /// **and** no `limits[]` entry supplies one either: the 5h window is *created* by the first token
    /// spend and *does not exist* until then (verified server mechanics — see ADR-0027), so a missing
    /// reset means "ready to start", not a reset boundary. When `true`, `fiveHour` is
    /// `UsageWindow(utilization: 0, resetsAt: "")` and the UI renders a green "ready to start"
    /// bar with **no synthesized phantom reset** — the bug this flag fixes. `false` on every normal
    /// snapshot (an active 5h window, or a genuine reset-boundary `null` that `limits[]` still
    /// backfills). Applies only to `five_hour`; the 7-day window keeps its local-estimate fallback.
    public let sessionIdle: Bool
    /// The money-credits ("extra usage") state (#143), merged from the `spend` + `extra_usage`
    /// blocks. `nil` on a pre-credits payload where neither block is present — the (many) legacy
    /// fixtures rely on that default. Consumed by ``CreditsPacing`` (#144/#145 render it).
    public let spend: SpendInfo?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case limits
        case spend
        case extraUsage = "extra_usage"
    }

    public init(
        fiveHour: UsageWindow,
        sevenDay: UsageWindow,
        sevenDayOpus: UsageWindow? = nil,
        sevenDaySonnet: UsageWindow? = nil,
        limits: [UsageLimit] = [],
        sessionIdle: Bool = false,
        spend: SpendInfo? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.limits = limits
        self.sessionIdle = sessionIdle
        self.spend = spend
    }

    /// Whether the snapshot carries a **broken-`resets_at` data error** on an **active** window — the
    /// server reports real usage (`utilization > 0`) yet the window's `resets_at` string is present but
    /// unparseable (`ResetClock.parse == nil`). Such a 200 body is malformed, so both the menu bar (⚠️
    /// error mode) and the popup (a red warning banner) surface it as an API error rather than a
    /// fabricated countdown / `resetting…` (#167, ADR-0043). The single source of truth for the check,
    /// shared by `MenuBarLayout` and `PopupLayout`.
    ///
    /// Deliberately **not** an error for: a **zero-usage** window (nothing to reset yet), the
    /// session-idle 5h (legitimately date-less, ADR-0027 — its `resetsAt` is `""`, which `parse` also
    /// rejects, so `sessionIdle` is excluded explicitly), or a `""`/`null` date (a boundary/idle state,
    /// not a malformed value). Only a **non-empty, unparseable** date on a used window qualifies.
    public var hasBrokenActiveReset: Bool {
        func broken(_ window: UsageWindow) -> Bool {
            window.utilization > 0 && window.hasResetsAt && ResetClock.parse(window.resetsAt) == nil
        }
        let fiveBroken = !sessionIdle && broken(fiveHour)
        return fiveBroken || broken(sevenDay)
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
        //
        // `five_hour` is special (#100): when its reset is unavailable **and** `limits[]` backfills
        // nothing, the window does not exist server-side (no active session), so `window(...)` reports
        // `sessionIdle: true` and returns a `resetsAt: ""` window rather than a synthesized `now + 5h`
        // phantom. `localEstimateAllowed: false` disables the local-estimate rung for it — that rung
        // is exactly what produced the drifting phantom reset. `seven_day` keeps the local estimate
        // (`localEstimateAllowed: true`) and is never idle: the weekly window always exists.
        let (five, fiveIdle) = try Self.window(
            in: container, key: .fiveHour, window: .fiveHour,
            limitKinds: ["session", "five_hour"], limits: limits, now: now,
            localEstimateAllowed: false)
        self.fiveHour = five
        self.sessionIdle = fiveIdle
        self.sevenDay = try Self.window(
            in: container, key: .sevenDay, window: .sevenDay,
            limitKinds: ["weekly_all", "seven_day"], limits: limits, now: now,
            localEstimateAllowed: true).window

        // Per-model sub-windows stay optional: an absent key or an all-`null` object → `nil` (the
        // model was not used this window). But a **present** sub-window with `resets_at: null` is the
        // same reset-boundary case as the core windows (live API sends e.g.
        // `seven_day_sonnet: {"utilization":0.0,"resets_at":null}`): keep its `utilization` and
        // borrow `resets_at` from `seven_day` — the sub-window is part of the 7-day window, so they
        // reset together. Without this the bar rendered a bogus "resetting…" at 100 % elapsed.
        self.sevenDayOpus = try Self.subWindow(
            in: container, key: .sevenDayOpus, parentResetsAt: sevenDay.resetsAt)
        self.sevenDaySonnet = try Self.subWindow(
            in: container, key: .sevenDaySonnet, parentResetsAt: sevenDay.resetsAt)

        // Money-credits state (#143): merge the two parallel blocks. `decodeIfPresent` on each keeps
        // a pre-credits payload (neither block) → `spend == nil`, so legacy fixtures are unaffected.
        let spendBlock = try container.decodeIfPresent(SpendInfo.SpendBlock.self, forKey: .spend)
        let extraUsage = try container.decodeIfPresent(SpendInfo.ExtraUsageBlock.self, forKey: .extraUsage)
        self.spend = SpendInfo.merged(spend: spendBlock, extraUsage: extraUsage)
    }

    /// Decode an optional per-model sub-window (`seven_day_opus` / `seven_day_sonnet`).
    ///
    /// - An absent key or an all-`null` object → `nil` (the model was unused this window).
    /// - A present object **with** a `resets_at` → returned as-is.
    /// - A present object **without** a `resets_at` (the reset-boundary `resets_at: null` case) →
    ///   `utilization` kept, `resets_at` borrowed from `parentResetsAt` (the 7-day window they
    ///   reset with). Logged once.
    private static func subWindow(
        in container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        parentResetsAt: String
    ) throws -> UsageWindow? {
        guard let decoded = try container.decodeIfPresent(UsageWindow.self, forKey: key) else {
            return nil   // absent / null → model unused
        }
        if decoded.hasResetsAt { return decoded }
        AppLogger.network.notice(
            "filled \(key.stringValue, privacy: .public) sub-window resets_at from seven_day (was null)")
        return UsageWindow(utilization: decoded.utilization, resetsAt: parentResetsAt)
    }

    /// Decode a core window, resolving its `resets_at` via a fallback chain when the API omits it on
    /// a reset boundary (the object is `null`, missing, or present-but-without a `resets_at`). The
    /// `utilization` is `0` — a just-reset window has zero usage — and the `resets_at` chain is:
    ///
    /// 1. the window object's own `resets_at`, if present (the `utilization: null` case);
    /// 2. the first `limits[]` entry whose `kind` matches `limitKinds` and carries a `resets_at`
    ///    (live API uses `"session"`/`"weekly_all"`; the test fixtures use `"five_hour"`/`"seven_day"`);
    /// 3. a local estimate, ``ResetClock/nextReset(now:window:)`` (`now + duration`, rounded to 10 min)
    ///    — **only when `localEstimateAllowed`**.
    ///
    /// `localEstimateAllowed` splits the two core windows (#100):
    /// - `seven_day` (`true`): the weekly window always exists, so an exhausted chain still synthesizes
    ///   a `now + 7d` estimate (logged once) — a missing weekly reset is a genuine boundary blip.
    /// - `five_hour` (`false`): the 5h window is *created by the first token spend* and does not exist
    ///   before then. An exhausted chain therefore means "no active session", not a reset boundary:
    ///   the method returns `(UsageWindow(utilization: <decoded ?? 0>, resetsAt: ""), sessionIdle: true)`
    ///   with **no** local estimate and **no** synthesis log — the honest idle state the UI renders as
    ///   a green "ready to start" bar. This is what removes the drifting phantom `now + 5h` reset.
    ///
    /// - Returns: the resolved window plus `sessionIdle` — `true` only in the `five_hour` exhausted-chain
    ///   case above, `false` on every other path (present reset, or a `limits[]`/local-estimate fill).
    private static func window(
        in container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        window: LimitWindow,
        limitKinds: [String],
        limits: [UsageLimit],
        now: Date,
        localEstimateAllowed: Bool
    ) throws -> (window: UsageWindow, sessionIdle: Bool) {
        // The window object as sent (may be absent → `nil`). Kept so an idle window can preserve a
        // present `utilization` (e.g. a `{"utilization":0.0,"resets_at":null}` idle body).
        let decoded = try container.decodeIfPresent(UsageWindow.self, forKey: key)

        // A present, well-formed window with its own `resets_at` is the common path — return as-is.
        if let decoded, decoded.hasResetsAt {
            return (decoded, false)
        }

        // No usable own `resets_at`. Try the `limits[]` fallback next.
        if let fromLimit = limits.first(where: { limitKinds.contains($0.kind) && !$0.resetsAt.isEmpty })?.resetsAt {
            AppLogger.network.notice(
                "synthesized \(key.stringValue, privacy: .public) window on reset boundary (utilization=0, resets_at source=limits[])")
            return (UsageWindow(utilization: 0, resetsAt: fromLimit), false)
        }

        // The `limits[]` chain is exhausted. For `five_hour` this is the honest "no active session"
        // state: no synthesis, no phantom reset — `sessionIdle: true`. Preserve any present utilization
        // (usually 0). No log: idle is a normal steady state, not a boundary event to diagnose.
        guard localEstimateAllowed else {
            return (UsageWindow(utilization: decoded?.utilization ?? 0, resetsAt: ""), true)
        }

        // `seven_day`: the weekly window always exists, so fall back to a local estimate (logged once).
        AppLogger.network.notice(
            "synthesized \(key.stringValue, privacy: .public) window on reset boundary (utilization=0, resets_at source=local-estimate)")
        let resetsAt = Self.isoString(from: ResetClock.nextReset(now: now, window: window))
        return (UsageWindow(utilization: 0, resetsAt: resetsAt), false)
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

// MARK: - ScopedModelWindow

/// One per-model weekly limit extracted from a `weekly_scoped` entry of `limits[]` (#65) —
/// the shape ``PopupLayout`` renders as a bare `"<name>"` row (7-day paced, no suffix). A struct (not a
/// tuple) so test fixtures can compare whole arrays via `Equatable`.
public struct ScopedModelWindow: Sendable, Equatable {
    /// `scope.model.display_name`, e.g. `"Fable"` — the only model identity the API provides.
    public let name: String
    /// The entry reshaped as a window: `percent` → `utilization`, `resets_at` kept raw (or
    /// borrowed from `seven_day` — see ``UsageSnapshot/scopedModelWindows``).
    public let window: UsageWindow

    public init(name: String, window: UsageWindow) {
        self.name = name
        self.window = window
    }
}

extension UsageSnapshot {
    /// Per-model weekly limits that exist **only** as `weekly_scoped` entries of `limits[]`
    /// (e.g. Fable, which has no top-level `seven_day_fable` window — #65), in API order.
    ///
    /// Entries whose model name matches a **present** legacy sub-window (`seven_day_opus`/
    /// `seven_day_sonnet`) are skipped, case-insensitively: live bodies carry Sonnet in *both*
    /// forms at once, and the legacy field wins — its `utilization` has decimals where the
    /// entry's `percent` is an integer. The same set also drops duplicate scoped entries.
    ///
    /// An entry with an empty `resets_at` borrows `seven_day`'s — the scoped limits reset on the
    /// weekly cadence, mirroring the `subWindow` borrow above. The borrow here is silent: this
    /// property runs on every popup render, not once per poll, so logging it would flood the
    /// `network` category (`docs/log-messages.md` discipline).
    public var scopedModelWindows: [ScopedModelWindow] {
        var seen: Set<String> = []
        if sevenDayOpus != nil { seen.insert("opus") }
        if sevenDaySonnet != nil { seen.insert("sonnet") }
        var result: [ScopedModelWindow] = []
        for limit in limits where limit.kind == "weekly_scoped" {
            guard let name = limit.modelDisplayName, !name.isEmpty,
                  seen.insert(name.lowercased()).inserted else { continue }
            let resetsAt = limit.resetsAt.isEmpty ? sevenDay.resetsAt : limit.resetsAt
            result.append(ScopedModelWindow(
                name: name,
                window: UsageWindow(utilization: limit.percent, resetsAt: resetsAt)))
        }
        return result
    }
}
