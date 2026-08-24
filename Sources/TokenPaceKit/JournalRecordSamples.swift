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
    /// - **5** — #502: ``provider`` names whose quota the line measures. Nothing else moves, and
    ///   ``sevV`` deliberately does not: the colour model is unchanged.
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
    /// Whose quota this line measures (``ProviderID``, a journal-stable snake_case string).
    ///
    /// Stored as `String` rather than the enum so a line written by a build that knows a provider
    /// this one does not still decodes, instead of failing the whole record.
    public let provider: String
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
    public static let currentVersion = 5

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
        provider: String = ProviderID.claude.rawValue,
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
        self.provider = provider
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
        case v, sevV, provider, t, ms, plan, tier, h5, d7, opus, sonnet, scoped, sessionIdle, spend
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
        // The Claude fallback exists for lines a rewrite cannot reach — a `.v4.bak`, a line pasted
        // into a bug report — not as a policy: the migration writes the key onto every stored line.
        self.provider = try c.decodeIfPresent(String.self, forKey: .provider)
            ?? ProviderID.claude.rawValue
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
    /// The `status`-line **format** version — its own counter, independent of ``UsageSample/v``.
    ///
    /// Two kinds, two generations: a `status` line and a `usage` line share a file but not a shape, and
    /// a single counter would force one to bump whenever the other changed. So `v: 2` on a `status`
    /// line and `v: 4` on a `usage` line describe unrelated things, and a reader must dispatch on
    /// `kind` before reading `v` at all.
    ///
    /// Per **line**, not per file, for the same reason ``UsageSample/v`` is: the journal is append-only
    /// and spans app upgrades, so one file legitimately holds several generations and a header could
    /// only ever describe its first line.
    ///
    /// - **1** — the original shape (implicit: absent `v` decodes as 1). No provider key; every such
    ///   line came from `status.claude.com`, but nothing in it says so.
    /// - **2** — #456: ``provider`` names the status page the line describes, and `worst` is that
    ///   provider's own worst-of rather than a flatten across whatever else was being monitored.
    public let v: Int
    public let t: String
    /// Which status page this line came from (``ProviderID``, a journal-stable snake_case string).
    ///
    /// Written explicitly on every line since v2, and backfilled onto every archived one, so no
    /// consumer ever needs an "absent means Claude" branch — the branch that, per the ``JournalMigration``
    /// rationale, the first forgetful reader turns into two series silently merged into one.
    public let provider: String
    /// Raw components: `[{n: name, s: rawStatus}]`.
    ///
    /// The **whole feed** of ``provider``'s status page, not the subset the user was monitoring
    /// (ADR-0119). Six components for Claude today. Recording the page verbatim keeps the line
    /// self-describing: which services were monitored is a *setting*, it is not in the line, and it
    /// changes under the user's hand — so a narrowed `svc` would silently change meaning between two
    /// lines that look alike. `worst`, by contrast, **is** the monitored-set answer, so the pair
    /// carries both facts without either standing in for the other.
    public let svc: [ServiceEntry]
    /// ``StatusHealth/worstProblem(for:)`` over **this provider's** checks, mapped to a
    /// ``ServiceStatus`` raw value (or `operational` when nothing is wrong) — the value that drives
    /// this provider's status-dot colour.
    ///
    /// Per provider, not flattened across all of them: a `status` line describes one page, and a
    /// worst-of-both would attribute another provider's outage to this one (#454 §2b).
    ///
    /// Note this is the aggregate over the **monitored** services, while ``svc`` is the whole feed —
    /// the two answer different questions on purpose.
    public let worst: String

    /// The version this build writes. Bump together with the case list on ``v``.
    public static let currentVersion = 2

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

    public init(
        v: Int = StatusSample.currentVersion,
        t: String,
        provider: String = ProviderID.claude.rawValue,
        svc: [ServiceEntry],
        worst: String
    ) {
        self.v = v
        self.t = t
        self.provider = provider
        self.svc = svc
        self.worst = worst
    }

    private enum CodingKeys: String, CodingKey { case v, t, provider, svc, worst }

    /// Tolerant decode — every field defaults, so an old line never fails and a newer one never breaks
    /// this reader.
    ///
    /// The `provider` default is the one place "absent means Claude" is still written down, and it is
    /// deliberately **not** the policy the archive relies on: the migration backfills the key onto every
    /// stored line, so after one pass no file on disk exercises this branch. It survives for the cases a
    /// rewrite cannot reach — a `.v1.bak`, a line pasted into a bug report, a journal copied from a
    /// machine that has not launched the new build yet — where decoding to *something* honest beats
    /// failing the record.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An absent `v` is a v1 status line — the field did not exist before #456.
        self.v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        self.t = try c.decodeIfPresent(String.self, forKey: .t) ?? ""
        self.provider = try c.decodeIfPresent(String.self, forKey: .provider)
            ?? ProviderID.claude.rawValue
        self.svc = try c.decodeIfPresent([ServiceEntry].self, forKey: .svc) ?? []
        self.worst = try c.decodeIfPresent(String.self, forKey: .worst) ?? "operational"
    }
}

// MARK: - ErrorSample

