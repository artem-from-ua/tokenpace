import Foundation

// MARK: - CodexQuotaError

/// Why a Codex quota read failed. Mapped onto ``FailureReason`` by ``FailureReason/init(_:)`` — the
/// popup's vocabulary gains no case for this provider, so a Codex failure explains itself in words
/// the user already met on the Claude side.
public enum CodexQuotaError: Error, Sendable, Equatable {
    /// No `codex` executable at any candidate path.
    case cliNotFound
    /// The process started but `initialize` never answered, or answered unusably.
    case handshakeFailed
    /// The child exited while a request was outstanding.
    case processDied
    /// No response carrying our `id` arrived inside the bounded wait.
    case timedOut
    /// This `codex` predates the method. Detected on the pair described in
    /// ``isUnsupportedMethod(code:message:method:)``, never on the code alone.
    case methodUnsupported(method: String)
    /// The read succeeded in protocol terms but reported no account.
    case notSignedIn
    /// A JSON-RPC `error` object that is none of the above.
    case rpc(code: Int, message: String)
    /// A response whose `result` did not decode, or a line that was not JSON-RPC at all.
    case malformedResponse

    /// Whether a JSON-RPC error says "this build has no such method".
    ///
    /// The server answers an unknown method with **`-32600`**, not the `-32601` the spec reserves
    /// for it (probed, codex-cli 0.148.0), and it enumerates every method it does know in the
    /// message. Both halves are required: `-32600` alone is a generic invalid-request that a
    /// malformed `params` struct returns too, so keying on the code by itself would report a bug in
    /// our own request as an out-of-date Codex and send the user to upgrade something that is fine.
    public static func isUnsupportedMethod(code: Int, message: String, method: String) -> Bool {
        code == -32600 && message.contains(method)
    }
}

// MARK: - FailureReason from CodexQuotaError

extension FailureReason {
    /// Map a Codex quota failure onto the popup's existing vocabulary. Exhaustive, no `default`, so
    /// a new ``CodexQuotaError`` case must be mapped consciously rather than bucketed into
    /// `.unknown`.
    ///
    /// **No new `FailureReason` case.** Every distinction this enum draws is one the user already
    /// meets on the Claude side, and the sentences are assembled at the view's localisation seam —
    /// a parallel Codex vocabulary would double that seam to say the same things.
    public init(_ error: CodexQuotaError) {
        switch error {
        case .notSignedIn:
            self = .notSignedIn
        case .cliNotFound:
            // The Claude side spells the missing-binary case this way too: the delegated refresh
            // reports `cliNotFound` and the popup says the credentials cannot be renewed. Here the
            // absent binary is likewise the reason no account can be read.
            self = .notSignedIn
        case .timedOut:
            self = .timeout
        case let .rpc(_, message):
            self = .network(message)
        case .handshakeFailed, .processDied:
            self = .serverProblem
        case .methodUnsupported, .malformedResponse:
            self = .unknown
        }
    }
}

// MARK: - CodexRateLimitsResult

/// The `account/rateLimits/read` result, decoded down to the fields the bars need.
///
/// Reads **`rateLimits`**, not `rateLimitsByLimitId.codex`. The two are byte-identical in a live
/// capture, and `rateLimits` is the stable spelling — the keyed map is indexed by a limit id that is
/// the server's to rename.
///
/// `rateLimitResetCredits` is deliberately absent from this type: it carries a grant id, and nothing
/// on screen asks for one.
public struct CodexRateLimitsResult: Sendable, Equatable, Decodable {
    public let rateLimits: CodexRateLimits?

    public init(rateLimits: CodexRateLimits?) {
        self.rateLimits = rateLimits
    }

    private enum CodingKeys: String, CodingKey { case rateLimits }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.rateLimits = try c.decodeIfPresent(CodexRateLimits.self, forKey: .rateLimits)
    }
}

/// One account's limit buckets.
public struct CodexRateLimits: Sendable, Equatable, Decodable {
    public let primary: CodexRateLimitWindow?
    /// Null on the live Plus account probed. The normalizer emits a row per non-nil window, so a
    /// second one appears the day the server sends it — no code change, and the two-window stub is
    /// what proves that path before then.
    public let secondary: CodexRateLimitWindow?
    /// `"plus"`, `"pro"`, … — the raw plan word, title-cased for the plate header by
    /// ``codexPlanLabel(planType:)``.
    public let planType: String?

    public init(primary: CodexRateLimitWindow?, secondary: CodexRateLimitWindow?,
                planType: String?) {
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
    }

    private enum CodingKeys: String, CodingKey { case primary, secondary, planType }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.primary = try c.decodeIfPresent(CodexRateLimitWindow.self, forKey: .primary)
        self.secondary = try c.decodeIfPresent(CodexRateLimitWindow.self, forKey: .secondary)
        self.planType = try c.decodeIfPresent(String.self, forKey: .planType)
    }
}

