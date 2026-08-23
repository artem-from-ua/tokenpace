import Foundation

// MARK: - Domain → JournalRecord factories

extension JournalRecord {

    /// Build a `usage` record from a successful poll's snapshot plus the poll instant and latency.
    ///
    /// All the derived states are computed here (in the pure Kit) so the shell stays a thin
    /// serialiser: window pacing via ``PacingModel``/``PacingBucket``, credits via ``CreditsPacing``,
    /// blocked/credits flags, `hasBrokenActiveReset`, and the blocking-reset choice.
    /// - Parameter weekly: the seven-day reconstruction for this poll (#386). Defaults to `nil` so
    ///   fixtures and tests that predate it keep compiling; live polls always pass it.
    public static func usage(
        from snapshot: UsageSnapshot,
        now: Date,
        durationMs: Int? = nil,
        plan: String? = nil,
        tier: String? = nil,
        weekly: WeeklyUtilization? = nil
    ) -> JournalRecord {
        // The weekly gate, hoisted **out** of the `UsageSample(...)` literal below: `d7` is built at the
        // same expression level as `h5`, so the 7-day state has to be resolved before the literal or the
        // 5-hour sample could not see it. Only `h5` reads it now — the per-model rows used to as well —
        // but the ordering constraint is unchanged, and the `let` is what makes it visible.
        //
        // Computed on the **reconstructed** snapshot (#386), not the raw one: the render layer applies
        // that overlay before anything reads the weekly window, so a gate derived from the raw value
        // could disagree with the bar the user was looking at — which is the one thing this line
        // exists to prevent.
        //
        // Matching the gate was never sufficient on its own, though this comment once claimed it was.
        // The popup carried a second gate in the view (`PopupBarView.isBaseLimit`) that forced every
        // per-model row green; the model did not know about it, so this factory recorded scoped blues
        // the user never saw — 2 211 of them on the maintainer's journal. That rule now lives on
        // `BarLayout.blueAllowed` where both sides can read it, and the rows below pass `false`.
        let rendered = weekly?.applied(to: snapshot) ?? snapshot
        let weeklyHeadroom = PacingModel.weeklyHasHeadroom(in: rendered, now: now)

        let credits = CreditsFlags(
            active: rendered.spend.map(CreditsPacing.isActive) ?? false,
            showIcon: rendered.spend.map {
                CreditsPacing.shouldShowIcon($0, baseLimitExhausted: CreditsPacing.anyBaseLimitExhausted(in: rendered))
            } ?? false,
            onCredits: ExtraUsageOnset.isOnCredits(rendered))

        let sample = UsageSample(
            t: ResetClock.isoString(from: now),
            ms: durationMs,
            plan: plan,
            tier: tier,
            h5: window(snapshot.fiveHour, window: .fiveHour, now: now, blueAllowed: weeklyHeadroom),
            // `resetSrc` reads the **rendered** snapshot for the same reason `weeklyHeadroom` does:
            // it must describe the date the user was actually shown. The overlays carry provenance
            // through, and `optimisticReset` can add a `-rolled` suffix the raw snapshot never had.
            d7: window(snapshot.sevenDay, window: .sevenDay, now: now, blueAllowed: true,
                       weekly: weekly, resetSource: rendered.sevenDayResetSource),
            // Per-model rows: `blueAllowed: false` unconditionally — they are slices of the very week
            // the blue advice is about (reason 2 on `BarLayout.blueAllowed`), so it can never apply.
            opus: snapshot.sevenDayOpus.map { window($0, window: .sevenDay, now: now, blueAllowed: false) },
            sonnet: snapshot.sevenDaySonnet.map { window($0, window: .sevenDay, now: now, blueAllowed: false) },
            scoped: snapshot.scopedModelWindows.map { scoped($0, now: now) },
            sessionIdle: snapshot.sessionIdle,
            spend: snapshot.spend.map { SpendSample($0, now: now) },
            // These three read the **rendered** snapshot too, so the record describes one consistent
            // state. In practice they cannot differ — each keys off `>= 100`, and the reconstruction
            // provably never carries a value across that line (ADR-0103) — but "provably equal" is a
            // reason to be consistent, not a reason to mix sources and leave a reader to work it out.
            blocked: CreditsPacing.isBlocked(in: rendered),
            credits: credits,
            brokenReset: rendered.hasBrokenActiveReset,
            blockingReset: BlockingReset.forBlocked(snapshot: rendered, now: now).map(BlockingResetSample.init))
        return .usage(sample)
    }

