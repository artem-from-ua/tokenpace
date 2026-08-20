import Foundation

// MARK: - UsageSample

/// A successful usage poll as journalled — every window, the credits state, and the derived UI
/// states, so downstream analytics never has to recompute what the app already showed.
public struct UsageSample: Sendable, Equatable, Codable {
    /// The sample-**format** version, written on every line and bumped monotonically whenever the set
    /// of fields or the meaning of one of them changes.
    ///
    /// Since v4 this is one of **two** version counters, and the split is deliberate: `v` answers "how
    /// do I read this line", ``sevV`` answers "which colour model decided its verdicts". A colour
    /// threshold can move without a single key changing shape, and folding that into `v` would force a
    /// format bump for a purely semantic change — and, worse, leave no way to ask "is this line's `sev`
    /// current?" without knowing which `v` happened to ship which thresholds.
    ///
    /// Carried per line rather than once per file because the journal is append-only and spans
    /// upgrades: a single file legitimately holds lines from several app versions, so a header could
    /// only ever describe the first of them. With `v` on the line, a reader knows how to interpret it
    /// without inferring anything from which keys happen to be present.
    ///
    /// - **1** — the original shape (implicit: absent `v` decodes as 1). `util` was the API's value;
    ///   `gap` was a stored field.
    /// - **2** — #386: `util` carries the value the app **acted on** (reconstructed for `seven_day`),
    ///   `raw` carries the API's; `src`/`n` describe the reconstruction; `gap` is derived, not stored.
    /// - **3** — ADR-0107: `src` is renamed `utilSrc` and joined by `resetSrc`, because the *date*
    ///   can now be reconstructed too and one field could not answer for both axes. Migration also
    ///   **rewrites** `reset` and `timePct` on lines written during a weekly API blackout: those
    ///   carried a `now + 7d` estimate that crept forward every poll, pinning `timePct` to 0 for
    ///   hours. Recovering them is what makes the archived series usable — the marker in those lines
    ///   never moved, so any analysis over them was reading a flat line that never happened.
    /// - **4** — #426: every window's `sev` is recomputed by the **current** colour model and stamped
    ///   with ``sevV``; the value written at poll time survives as `sevRaw` on the windows where the
    ///   two disagree. Adds the field, so it is a format bump as well as a colour-model one.
    public let v: Int
    /// Which generation of the **colour model** produced this line's `sev` values — the second axis
    /// described on ``v``.
    ///
    /// One number for the whole line, not per window: a poll evaluates every window through the same
    /// thresholds at the same instant, so six copies could only ever agree, and the day they did not
    /// would be a bug rather than information.
    ///
    /// `0` on lines written before the field existed, mirroring how an absent `v` reads as 1: both say
    /// "older than the first generation that named itself". That is what makes a re-run cheap to scope
    /// — migrate the lines whose `sevV` is below ``currentColorVersion``, leave the rest alone.
    public let sevV: Int
    /// Poll timestamp (ISO-8601, UTC, no fractional seconds — ``ResetClock/isoString(from:)``).
    public let t: String
    /// Usage-API response latency in milliseconds, or `nil` when unmeasured.
    public let ms: Int?
    /// Plan tier from the Keychain (`subscriptionType`, e.g. `"max"`), or `nil`. Not a secret — lets a
    /// reading be attributed to a plan (limits/pacing differ by plan).
    public let plan: String?
    /// Rate-limit tier from the Keychain (`rateLimitTier`, e.g. `"default_claude_max_5x"`), or `nil`.
    public let tier: String?
    public let h5: WindowSample
    public let d7: WindowSample
    public let opus: WindowSample?
    public let sonnet: WindowSample?
    public let scoped: [ScopedSample]
    public let sessionIdle: Bool
    public let spend: SpendSample?
    /// ``CreditsPacing/isBlocked(in:)`` — no path to work (`mainWindowExhausted` & credits can't cover).
    public let blocked: Bool
    public let credits: CreditsFlags
    /// ``UsageSnapshot/hasBrokenActiveReset`` — active window with an unparseable reset (⚠️ error).
    public let brokenReset: Bool
    /// ``BlockingReset/Choice`` — which reset is the blocked countdown, or `nil` when not blocked.
    public let blockingReset: BlockingResetSample?

