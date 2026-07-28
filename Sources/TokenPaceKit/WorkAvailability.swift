import Foundation

// MARK: - WorkAvailability

/// Whether Claude Code can do work **right now**, from a decoded ``UsageSnapshot`` (#160). This is the
/// pure signal behind the "Back to work!" notification: the shell watches it poll-to-poll and fires
/// when it crosses `false → true` (see `AppDelegate.apply`).
///
/// "Blocked" means every path to doing work is spent; "workable" means at least one is open. The
/// decision reuses the existing predicates rather than reinventing an exhaustion check:
/// - ``CreditsPacing/mainWindowExhausted(in:)`` — is a **main** window (5h **or** 7d) at 100%? Only
///   these two gate work; per-model sub-windows do not (#177).
/// - ``CreditsPacing/isSpending(_:baseLimitExhausted:)`` — are money-credits **actively covering**
///   work (enabled, not yet capped) while a main window is exhausted?
///
/// This is the exact inverse of ``CreditsPacing/isBlocked(in:)`` (both built on
/// ``CreditsPacing/mainWindowExhausted(in:)``), so the "Back to work!" notification and the popup's
/// red blocking-reset badge stay in lock-step.
public enum WorkAvailability {

    /// `true` when work is possible: no **main** window (5h / 7d) is exhausted, **or** one is exhausted
    /// but money-credits are actively covering it.
    ///
    /// Exact rule:
    /// ```
    /// canWork = !mainWindowExhausted(snapshot)
    ///           || (spend != nil && isSpending(spend, baseLimitExhausted: true))
    /// ```
    ///
    /// Edge cases (all fall out of the reused predicates — no special-casing here):
    /// - **Per-model sub-window at 100%** (`sevenDayOpus` / `sevenDaySonnet` / `weekly_scoped`) with the
    ///   main windows below 100 % → `true` (workable): sub-windows do not gate work, so no "blocked"
    ///   state and no spurious "Back to work!" edge (#177).
    /// - **`spend == nil`** (a pre-credits payload) with a main window exhausted → `false`: no credits
    ///   data means no money coverage, so exhausted = blocked.
    /// - **`sessionIdle == true`**: the idle 5h window carries `utilization: 0` (see
    ///   ``UsageSnapshot/sessionIdle``), so ``CreditsPacing/mainWindowExhausted(in:)`` does not count
    ///   it — an idle 5h window is treated as *not* exhausted ("ready to start"), which is correct.
    /// - **`spend_limit_reached == true`** (credits capped; the server flips `enabled` to false) with a
    ///   main window exhausted → `false`: credits are no longer covering anything. A later credits reset
    ///   (`spend_limit_reached` back to false, `enabled` true) is then a genuine `false → true` edge —
    ///   exactly the "extra usage reset" unblock the feature must catch.
    public static func canWork(_ snapshot: UsageSnapshot) -> Bool {
        guard CreditsPacing.mainWindowExhausted(in: snapshot) else { return true }
        // A main window is exhausted — the only way work is still possible is active credit coverage.
        guard let spend = snapshot.spend else { return false }
        return CreditsPacing.isSpending(spend, baseLimitExhausted: true)
    }
}
