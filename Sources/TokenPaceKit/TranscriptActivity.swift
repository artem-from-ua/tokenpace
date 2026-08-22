import Foundation

// MARK: - ActivityFileIndex

/// The filesystem seam behind ``TranscriptActivityProbe`` — "is anything under `root` newer than
/// `cutoff`?" — so the activity decision is unit-tested against a fixture table instead of the
/// maintainer's real `~/.claude` tree.
///
/// One method, and it answers a **question** rather than returning a listing: the probe never needs
/// to know *which* file moved or *how many* did, only whether at least one did. That lets the
/// production implementation stop walking at the first hit (`ADR-0117`), which is what keeps a
/// ~500-file tree affordable to check every three minutes.
public protocol ActivityFileIndex: Sendable {
    /// Whether **any** file at or below `root` has an mtime strictly after `cutoff`.
    ///
    /// Deliberately not filtered by extension. Claude Code writes far more than transcripts while it
    /// works — under `jobs/` the `.jsonl` files are a minority (measured: 249 of ~5,800, against
    /// 2,014 `.png` and 1,139 `.log`), and under `projects/` they are about a third. Any write is
    /// evidence of the same thing, and matching on a suffix would smuggle back an assumption about a
    /// private on-disk format.
    ///
    /// `root` may be a single file (`history.jsonl`), a flat directory of per-job files, or a
    /// recursive tree (`projects/`); implementations treat all three uniformly. A missing or
    /// unreadable `root` is **not** an error — it answers `false`, because "the directory is not
    /// there" and "nothing in it moved" lead to the same conclusion for the caller.
    func hasFileModified(after cutoff: Date, under root: URL) -> Bool
}

// MARK: - TranscriptActivityProbe

/// Production ``ClaudeActivityProbe`` (ADR-0117): reports a Claude Code session as active when any
/// of its **on-disk journals** was written to within ``activityWindow``.
///
/// ## Why not the process table
///
/// The previous probe matched a process whose `p_comm` was exactly `claude`. The native installer
/// lays the binary down as `~/.local/share/claude/versions/<semver>` with `~/.local/bin/claude` a
/// symlink to it, and the kernel records the **real file's** basename — so every Claude Code
/// process reports `p_comm` = `2.1.231`, and the match silently stopped firing. Measured on the
/// maintainer's Mac: 12 live Claude Code processes, 0 matches; the interval sat at the 15-minute
/// idle override while background agents were burning tokens.
///
/// Naming a process is a **private contract of the CLI**, and it broke twice over (first `p_comm`,
/// then the `daemon` / `bg-*` subcommand names). What the app actually needs to know is whether
/// *work is happening*, and Claude Code leaves a direct, documented trace of that: it appends to a
/// transcript on every turn.
///
/// ## What counts as activity
///
/// Any write, within the window, to one of three sources — a disjunction, checked cheapest-first:
///
/// 1. `history.jsonl` — the user just typed something. This is deliberately counted **before** any
///    token is spent: the probe answers "does the user need a fresh number *now*", and someone at
///    the keyboard is looking at the widget. Spend follows within seconds.
/// 2. `jobs/<id>/timeline.jsonl` — a background job is progressing, possibly with no interactive
///    session open at all.
/// 3. `projects/<slug>/**/*.jsonl` — the session transcripts themselves, covering interactive
///    sessions, agent-view sessions and subagents alike (subagents nest one level deeper, hence the
///    recursive walk).
///
/// **Only mtime is read; file contents never are.** A write means the balance may be moving even
/// when the user is doing nothing directly — a background job can burn tokens and only then record
/// that it is blocked. Parsing a `state` field to filter those out would re-introduce exactly the
/// dependency on a private naming contract that broke the old probe, and cost file reads besides.
/// The error costs are asymmetric and point the same way: guessing "active" wastes one request per
/// three minutes, guessing "idle" leaves a quarter hour of stale numbers on screen.
public struct TranscriptActivityProbe: ClaudeActivityProbe {
    /// How recently a journal must have been written for the session to count as active.
    ///
    /// 5 minutes. A transcript is appended on every turn (measured: this session's file trailed the
    /// live conversation by 8 seconds), so the window only has to outlast a long stretch of model
    /// thinking, and it goes quiet promptly once work stops. Shorter risks a false "idle" mid-turn;
    /// longer drags a tail of 3-minute polling past the end of the work.
    public static let activityWindow: TimeInterval = 5 * 60

    private let claudeHome: URL
    private let activityWindow: TimeInterval
    private let now: @Sendable () -> Date
    private let index: ActivityFileIndex

    /// - Parameters:
    ///   - claudeHome: the Claude Code home directory. Defaults to ``defaultClaudeHome``, which
    ///     honors `CLAUDE_CONFIG_DIR`; injectable so tests point at a fixture tree.
    ///   - activityWindow: how fresh a write must be to count. Defaults to ``activityWindow``.
    ///   - now: the clock seam, so tests drive the window without sleeping.
    ///   - index: the filesystem seam.
    public init(
        claudeHome: URL = TranscriptActivityProbe.defaultClaudeHome(),
        activityWindow: TimeInterval = TranscriptActivityProbe.activityWindow,
        now: @escaping @Sendable () -> Date = Date.init,
        index: ActivityFileIndex
    ) {
        self.claudeHome = claudeHome
        self.activityWindow = activityWindow
        self.now = now
        self.index = index
    }

    /// The Claude Code home directory: `CLAUDE_CONFIG_DIR` when set, else `~/.claude`.
    ///
    /// `CLAUDE_CONFIG_DIR` relocates the whole tree, so hard-coding `~/.claude` would make the probe
    /// blind for anyone who sets it — the same class of failure as hard-coding the binary's name.
    public static func defaultClaudeHome() -> URL {
        if let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    public func isClaudeRunning() -> Bool {
        let cutoff = now().addingTimeInterval(-activityWindow)
        // Cheapest first, and the walk stops at the first source that answers yes: one `stat` for
        // the history file, a flat scan of the job directory, and only then the recursive tree.
        return searchRoots.contains { index.hasFileModified(after: cutoff, under: $0) }
    }

    /// The three roots, ordered by cost so an active machine usually answers before the recursive
    /// walk is ever reached.
    private var searchRoots: [URL] {
        [
            claudeHome.appendingPathComponent("history.jsonl"),
            claudeHome.appendingPathComponent("jobs"),
            claudeHome.appendingPathComponent("projects"),
        ]
    }
}