    /// The version this build writes. Bump together with the case list on ``v``.
    public static let currentVersion = 4

    /// The colour-model generation this build writes into ``sevV``. Bump it whenever a change to
    /// ``PacingBucket``/``PacingModel`` would give an existing sample a different `sev` — that is the
    /// signal ``JournalMigration`` uses to decide which archived lines need recomputing.
    ///
    /// **1** — the model as of #426: dynamic ahead-threshold (ADR-0044), fixed-width behind-threshold
    /// (ADR-0061), weekly-capacity gate on the 5-hour bar (ADR-0081), and no blue on per-model windows.
    public static let currentColorVersion = 1

    public init(
        v: Int = UsageSample.currentVersion,
        sevV: Int = UsageSample.currentColorVersion,
        t: String,
        ms: Int? = nil,
        plan: String? = nil,
        tier: String? = nil,
        h5: WindowSample,
        d7: WindowSample,
        opus: WindowSample? = nil,
        sonnet: WindowSample? = nil,
        scoped: [ScopedSample] = [],
        sessionIdle: Bool = false,
        spend: SpendSample? = nil,
        blocked: Bool = false,
        credits: CreditsFlags,
        brokenReset: Bool = false,
        blockingReset: BlockingResetSample? = nil
    ) {
        self.v = v
        self.sevV = sevV
        self.t = t
        self.ms = ms
        self.plan = plan
        self.tier = tier
        self.h5 = h5
        self.d7 = d7
        self.opus = opus
        self.sonnet = sonnet
        self.scoped = scoped
        self.sessionIdle = sessionIdle
        self.spend = spend
        self.blocked = blocked
        self.credits = credits
        self.brokenReset = brokenReset
        self.blockingReset = blockingReset
    }

    private enum CodingKeys: String, CodingKey {
        case v, sevV, t, ms, plan, tier, h5, d7, opus, sonnet, scoped, sessionIdle, spend
        case blocked, credits, brokenReset, blockingReset
    }

    /// Tolerant decode — a partial line (an older/newer schema) fills defaults rather than failing.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An absent `v` is a v1 line — the field did not exist before #386.
        self.v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        // Absent means "written before any colour model named itself" — see the field's doc. Not 1:
        // that number is claimed by the model #426 shipped, and a v1 line has no claim to it.
        self.sevV = try c.decodeIfPresent(Int.self, forKey: .sevV) ?? 0
        self.t = try c.decodeIfPresent(String.self, forKey: .t) ?? ""
        self.ms = try c.decodeIfPresent(Int.self, forKey: .ms)
        self.plan = try c.decodeIfPresent(String.self, forKey: .plan)
        self.tier = try c.decodeIfPresent(String.self, forKey: .tier)
        self.h5 = try c.decodeIfPresent(WindowSample.self, forKey: .h5)
            ?? WindowSample(util: 0, reset: "", timePct: 0, sev: .green)
        self.d7 = try c.decodeIfPresent(WindowSample.self, forKey: .d7)
            ?? WindowSample(util: 0, reset: "", timePct: 0, sev: .green)
        self.opus = try c.decodeIfPresent(WindowSample.self, forKey: .opus)
        self.sonnet = try c.decodeIfPresent(WindowSample.self, forKey: .sonnet)
        self.scoped = try c.decodeIfPresent([ScopedSample].self, forKey: .scoped) ?? []
        self.sessionIdle = try c.decodeIfPresent(Bool.self, forKey: .sessionIdle) ?? false
        self.spend = try c.decodeIfPresent(SpendSample.self, forKey: .spend)
        self.blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked) ?? false
        self.credits = try c.decodeIfPresent(CreditsFlags.self, forKey: .credits)
            ?? CreditsFlags(active: false, showIcon: false, onCredits: false)
        self.brokenReset = try c.decodeIfPresent(Bool.self, forKey: .brokenReset) ?? false
        self.blockingReset = try c.decodeIfPresent(BlockingResetSample.self, forKey: .blockingReset)
    }
}

// MARK: - StatusSample