/// One rolling window: how much is spent, how long the window is, and when it resets.
public struct CodexRateLimitWindow: Sendable, Equatable, Decodable {
    /// Percent in [0, 100], the same unit Anthropic's `utilization` uses.
    public let usedPercent: Double
    /// The window length **in minutes** — the server's number, and the reason durations reach
    /// `PacingModel` as raw seconds rather than as `LimitWindow` cases. 10080 on the live account.
    public let windowDurationMins: Int
    /// **Epoch seconds**, where every Anthropic reset is an ISO-8601 string. The one real format
    /// difference between the two providers; converted here so nothing downstream sees it.
    public let resetsAt: TimeInterval?

    public init(usedPercent: Double, windowDurationMins: Int, resetsAt: TimeInterval?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }

    /// The reset instant, or `nil` when the server omitted it — the row then renders its
    /// "resetting…" fallback rather than a fabricated date.
    public var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: $0) } }

    public var durationSeconds: Int { windowDurationMins * 60 }
}

// MARK: - codexPlanLabel

/// The plan word for the plate header: `"plus"` → `"Plus"`.
///
/// Title-cases whatever arrives rather than whitelisting known plans, unlike
/// ``claudePlanLabel(rateLimitTier:)``. The two answer different questions. Anthropic's tier is an
/// opaque identifier (`default_claude_max_5x`) that must be *decoded* into a plan name, and third-party
/// clients disagree on what some of them mean — so a guess there renders a wrong plan in brand
/// colour. `planType` is already the plan name; an unrecognised one is a plan we have not seen, not a
/// string we might be misreading.
public func codexPlanLabel(planType: String?) -> String? {
    guard let planType, !planType.isEmpty else { return nil }
    return planType.prefix(1).uppercased() + planType.dropFirst()
}

// MARK: - CodexQuotaSnapshot

/// One successful quota read, in provider-neutral terms.
public struct CodexQuotaSnapshot: Sendable, Equatable {
    /// Every window the server reported, in the order it reported them. **One entry today**; the
    /// count is the server's and nothing here assumes it.
    public let windows: [CodexQuotaWindow]
    /// `"Plus"`, or `nil` when the server named no plan (the header then reads a bare "Codex").
    public let planLabel: String?

    public init(windows: [CodexQuotaWindow], planLabel: String?) {
        self.windows = windows
        self.planLabel = planLabel
    }
}

/// One window from a quota read, before it becomes a drawable row.
public struct CodexQuotaWindow: Sendable, Equatable {
    public let utilization: Double
    public let durationSeconds: Int
    public let resetsAt: Date?

    public init(utilization: Double, durationSeconds: Int, resetsAt: Date?) {
        self.utilization = utilization
        self.durationSeconds = durationSeconds
        self.resetsAt = resetsAt
    }

    /// How far `resetsAt` may sit from `now + durationSeconds` and still read as "the window has not
    /// started": **±120 s**.
    ///
    /// The budget it has to cover is the gap between the server computing its own `now` and us
    /// reading ours — one `account/rateLimits/read` is a 0.44 s round trip (measured, codex-cli
    /// 0.148.0) behind a spawn that may be retried once — plus local clock skew against the server's.
    /// The ceiling is the 180 s poll interval: a tolerance below it can misread at most **one** poll
    /// of a genuinely anchored window, and that is the poll in which the window really has just
    /// opened, so both readings agree there.
    public static let notStartedTolerance: TimeInterval = 120

    /// Whether this window has **not started yet** — the server is answering "if you began now, it
    /// would end then" rather than naming an instant.
    ///
    /// Measured on a live Plus account (codex-cli 0.148.0): three reads spanning 13 s returned
    /// `usedPercent 0` with `resetsAt` at `now + 604 800 s` each time, and the value itself advanced
    /// 13 s — second-for-second with the clock. Rendered as an instant it is a 7-day countdown that
    /// never ticks down. The anchored form exists on the same account — `usedPercent 3` against a reset
    /// fixed at an arbitrary wall-clock second — which is what says the window is **rolling**: it
    /// starts on the first spend after a reset and runs `durationSeconds` from there, so there is no
    /// weekly grid to roll an anchor forward on.
    ///
    /// Two conditions, and the conjunction is what makes a single sample enough:
    /// - the reset sits a whole ``durationSeconds`` ahead, within ``notStartedTolerance``;
    /// - nothing is spent. Spending is the contradiction that rules out a real window this far off —
    ///   3 % of a window that has not started cannot exist.
    ///
    /// Requiring the shape to hold across consecutive polls was the alternative. It would render the
    /// sliding countdown for one full poll every time a window really does reset, to rule out a case
    /// `utilization == 0` already rules out, and it would need state that has nowhere to live: the
    /// quota is not journalled and this decision is a pure function of one payload.
    public func hasNotStarted(now: Date) -> Bool {
        guard utilization == 0, durationSeconds > 0, let resetsAt else { return false }
        let ahead = resetsAt.timeIntervalSince(now)
        return abs(ahead - Double(durationSeconds)) <= Self.notStartedTolerance
    }
}

// MARK: - CodexQuotaNormalizer

/// Turns a decoded `account/rateLimits/read` into ``CodexQuotaSnapshot``, and that into the popup's
/// ``LimitRow``s.
public enum CodexQuotaNormalizer {

