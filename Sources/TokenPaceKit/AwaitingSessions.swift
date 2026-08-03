import Foundation

// MARK: - AwaitingUrgency

/// How close an awaiting session is to being **deleted** by Claude Code's cleanup (#233, #234). Claude
/// Code prunes data older than `cleanupPeriodDays` (default 30) by mtime; we approximate a session's
/// age by its `updatedAt`, so `daysUntilDeletion = cleanupPeriodDays − ageDays`. The urgency is keyed on
/// how little time is **left**, not on how old the session is:
///
/// - ``red`` — under 7 days left (about to be pruned).
/// - ``orange`` — under 15 days left.
/// - ``neutral`` — more than 15 days left.
///
/// This drives the hand indicator's tint (the **soonest**-deletion session across all awaiting sessions
/// wins) and the per-project popover's three columns.
public enum AwaitingUrgency: Int, Sendable, Equatable, Comparable, CaseIterable {
    case neutral = 0
    case orange = 1
    case red = 2

    /// Bucket a session by how many days remain before Claude Code would delete it.
    public static func forDaysUntilDeletion(_ days: Double) -> AwaitingUrgency {
        if days < 7 { return .red }
        if days < 15 { return .orange }
        return .neutral
    }

    /// More time left is *less* urgent, so `neutral < orange < red` — `max` picks the soonest deletion.
    public static func < (lhs: AwaitingUrgency, rhs: AwaitingUrgency) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - AwaitingSession

/// One live Claude Code session awaiting user input, with the facts the UI needs beyond the bare count
/// (#233). Built by ``AwaitingInputScanner``.
public struct AwaitingSession: Sendable, Equatable {
    /// The session's project — the repo root (`originCwd` from the job state, falling back to the
    /// session `cwd`), so worktrees of one repo collapse into a single project.
    public let project: String
    /// Days until Claude Code's cleanup would delete this session: `cleanupPeriodDays − ageDays`,
    /// where age is `now − updatedAt`. Can go negative if already past the window (still counted —
    /// it's awaiting until it actually disappears).
    public let daysUntilDeletion: Double

    public init(project: String, daysUntilDeletion: Double) {
        self.project = project
        self.daysUntilDeletion = daysUntilDeletion
    }

    /// This session's urgency bucket.
    public var urgency: AwaitingUrgency { .forDaysUntilDeletion(daysUntilDeletion) }

    /// The project's display name — the last path component of ``project`` (e.g. `cc-timer`), or the
    /// whole string if it has no separators.
    public var projectName: String {
        let trimmed = project.hasSuffix("/") ? String(project.dropLast()) : project
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}

// MARK: - ProjectAwaitingStats

/// Per-project counts of awaiting sessions bucketed by urgency (#233) — one row in the click popover.
public struct ProjectAwaitingStats: Sendable, Equatable {
    public let projectName: String
    /// Sessions with under 7 days left before deletion (red).
    public let red: Int
    /// Sessions with under 15 days (but ≥ 7) left before deletion (orange).
    public let orange: Int
    /// Sessions with more than 15 days left (neutral / "recent").
    public let recent: Int

    public init(projectName: String, red: Int, orange: Int, recent: Int) {
        self.projectName = projectName
        self.red = red
        self.orange = orange
        self.recent = recent
    }

    public var total: Int { red + orange + recent }
}

// MARK: - AwaitingSessions

/// The aggregate result of a scan (#233): every awaiting session, plus the derived count, overall
/// urgency tint, and per-project breakdown the UI renders. A pure value — the shell builds it from
/// ``AwaitingInputScanner/scan(now:)`` and grafts it onto the layouts.
public struct AwaitingSessions: Sendable, Equatable {
    public let sessions: [AwaitingSession]

    public init(_ sessions: [AwaitingSession]) {
        self.sessions = sessions
    }

    /// No awaiting sessions — the UI hides the indicator entirely.
    public static let none = AwaitingSessions([])

    /// Number of awaiting sessions (the count; the indicator is hidden at 0).
    public var count: Int { sessions.count }

    /// The tint for the hand indicator: the **soonest**-to-be-deleted session wins (`max` urgency),
    /// so a single about-to-expire session turns the whole indicator red. ``AwaitingUrgency/neutral``
    /// when nothing is close (or there are no sessions).
    public var urgency: AwaitingUrgency {
        sessions.map(\.urgency).max() ?? .neutral
    }

    /// Per-project breakdown for the click popover, one ``ProjectAwaitingStats`` per project, sorted
    /// most-urgent-first (most red, then orange, then name) so the projects that need attention are on
    /// top.
    public var perProject: [ProjectAwaitingStats] {
        let grouped = Dictionary(grouping: sessions, by: \.projectName)
        return grouped.map { name, group in
            ProjectAwaitingStats(
                projectName: name,
                red: group.filter { $0.urgency == .red }.count,
                orange: group.filter { $0.urgency == .orange }.count,
                recent: group.filter { $0.urgency == .neutral }.count)
        }
        .sorted { a, b in
            if a.red != b.red { return a.red > b.red }
            if a.orange != b.orange { return a.orange > b.orange }
            return a.projectName < b.projectName
        }
    }
}