/// A successful service-status poll as journalled — the raw per-component statuses plus the derived
/// worst-of, tagged as its own `kind` because status rides a separate poll loop from usage.
public struct StatusSample: Sendable, Equatable, Codable {
    public let t: String
    /// Raw components: `[{n: name, s: rawStatus}]`.
    public let svc: [ServiceEntry]
    /// ``StatusHealth/worstProblem`` mapped to a ``ServiceStatus`` raw value (or `operational` when
    /// nothing is wrong) — the value that drives the menu-bar status-dot colour.
    public let worst: String

    public struct ServiceEntry: Sendable, Equatable, Codable {
        public let n: String
        public let s: String
        public init(n: String, s: String) { self.n = n; self.s = s }

        private enum CodingKeys: String, CodingKey { case n, s }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.n = try c.decodeIfPresent(String.self, forKey: .n) ?? ""
            self.s = try c.decodeIfPresent(String.self, forKey: .s) ?? ""
        }
    }

    public init(t: String, svc: [ServiceEntry], worst: String) {
        self.t = t
        self.svc = svc
        self.worst = worst
    }

    private enum CodingKeys: String, CodingKey { case t, svc, worst }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.t = try c.decodeIfPresent(String.self, forKey: .t) ?? ""
        self.svc = try c.decodeIfPresent([ServiceEntry].self, forKey: .svc) ?? []
        self.worst = try c.decodeIfPresent(String.self, forKey: .worst) ?? "operational"
    }
}

// MARK: - ErrorSample

/// A failed usage poll as journalled — enough to tell 429 (client) from 5xx (server) from a
/// malformed body, plus the retry-after hint and the request latency.
public struct ErrorSample: Sendable, Equatable, Codable {
    public let t: String
    /// HTTP status as a number (`429`/`503`/…) when a response arrived, or a non-HTTP category string
    /// (`"timeout"`/`"dns"`/`"network"`/`"decode"`/`"nonHTTP"`/`"notSent"`). Encoded as a JSON value
    /// that is either an integer or a string — see ``ErrorCode``.
    public let code: ErrorCode
    /// The journal error taxonomy (distinct from the UI's `FailureReason`): 4xx→`clientProblem`,
    /// 5xx→`serverProblem`, decode→`decode`, auth→`auth`, plus the transport categories.
    public let reason: String
    /// `Retry-After` seconds, only on 429; `nil` otherwise.
    public let retryAfter: TimeInterval?
    /// Usage-API response latency in milliseconds, or `nil` when the request was never sent.
    public let ms: Int?

    public init(t: String, code: ErrorCode, reason: String, retryAfter: TimeInterval? = nil, ms: Int? = nil) {
        self.t = t
        self.code = code
        self.reason = reason
        self.retryAfter = retryAfter
        self.ms = ms
    }

    private enum CodingKeys: String, CodingKey { case t, code, reason, retryAfter, ms }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.t = try c.decodeIfPresent(String.self, forKey: .t) ?? ""
        self.code = try c.decodeIfPresent(ErrorCode.self, forKey: .code) ?? .category("unknown")
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? "unknown"
        self.retryAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .retryAfter)
        self.ms = try c.decodeIfPresent(Int.self, forKey: .ms)
    }
}

/// An error code that is either an HTTP status integer or a non-HTTP category string, encoded as the
/// bare JSON value (a number or a string) so `code` reads naturally in the JSONL.
public enum ErrorCode: Sendable, Equatable, Codable {
    case http(Int)
    case category(String)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) {
            self = .http(n)
        } else {
            self = .category((try? c.decode(String.self)) ?? "unknown")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .http(n): try c.encode(n)
        case let .category(s): try c.encode(s)
        }
    }
}

// MARK: - ResumeMarker

/// A marker written after a sampling gap longer than the expected interval — so a reader can tell
/// "nothing happened" from "we weren't looking" and never interpolate across the hole.
public struct ResumeMarker: Sendable, Equatable, Codable {
    /// Timestamp of the first poll after the gap.
    public let t: String
    /// The gap length in seconds (`now − previous`).
    public let gap: TimeInterval

    public init(t: String, gap: TimeInterval) {
        self.t = t
        self.gap = gap
    }

    private enum CodingKeys: String, CodingKey { case t, gap }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.t = try c.decodeIfPresent(String.self, forKey: .t) ?? ""
        self.gap = try c.decodeIfPresent(TimeInterval.self, forKey: .gap) ?? 0
    }
}