    /// Normalize a decoded result, or throw when it carries no account.
    ///
    /// **A missing `rateLimits` is how "not signed in" is detected.** `account/read` would answer it
    /// directly and is never called: it returns the account **email in the clear**, which nothing on
    /// screen or in the journal has any use for. Reading the limits answers the same question as a
    /// side effect of the request already being made.
    public static func snapshot(from result: CodexRateLimitsResult) throws -> CodexQuotaSnapshot {
        guard let limits = result.rateLimits else { throw CodexQuotaError.notSignedIn }
        let windows = [limits.primary, limits.secondary]
            .compactMap { $0 }
            .filter { $0.windowDurationMins > 0 }
            .map {
                CodexQuotaWindow(
                    utilization: min(100, max(0, $0.usedPercent)),
                    durationSeconds: $0.durationSeconds,
                    resetsAt: $0.resetDate)
            }
        guard !windows.isEmpty else { throw CodexQuotaError.notSignedIn }
        return CodexQuotaSnapshot(
            windows: windows, planLabel: codexPlanLabel(planType: limits.planType))
    }

    /// The popup rows for one snapshot, one per reported window.
    ///
    /// **A 5-hour row is never synthesized.** The symmetry with Claude — whose plate always carries a
    /// 5-hour bar above its 7-day one — makes adding one the obvious move, and it would be a drawn
    /// bar for a limit this server does not report, under a reset date invented to fill the field.
    /// Codex reports the windows it has; the plate shows those and no others.
    public static func rows(from snapshot: CodexQuotaSnapshot, now: Date) -> [LimitRow] {
        snapshot.windows.map { window in
            if window.hasNotStarted(now: now) { return notStartedRow(for: window) }
            let resetsAt = window.resetsAt ?? now
            let bar = PacingModel.barLayout(
                utilization: window.utilization,
                resetsAt: resetsAt,
                now: now,
                windowDurationSeconds: window.durationSeconds,
                // No cross-window gate to apply: Claude's 5-hour bar asks its own 7-day bar whether
                // there is room to push, and Codex's windows are not slices of one another.
                blueAllowed: true)
            return LimitRow(
                title: title(forDurationSeconds: window.durationSeconds),
                utilization: window.utilization,
                pacing: bar.pacing,
                indicator: PacingModel.limitIndicator(utilization: window.utilization),
                bar: bar,
                subdivisions: PacingModel.subdivisions(forWindowDurationSeconds:
                                                        window.durationSeconds),
                resetLine: window.resetsAt.flatMap {
                    ResetClock.resetLine(resetsAt: $0, now: now)
                },
                resetLineVerbose: window.resetsAt.flatMap {
                    ResetClock.resetLine(resetsAt: $0, now: now, verbose: true)
                })
        }
    }

    /// The row for a window that has not started (``CodexQuotaWindow/hasNotStarted(now:)``): the
    /// title and the tick ruler its length earns, `sessionIdle: true`, and **no reset line**.
    ///
    /// `sessionIdle` is Claude's shape for the same fact — no window exists server-side, so there is
    /// nothing to pace and nothing to count down to — and the view already answers it with a green
    /// knobless track, the status word "ready to start", and no detail line at all. Reaching for it
    /// here is what keeps a state the user has already met from arriving in a second dialect.
    ///
    /// The reset line has to go **with** the detail line, not on its own: `LimitRow.resetLine == nil`
    /// renders as `"resetting…"`, which claims a reset is happening this second — a second false
    /// statement in place of the sliding one, and no improvement on it.
    ///
    /// The bar is inert. `.onPaceOrBehind` makes `severity` read `.calm` before `remainingSeconds` is
    /// consulted, so the zeroes below are never drawn from.
    static func notStartedRow(for window: CodexQuotaWindow) -> LimitRow {
        LimitRow(
            title: title(forDurationSeconds: window.durationSeconds),
            utilization: 0,
            pacing: .onPaceOrBehind,
            indicator: .neutral,
            bar: BarLayout(
                usageFraction: 0, timeFraction: 0, pacing: .onPaceOrBehind, remainingSeconds: 0,
                windowDurationSeconds: window.durationSeconds, blueAllowed: false),
            subdivisions: PacingModel.subdivisions(
                forWindowDurationSeconds: window.durationSeconds),
            resetLine: nil,
            sessionIdle: true)
    }

    /// The row's heading, named after its length so the two providers' weeks read alike: `"7-day"`
    /// where Claude says `"7-day"`.
    ///
    /// Falls back to a whole number of hours, then minutes, for a length the table does not name —
    /// the server chooses these, so an unnamed one is a shape to render rather than an error.
    public static func title(forDurationSeconds duration: Int) -> String {
        switch duration {
        case LimitWindow.fiveHour.durationSeconds: return "5-hour"
        case LimitWindow.sevenDay.durationSeconds: return "7-day"
        default: break
        }
        if duration >= 86_400, duration % 86_400 == 0 { return "\(duration / 86_400)-day" }
        if duration >= 3_600, duration % 3_600 == 0 { return "\(duration / 3_600)-hour" }
        return "\(max(1, duration / 60))-minute"
    }
}
