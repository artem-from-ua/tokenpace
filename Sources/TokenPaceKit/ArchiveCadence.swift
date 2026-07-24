import Foundation

// MARK: - ArchiveCadence

/// When the session-log archive sync is due — a pure decision seam, no clock, no I/O (#110),
/// modeled on ``UpdateCheckCadence``.
///
/// The archiver runs at most once per fixed 24 h window. Like the update check, it does **not** ride
/// the usage poll interval: the source (`~/.claude/…`) changes slowly, and Claude Code only prunes on
/// its own launch, so a once-a-day mirror is more than enough to outrun the 30-day cleanup. Syncing
/// on every usage heartbeat would only churn the disk for no benefit.
///
/// The shell asks ``isDue(lastSync:now:)`` on each usage heartbeat (`AppDelegate.pollArchiveIfDue`)
/// and mirrors only when it returns `true`, then advances `lastArchiveSync` on a **successful** run —
/// a failed sync (e.g. destination unwritable) stays due so the next heartbeat retries, matching the
/// spirit of ``StatusCadence`` rather than ``UpdateCheckCadence`` (there is no third party to be
/// polite to here — the work is local).
public enum ArchiveCadence {
    /// The minimum gap between archive syncs: 24 hours. The source rotates on a 30-day horizon, so a
    /// daily mirror preserves everything with a wide safety margin.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// Whether an archive sync is due at `now`, given when the last **successful** sync ran. A `nil`
    /// last-sync (fresh enable / first run after this feature shipped) is always due. The boundary
    /// counts as due (`>=`), consistent with ``UpdateCheckCadence/isDue(lastCheck:now:)``.
    ///
    /// - Parameters:
    ///   - lastSync: Instant of the last successful sync, or `nil` if none yet.
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    public static func isDue(lastSync: Date?, now: Date) -> Bool {
        guard let lastSync else { return true }
        return now.timeIntervalSince(lastSync) >= interval
    }
}
