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
    /// The session's title — the same string Claude Code's agentic view lists it under (`refactor
    /// popup layout`), or `nil` when the session was never named (#438).
    ///
    /// `nil` is the *normalized* absence, not merely a missing field: Claude Code writes a
    /// **placeholder** rather than omitting the key, so an unnamed session carries its own `jobId`
    /// (the sessionId's first 8 chars) as its `name`. ``AwaitingInputScanner/normalizedName(_:jobId:sessionId:)``
    /// collapses every such shape to `nil` at the scanner boundary, so the UI only ever has to ask
    /// "is this nil". The placeholder must not reach the screen: it reads as a copyable identifier
    /// while `--resume` rejects it (it takes a full UUID or a session title, not the 8-char prefix).
    public let name: String?

    public init(project: String, daysUntilDeletion: Double, name: String? = nil) {
        self.project = project
        self.daysUntilDeletion = daysUntilDeletion
        self.name = name
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

/// One project's awaiting sessions (#233, #438) — a heading row in the ⌥ breakdown plus the session
/// rows beneath it.
///
/// The bucket counts are **derived** from ``sessions`` rather than stored alongside it: they used to
/// be the whole payload, back when the row rendered them as `1✋ 2✋` chips and no session was named.
/// Now that every session gets its own row and its own hand, a stored count could disagree with the
/// array it summarizes — so there is nothing to keep in sync.
public struct ProjectAwaitingStats: Sendable, Equatable {
    public let projectName: String
    /// This project's awaiting sessions, **freshest first** (see ``AwaitingSessions/perProject``).
    public let sessions: [AwaitingSession]

    public init(projectName: String, sessions: [AwaitingSession]) {
        self.projectName = projectName
        self.sessions = sessions
    }

    /// Sessions with under 7 days left before deletion (red).
    public var red: Int { sessions.count { $0.urgency == .red } }
    /// Sessions with under 15 days (but ≥ 7) left before deletion (orange).
    public var orange: Int { sessions.count { $0.urgency == .orange } }
    /// Sessions with more than 15 days left (neutral / "recent").
    public var recent: Int { sessions.count { $0.urgency == .neutral } }

    public var total: Int { sessions.count }
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

    /// Per-project breakdown for the ⌥ popup: one ``ProjectAwaitingStats`` per project, **sorted by
    /// name**, each carrying its sessions **freshest first**.
    ///
    /// Projects sort alphabetically rather than most-urgent-first (#438). The urgency ordering made
    /// sense while the project row itself carried the coloured chips; now that row is a bare heading
    /// and every hand hangs off a session line, so ranking headings by a quantity they no longer
    /// display would order the list by something the eye cannot check.
    ///
    /// Sessions sort by ``AwaitingSession/daysUntilDeletion`` **descending**, which is exactly
    /// "most recently updated first": the scanner derives that number as `cleanupDays − ageDays` from
    /// `updatedAt`, and `cleanupDays` is one value for the whole scan — so more days left means a
    /// fresher session, with no second timestamp to carry.
    ///
    /// The tie-break is load-bearing, not cosmetic. `ageDays` is clamped at `max(0, …)`, so every
    /// session touched within the last moment collapses onto the *same* `daysUntilDeletion`; without
    /// a total order the row order would follow `contentsOfDirectory`, and ``AwaitingSessions`` is
    /// `Equatable` — the watcher would read each reshuffle as a change and re-render on every scan.
    public var perProject: [ProjectAwaitingStats] {
        Dictionary(grouping: sessions, by: \.projectName)
            .map { name, group in
                ProjectAwaitingStats(projectName: name, sessions: group.sorted(by: Self.freshestFirst))
            }
            .sorted { $0.projectName < $1.projectName }
    }

    /// Freshest first, with a total order: more days left wins, then name, then project — so equal
    /// timestamps still land in one stable sequence rather than in directory order.
    private static func freshestFirst(_ a: AwaitingSession, _ b: AwaitingSession) -> Bool {
        if a.daysUntilDeletion != b.daysUntilDeletion { return a.daysUntilDeletion > b.daysUntilDeletion }
        if a.name != b.name { return (a.name ?? "") < (b.name ?? "") }
        return a.project < b.project
    }
}
