import Foundation

// MARK: - Domain → JournalRecord factories

extension JournalRecord {

    /// The `FarBehindInterval` multiplier the journal always paces at — the shipped **medium** width,
    /// so the recorded ``PacingBucket`` is independent of the user's blue-zone setting (see
    /// ``PacingBucket``). Kept in sync with ``PacingBucket`` by intent, not by reference (that type
    /// hard-codes the same value for its own reason — the constant is private there).
    private static let journalBehindMultiplier = 2

    /// Build a `usage` record from a successful poll's snapshot plus the poll instant and latency.
    ///
    /// All the derived states are computed here (in the pure Kit) so the shell stays a thin
    /// serialiser: window pacing via ``PacingModel``/``PacingBucket``, credits via ``CreditsPacing``,
    /// blocked/credits flags, `hasBrokenActiveReset`, and the blocking-reset choice.
    public static func usage(from snapshot: UsageSnapshot, now: Date, durationMs: Int? = nil) -> JournalRecord {
        let credits = CreditsFlags(
            active: snapshot.spend.map(CreditsPacing.isActive) ?? false,
            showIcon: snapshot.spend.map {
                CreditsPacing.shouldShowIcon($0, baseLimitExhausted: CreditsPacing.anyBaseLimitExhausted(in: snapshot))
            } ?? false,
            onCredits: ExtraUsageOnset.isOnCredits(snapshot))

        let sample = UsageSample(
            t: ResetClock.isoString(from: now),
            ms: durationMs,
            h5: window(snapshot.fiveHour, window: .fiveHour, now: now),
            d7: window(snapshot.sevenDay, window: .sevenDay, now: now),
            opus: snapshot.sevenDayOpus.map { window($0, window: .sevenDay, now: now) },
            sonnet: snapshot.sevenDaySonnet.map { window($0, window: .sevenDay, now: now) },
            scoped: snapshot.scopedModelWindows.map { scoped($0, now: now) },
            sessionIdle: snapshot.sessionIdle,
            spend: snapshot.spend.map { SpendSample($0, now: now) },
            blocked: CreditsPacing.isBlocked(in: snapshot),
            credits: credits,
            brokenReset: snapshot.hasBrokenActiveReset,
            blockingReset: BlockingReset.forBlocked(snapshot: snapshot, now: now).map(BlockingResetSample.init))
        return .usage(sample)
    }

    /// Build a `status` record from a successful status poll — the raw components plus the derived
    /// worst-of that drives the menu-bar dot.
    public static func status(from summary: StatusSummary, health: StatusHealth, now: Date) -> JournalRecord {
        let svc = summary.components.map { StatusSample.ServiceEntry(n: $0.name, s: $0.status) }
        let worst = health.worstProblem ?? .operational
        return .status(StatusSample(t: ResetClock.isoString(from: now), svc: svc, worst: journalString(worst)))
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
        let (code, reason) = errorCodeAndReason(d, failure: failure)
        return .error(ErrorSample(
            t: ResetClock.isoString(from: now),
            code: code,
            reason: reason,
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
    private static func window(_ w: UsageWindow, window kind: LimitWindow, now: Date) -> WindowSample {
        guard let resetsAt = ResetClock.parse(w.resetsAt) else {
            // No parseable reset → no pacing gap to colour; `timePct` 0, `gap` from time(0)−util.
            return WindowSample(util: w.utilization, reset: w.resetsAt, timePct: 0,
                                gap: -w.utilization, sev: w.utilization >= 100 ? .red : .green)
        }
        let layout = PacingModel.barLayout(
            utilization: w.utilization, resetsAt: resetsAt, now: now,
            window: kind, behindMultiplier: journalBehindMultiplier)
        return WindowSample(
            util: w.utilization, reset: w.resetsAt,
            timePct: layout.timeFraction, gap: layout.timeFraction * 100 - w.utilization,
            sev: PacingBucket.of(layout))
    }

    /// Journal a scoped per-model window — all 7-day-paced, so it borrows the 7-day pacing math.
    private static func scoped(_ s: ScopedModelWindow, now: Date) -> ScopedSample {
        let w = window(s.window, window: .sevenDay, now: now)
        return ScopedSample(name: s.name, pct: s.window.utilization, reset: s.window.resetsAt,
                            timePct: w.timePct, gap: w.gap, sev: w.sev)
    }

    /// Derive the journal `code` and `reason` from a fetch diagnostic (and, for transport failures, the
    /// refined ``FailureReason``). Exhaustive over ``FetchDiagnostics/Outcome``.
    private static func errorCodeAndReason(_ d: FetchDiagnostics, failure: FailureReason?) -> (ErrorCode, String) {
        switch d.outcome {
        case .success:
            // Never called for a success (the success path writes a usage record), but keep the
            // switch exhaustive rather than trapping.
            return (.category("success"), "success")
        case .httpError:
            guard let status = d.httpStatus else { return (.category("network"), "network") }
            let reason: String
            switch status {
            case 401, 403:      reason = "auth"
            case 400...499:     reason = "clientProblem"     // 429 and every other 4xx
            case 500...599:     reason = "serverProblem"
            default:            reason = "clientProblem"      // unexpected but response-bearing → client bucket
            }
            return (.http(status), reason)
        case .decodeFailure:
            return (.category("decode"), "decode")
        case .transportError:
            // The diagnostic outcome does not carry the `URLError.Code`; `FailureReason` already refined
            // it (timeout / cannotResolveHost / network), so lean on that for the category.
            switch failure {
            case .timeout:           return (.category("timeout"), "timeout")
            case .cannotResolveHost: return (.category("dns"), "dns")
            default:                 return (.category("network"), "network")
            }
        case .nonHTTPResponse:
            return (.category("nonHTTP"), "network")
        case .notSent:
            return (.category("notSent"), "notSent")
        }
    }
}