    /// Build a `status` record from a successful status poll — the raw components plus the derived
    /// worst-of for that provider.
    ///
    /// One record per provider poll: a `status` line describes **one** page and must never become a
    /// union of two (#456). Both halves are scoped to `provider` accordingly, but by different means,
    /// because they answer different questions:
    ///
    /// - `svc` is `summary.components` verbatim — the whole feed of the page that was polled, which is
    ///   already single-provider by construction (a summary *is* one page's response). It is not
    ///   narrowed to the monitored set: what was monitored is a setting the line does not carry, so a
    ///   narrowed feed would change meaning whenever the user flipped a toggle (ADR-0119).
    /// - `worst` is ``StatusHealth/worstProblem(for:)``, **not** the flattening ``StatusHealth/worstProblem``.
    ///   `health.checks` is a single collection across every provider, so the unscoped property would
    ///   turn into a worst-of-both the moment a second page joins it (#454 §2b) — and it would do so
    ///   without this line changing, which is exactly the silent failure the provider tag exists to
    ///   prevent. Deriving it from this provider's own checks makes that impossible rather than
    ///   merely currently-correct.
    public static func status(
        from summary: StatusSummary,
        health: StatusHealth,
        now: Date,
        provider: ProviderID = .claude
    ) -> JournalRecord {
        let svc = summary.components.map { StatusSample.ServiceEntry(n: $0.name, s: $0.status) }
        let worst = health.worstProblem(for: provider) ?? .operational
        return .status(StatusSample(
            t: ResetClock.isoString(from: now),
            provider: provider.rawValue,
            svc: svc,
            worst: journalString(worst)))
    }

    /// Build an `error` record from a failed poll's diagnostics. `code`/`reason` follow the **journal**
    /// taxonomy (not the UI's `FailureReason`): 4xx → `clientProblem`, 5xx → `serverProblem`, a
    /// malformed 200 body → `decode`, 401/403 → `auth`, and the transport outcomes to their own
    /// categories.
    ///
    /// `failure` (the poll's `UsageHealth.reason`) is used **only** to refine the transport bucket into
    /// `timeout`/`dns`/`network` — it already collapsed the `URLError.Code` the raw diagnostic outcome
    /// does not carry. HTTP/decode categories come from the diagnostic status/outcome directly.
    public static func error(diagnostics d: FetchDiagnostics, failure: FailureReason?, now: Date) -> JournalRecord {
        let (code, reason, detail) = errorCodeReasonAndDetail(d, failure: failure)
        return .error(ErrorSample(
            t: ResetClock.isoString(from: now),
            code: code,
            reason: reason,
            detail: detail,
            retryAfter: d.retryAfter,
            ms: d.durationMs))
    }

    // MARK: - Helpers

    /// Journal-stable snake_case string for a ``ServiceStatus`` (mirrors the API's raw values, and
    /// `ServiceStatus.init(rawAPIValue:)` round-trips them). `unknown` is its own honest value.
    private static func journalString(_ status: ServiceStatus) -> String {
        switch status {
        case .operational:      return "operational"
        case .degraded:         return "degraded_performance"
        case .partialOutage:    return "partial_outage"
        case .majorOutage:      return "major_outage"
        case .underMaintenance: return "under_maintenance"
        case .unknown:          return "unknown"
        }
    }

