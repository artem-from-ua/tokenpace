import Foundation

// MARK: - WorkAvailability

/// Two pure availability signals read off a decoded ``UsageSnapshot`` — both built on
/// ``CreditsPacing/mainWindowExhausted(in:)`` so they cannot drift apart on what "exhausted" means,
/// but answering different questions:
///
/// - ``canWork(_:)`` (#160) — *can work happen right now?* Counts active Extra Usage Credit as a way
///   through, so it is the exact inverse of ``CreditsPacing/isBlocked(in:)`` and stays in lock-step
///   with the popup's red blocking-reset badge.
/// - ``subscriptionAvailable(_:)`` (#161) — *is the subscription quota available again?* Credits are
///   outside the question. This is the signal behind the "Back to work!" notification: the shell
///   watches it poll-to-poll and fires when it crosses `false → true` (see `AppDelegate.apply`).
///
/// Both reuse the existing predicates rather than reinventing an exhaustion check:
/// - ``CreditsPacing/mainWindowExhausted(in:)`` — is a **main** window (5h **or** 7d) at 100%? Only
///   these two gate work; per-model sub-windows do not (#177).
/// - ``CreditsPacing/isSpending(_:baseLimitExhausted:)`` — are money-credits **actively covering**
///   work (enabled, not yet capped) while a main window is exhausted?
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
    ///   state (#177).
    /// - **`spend == nil`** (a pre-credits payload) with a main window exhausted → `false`: no credits
    ///   data means no money coverage, so exhausted = blocked.
    /// - **`sessionIdle == true`**: the idle 5h window carries `utilization: 0` (see
    ///   ``UsageSnapshot/sessionIdle``), so ``CreditsPacing/mainWindowExhausted(in:)`` does not count
    ///   it — an idle 5h window is treated as *not* exhausted ("ready to start"), which is correct.
    /// - **`spend_limit_reached == true`** (credits capped; the server flips `enabled` to false) with a
    ///   main window exhausted → `false`: credits are no longer covering anything. A later credits reset
    ///   (`spend_limit_reached` back to false, `enabled` true) is then a genuine `false → true` edge for
    ///   *this* predicate — work becomes possible again. Note that the "Back to work!" notification no
    ///   longer rides on it (#161): it tracks ``subscriptionAvailable(_:)``, which a credits reset does
    ///   not move.
    public static func canWork(_ snapshot: UsageSnapshot) -> Bool {
        guard CreditsPacing.mainWindowExhausted(in: snapshot) else { return true }
        // A main window is exhausted — the only way work is still possible is active credit coverage.
        guard let spend = snapshot.spend else { return false }
        return CreditsPacing.isSpending(spend, baseLimitExhausted: true)
    }

    /// `true` when **no main subscription window** (5h / 7d) is exhausted — the signal behind the
    /// "Back to work!" notification since #161.
    ///
    /// This deliberately differs from ``canWork(_:)``: it answers *"is my subscription quota available
    /// again?"*, not *"can I do work right now?"*. Extra Usage Credit is outside the question entirely
    /// and never moves this value in either direction:
    ///
    /// - A main window at 100 % reads as **unavailable even while credits actively cover the work**, so
    ///   the later subscription reset is a genuine `false → true` edge. Under ``canWork(_:)`` that state
    ///   is already "workable", the blocked state is never entered, and the reset passes unannounced.
    /// - A credits cap (`spend_limit_reached`) and its later reset move nothing here, so a credits reset
    ///   alone never announces "Back to work" while the subscription is still spent. Switching onto paid
    ///   credit has its own notification (``ExtraUsageOnset``, ADR-0050).
    ///
    /// Built on ``CreditsPacing/mainWindowExhausted(in:)`` — the same exhaustion notion behind
    /// ``CreditsPacing/isBlocked(in:)`` and ``canWork(_:)`` — rather than a fresh check, so the popup's
    /// blocking badge and this notification cannot drift apart on what "exhausted" means. The edge cases
    /// fall out of that predicate with no special-casing here: a per-model sub-window at 100 % does not
    /// count (#177), an idle 5h window carries `utilization: 0` and reads as "ready to start", and
    /// ``UsageSnapshot/spend`` is not consulted at all.
    public static func subscriptionAvailable(_ snapshot: UsageSnapshot) -> Bool {
        !CreditsPacing.mainWindowExhausted(in: snapshot)
    }
}
