import Foundation

// MARK: - UpdateCheckCadence

/// When the daily update check is due — a pure decision seam, no clock, no I/O (#37), modeled on
/// ``StatusCadence``.
///
/// Unlike the status poll, the update check does **not** ride the usage interval: it runs at most
/// once per fixed 24 h window regardless of how fast usage is polled. The check is a courtesy to a
/// third party (GitHub) about a value that changes at most once per release, so coupling it to the
/// usage cadence would only add needless requests.
///
/// The shell also checks **once on launch** unconditionally (a freshly relaunched build should
/// surface a pending update right away, not up to a day later); this cadence governs the *re-checks*
/// during a long-running session. The shell asks ``isDue(lastCheck:now:)`` on each usage heartbeat
/// and fetches only when it returns `true`, then advances `lastUpdateCheck` on **every** attempt —
/// success or graceful failure — so a private-repo 404 does not retry every tick. (This differs from
/// ``StatusCadence``, whose marker advances only on success, because the status page is meant to
/// retry quickly. See ADR-0025.)
public enum UpdateCheckCadence {
    /// The minimum gap between update checks: 24 hours. Polite to GitHub's anonymous rate limit
    /// (~60 req/h/IP — a once-a-day check is far within it) and matches the ticket's "≤ once per day".
    public static let interval: TimeInterval = 24 * 60 * 60

    /// Whether an update check is due at `now`, given when the last attempt ran. A `nil` last-check
    /// (fresh install / first run after this feature shipped) is always due. The boundary counts as
    /// due (`>=`), consistent with ``StatusCadence/isDue(lastSuccess:usageInterval:hasProblem:now:)``.
    ///
    /// - Parameters:
    ///   - lastCheck: Instant of the last check **attempt** (not just success), or `nil` if none yet.
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}
