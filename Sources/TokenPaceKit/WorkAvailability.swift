import Foundation

// MARK: - WorkAvailability

/// Whether Claude Code can do work **right now**, from a decoded ``UsageSnapshot`` (#160). This is the
/// pure signal behind the "Back to work!" notification: the shell watches it poll-to-poll and fires
/// when it crosses `false → true` (see `AppDelegate.apply`).
///
/// "Blocked" means every path to doing work is spent; "workable" means at least one is open. The
/// decision reuses the existing credits predicates rather than reinventing an exhaustion check:
/// - ``CreditsPacing/anyBaseLimitExhausted(in:)`` — is any **base** limit (5h / 7d / per-model /
///   `weekly_scoped`) at 100%?
/// - ``CreditsPacing/isSpending(_:baseLimitExhausted:)`` — are money-credits **actively covering**
///   work (enabled, not yet capped) while a base limit is exhausted?
public enum WorkAvailability {

    /// `true` when work is possible: no base limit is exhausted, **or** a base limit is exhausted but
    /// money-credits are actively covering it.
    ///
    /// Exact rule:
    /// ```
    /// canWork = !anyBaseLimitExhausted(snapshot)
    ///           || (spend != nil && isSpending(spend, baseLimitExhausted: true))
    /// ```
    ///
    /// Edge cases (all fall out of the reused predicates — no special-casing here):
    /// - **`spend == nil`** (a pre-credits payload) with a base limit exhausted → `false`: no credits
    ///   data means no money coverage, so exhausted = blocked.
    /// - **`sessionIdle == true`**: the idle 5h window carries `utilization: 0` (see
    ///   ``UsageSnapshot/sessionIdle``), so ``CreditsPacing/anyBaseLimitExhausted(in:)`` does not count
    ///   it — an idle 5h window is treated as *not* exhausted ("ready to start"), which is correct.
    /// - **`spend_limit_reached == true`** (credits capped; the server flips `enabled` to false) with a
    ///   base limit exhausted → `false`: credits are no longer covering anything. A later credits reset
    ///   (`spend_limit_reached` back to false, `enabled` true) is then a genuine `false → true` edge —
    ///   exactly the "extra usage reset" unblock the feature must catch.
    public static func canWork(_ snapshot: UsageSnapshot) -> Bool {
        guard CreditsPacing.anyBaseLimitExhausted(in: snapshot) else { return true }
        // A base limit is exhausted — the only way work is still possible is active credit coverage.
        guard let spend = snapshot.spend else { return false }
        return CreditsPacing.isSpending(spend, baseLimitExhausted: true)
    }
}