    /// Journal a single window: utilisation, raw reset, elapsed fraction, and the objective bucket.
    /// When the reset parses, the bucket comes from a real ``BarLayout``; when it doesn't (idle/empty
    /// or malformed reset), fall back to exhausted-or-green from utilisation alone (there is no pacing
    /// gap to colour without a reset instant).
    /// - Parameter weekly: the reconstruction for this window (#386), when there is one. Only the
    ///   seven-day window has it; the five-hour and per-model rows pass `nil` and journal the API's
    ///   value as both `util` and `raw`.
    private static func window(_ w: UsageWindow, window kind: LimitWindow, now: Date,
                               blueAllowed: Bool,
                               weekly: WeeklyUtilization? = nil,
                               resetSource: ResetSource? = nil) -> WindowSample {
        // What the app acted on. The bars were drawn from the reconstructed value, so the journal
        // records that as `util` and keeps the API's number beside it — a line must describe the
        // pixels that existed, not a parallel reality.
        let effective = weekly?.effective ?? w.utilization
        let raw = weekly?.raw ?? w.utilization

        guard let resetsAt = ResetClock.parse(w.resetsAt) else {
            // No parseable reset → no pacing gap to colour; `timePct` 0, and `gap` derives to −util.
            return WindowSample(
                util: effective, raw: raw, utilSrc: weekly?.source.rawValue,
                resetSrc: resetSource?.rawValue, n: weekly?.ratio,
                reset: w.resetsAt, timePct: 0, sev: effective >= 100 ? .red : .green,
                windowSeconds: kind.durationSeconds)
        }
        let layout = PacingModel.barLayout(
            utilization: effective, resetsAt: resetsAt, now: now,
            window: kind, blueAllowed: blueAllowed)
        return WindowSample(
            util: effective, raw: raw, utilSrc: weekly?.source.rawValue,
            resetSrc: resetSource?.rawValue, n: weekly?.ratio,
            reset: w.resetsAt, timePct: layout.timeFraction, sev: PacingBucket.of(layout),
            windowSeconds: kind.durationSeconds)
    }

    /// Journal a scoped per-model window — all 7-day-paced, so it borrows the 7-day pacing math, but
    /// **not** the weekly gate: a scoped limit is a slice of the weekly budget, so "the week has spare
    /// capacity" is advice it would be giving about itself. `blueAllowed: false` is therefore fixed,
    /// not a parameter — a caller able to pass `true` is a caller able to reintroduce the very
    /// mismatch this fixed (see reason 2 on ``BarLayout/blueAllowed``).
    ///
    /// Never reconstructed: a scoped window meters different spend and has no five-hour counter of
    /// its own, so a single `N` cannot describe it (ADR-0103).
    private static func scoped(_ s: ScopedModelWindow, now: Date) -> ScopedSample {
        let w = window(s.window, window: .sevenDay, now: now, blueAllowed: false)
        return ScopedSample(name: s.name, pct: s.window.utilization, reset: s.window.resetsAt,
                            timePct: w.timePct, sev: w.sev)
    }

    /// Derive the journal `code`, `reason` and `detail` from a fetch diagnostic (and, for transport
    /// failures, the refined ``FailureReason``). Exhaustive over ``FetchDiagnostics/Outcome``.
    ///
    /// The name lists all three returns on purpose: while it named only two, the third — the
    /// not-sent reason — was quietly dropped on the floor here, and a real journal recorded 122 408
    /// failures that could not say whether the token had expired or the Keychain had refused.
    private static func errorCodeReasonAndDetail(
        _ d: FetchDiagnostics, failure: FailureReason?
    ) -> (ErrorCode, String, String?) {
        switch d.outcome {
        case .success:
            // Never called for a success (the success path writes a usage record), but keep the
            // switch exhaustive rather than trapping.
            return (.category("success"), "success", nil)
        case .httpError:
            guard let status = d.httpStatus else { return (.category("network"), "network", nil) }
            let reason: String
            switch status {
            case 401, 403:      reason = "auth"
            case 400...499:     reason = "clientProblem"     // 429 and every other 4xx
            case 500...599:     reason = "serverProblem"
            default:            reason = "clientProblem"      // unexpected but response-bearing → client bucket
            }
            return (.http(status), reason, nil)
        case .decodeFailure:
            return (.category("decode"), "decode", nil)
        case .transportError:
            // The diagnostic outcome does not carry the `URLError.Code`; `FailureReason` already refined
            // it (timeout / cannotResolveHost / network), so lean on that for the category.
            switch failure {
            // The transport message is a `URLError` description, not a stable category, so it stays
            // out of `detail`: whether it is `.public`-safe at journal scale is its own decision.
            case .timeout:           return (.category("timeout"), "timeout", nil)
            case .cannotResolveHost: return (.category("dns"), "dns", nil)
            default:                 return (.category("network"), "network", nil)
            }
        case .nonHTTPResponse:
            return (.category("nonHTTP"), "network", nil)
        case let .notSent(reason):
            return (.category("notSent"), "notSent", reason)
        }
    }
}