/// A failed usage poll as journalled — enough to tell 429 (client) from 5xx (server) from a
/// malformed body, plus the retry-after hint and the request latency.
public struct ErrorSample: Sendable, Equatable, Codable {
    /// Which provider's poll failed (``ProviderID``, a journal-stable snake_case string). A `String`
    /// for the reason ``UsageSample/provider`` is one.
    ///
    /// Part of a run's identity, so two providers failing identically never fold into one line
    /// (``ErrorRunCollapse/admit(_:sample:at:)``).
    public let provider: String
    public let t: String
    /// HTTP status as a number (`429`/`503`/…) when a response arrived, or a non-HTTP category string
    /// (`"timeout"`/`"dns"`/`"network"`/`"decode"`/`"nonHTTP"`/`"notSent"`). Encoded as a JSON value
    /// that is either an integer or a string — see ``ErrorCode``.
    public let code: ErrorCode
    /// The journal error taxonomy (distinct from the UI's `FailureReason`): 4xx→`clientProblem`,
    /// 5xx→`serverProblem`, decode→`decode`, auth→`auth`, plus the transport categories.
    public let reason: String
    /// A `.public`-safe refinement of ``reason`` — `"token expired"`, `"keychain access denied"`,
    /// `"not signed in"`, `"keychain read failed"`, `"malformed credentials"`, `"missing User-Agent"`.
    ///
    /// Deliberately **not** folded into `reason`: that field is a closed taxonomy every downstream
    /// count groups by, and a free-text value in it would silently split one bucket into six. The
    /// detail was produced all along and shown in the Troubleshoot window, but dropped on the way to
    /// the journal — so a 122 408-line outage recorded that the request was not sent and never why
    /// (ADR-0123). `nil` for codes with no refinement to offer.
    public let detail: String?
    /// `Retry-After` seconds, only on 429; `nil` otherwise.
    public let retryAfter: TimeInterval?
    /// Usage-API response latency in milliseconds, or `nil` when the request was never sent.
    public let ms: Int?
    /// How many consecutive identical attempts this line stands for; absent means one.
    ///
    /// **A reader counting failures must sum `n ?? 1`, never count lines** — consecutive identical
    /// failures are written once, so a line count reads a two-hour outage as a handful of events.
    public let n: Int?
    /// The last attempt's instant when this line collapses several; ``t`` is the first.
    ///
    /// `tEnd - t` is the run's *duration*, not the spacing between attempts: the individual instants
    /// inside a run are not kept.
    public let tEnd: String?
    /// The version this build writes. Bump together with the shape.
    public static let currentVersion = 3
    /// This line's own format counter — unrelated to ``UsageSample/v`` and ``StatusSample/v``.
    /// v1 predates ``detail``/``n``/``tEnd``, v2 predates ``provider``; an absent `v` decodes as 1.
    public let v: Int

    public init(
        t: String, code: ErrorCode, reason: String, detail: String? = nil,
        retryAfter: TimeInterval? = nil, ms: Int? = nil,
        n: Int? = nil, tEnd: String? = nil, v: Int = ErrorSample.currentVersion,
        provider: String = ProviderID.claude.rawValue
    ) {
        self.provider = provider
        self.t = t
        self.code = code
        self.reason = reason
        self.detail = detail
        self.retryAfter = retryAfter
        self.ms = ms
        self.n = n
        self.tEnd = tEnd
        self.v = v
    }

    private enum CodingKeys: String, CodingKey {
        case t, code, reason, detail, retryAfter, ms, n, tEnd, v, provider
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Same fallback discipline as ``UsageSample/provider``: for the lines a rewrite cannot reach.
        self.provider = try c.decodeIfPresent(String.self, forKey: .provider)
            ?? ProviderID.claude.rawValue
        self.t = try c.decodeIfPresent(String.self, forKey: .t) ?? ""
        self.code = try c.decodeIfPresent(ErrorCode.self, forKey: .code) ?? .category("unknown")
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? "unknown"
        self.detail = try c.decodeIfPresent(String.self, forKey: .detail)
        self.retryAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .retryAfter)
        self.ms = try c.decodeIfPresent(Int.self, forKey: .ms)
        self.n = try c.decodeIfPresent(Int.self, forKey: .n)
        self.tEnd = try c.decodeIfPresent(String.self, forKey: .tEnd)
        // An absent `v` is a v1 error line — the field did not exist before ADR-0123.
        self.v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
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
    /// This shape's own format counter — unrelated to every other kind's `v`.
    ///
    /// - **0** — the original shape, which carried no counter at all. An absent `v` reads as **0**,
    ///   not 1: the field never existed here, so there is no generation "1" to claim. Same argument
    ///   as ``UsageSample/sevV``, and it makes the migration predicate `v < currentVersion` read
    ///   identically for all four kinds.
    /// - **1** — #502: ``provider`` names whose observation gap this marks.
    public let v: Int
    /// Whose gap this is (``ProviderID``, a journal-stable snake_case string). A `String` for the
    /// reason ``UsageSample/provider`` is one.
    ///
    /// Each provider's writer keeps its own gap clock, so one provider's polling can never suppress
    /// another's marker and read an outage as continuous observation.
    public let provider: String
    /// Timestamp of the first poll after the gap.
    public let t: String
    /// The gap length in seconds (`now − previous`).
    public let gap: TimeInterval

    /// The version this build writes. Bump together with the case list on ``v``.
    public static let currentVersion = 1

    public init(
        t: String, gap: TimeInterval,
        v: Int = ResumeMarker.currentVersion,
        provider: String = ProviderID.claude.rawValue
    ) {
        self.v = v
        self.provider = provider
        self.t = t
        self.gap = gap
    }

    private enum CodingKeys: String, CodingKey { case t, gap, v, provider }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 0
        // Same fallback discipline as ``UsageSample/provider``: for the lines a rewrite cannot reach.
        self.provider = try c.decodeIfPresent(String.self, forKey: .provider)
            ?? ProviderID.claude.rawValue
        self.t = try c.decodeIfPresent(String.self, forKey: .t) ?? ""
        self.gap = try c.decodeIfPresent(TimeInterval.self, forKey: .gap) ?? 0
    }
}
