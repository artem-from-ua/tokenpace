import Foundation

// MARK: - AwaitingInputScanner

/// Counts local Claude Code sessions that are **awaiting user input** — the state the native
/// FleetView agent list labels "Needs input" (a permission prompt, an approve-plan gate, a
/// question at the end of a turn, or `login required`). See ADR-0066 for the source-of-truth
/// investigation behind this.
///
/// **Data source (ADR-0066).** Claude Code's own daemon writes the aggregated state; we never
/// parse the multi-megabyte `.jsonl` transcripts (empirically they cannot tell a working session
/// from one awaiting approve-plan — both end on a `user`/`tool_result` record). Instead we read two
/// tiny state files and OR their signals:
///
/// ```
/// awaiting = sessions/<pid>.json  .status == "waiting"
///         OR (jobs/<jobId>/state.json is fresh AND .needs != null)
///         OR (jobs/<jobId>/state.json is fresh AND .tempo == "blocked")
/// ```
///
/// The **fresh** qualifier guards against a Claude Code worktree bug where the daemon's own
/// transcript scanner stalls and freezes `needs`/`tempo` on a past phase; see ``isAwaiting`` and
/// ``jobStateIsFresh``. Without it a worktree session that finished its approve-plan gate hours ago
/// would keep advertising a phantom "awaiting input".
///
/// The session list comes from **live** `sessions/*.json` (a handful of ~400-byte files); for each
/// we take its `jobId` and read **only** `jobs/<jobId>/state.json`, never scanning the whole
/// `jobs/` tree (it holds dozens of *dead* completed-session dirs that would inflate the count).
///
/// **No `JSONDecoder`.** These files are read as raw strings and matched with a few small regexes
/// on the 3–4 fields we need. `sessions/*.json` is written compact (`"status":"waiting"`);
/// `jobs/*/state.json` is pretty-printed with spaces (`"needs": "approve plan"`), so the patterns
/// tolerate optional whitespace.
///
/// **Stateless — no cache.** ``scan()`` reads and counts every time; a full scan measured ~0.18 ms
/// (a handful of sub-KB files). The shell drives it from FSEvents (see
/// `docs/design/awaiting-input-refresh.md`), so scans already happen only when the watched trees
/// change — there is essentially nothing to cache away. An mtime cache would only pay off in a
/// **poll-without-FSEvents** design (re-scanning on a fixed timer while nothing changed); if we ever
/// revert to that, reintroduce a per-session `path → (mtime, awaiting)` cache here. As is, keeping
/// the type a pure value keeps it trivially testable and free of atomic-write / coarse-mtime edge
/// cases.
///
/// **Private, undocumented format.** The file layout and the `status`/`state`/`tempo`/`needs`
/// values are Claude Code internals (observed on v2.1.212) and may change without notice. Every
/// lookup degrades gracefully: a missing field / dir / new value is treated as "not awaiting", so
/// the count never crashes and the feature quietly reads zero rather than misbehaving.
///
/// `claudeHome` and `fileManager` are injectable so a test can point at a fixture tree, mirroring
/// ``LogArchiver``. A pure value type; `scan()` is side-effect-free and safe to call off the main
/// thread. (`fileManager` is not `Sendable`, so the struct isn't marked `Sendable` — the shell owns
/// one instance and calls it from its single refresh path.)
public struct AwaitingInputScanner {
    /// The `~/.claude` directory. Injectable so a test can point at a fixture tree.
    private let claudeHome: URL
    private let fileManager: FileManager

    public init(
        claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"),
        fileManager: FileManager = .default
    ) {
        self.claudeHome = claudeHome
        self.fileManager = fileManager
    }

    // MARK: Public API

    /// Every live session currently awaiting user input, with its project and days-until-deletion —
    /// ``AwaitingSessions/none`` when nothing is waiting (the UI then hides the indicator).
    ///
    /// `now` is injected so age math is deterministic in tests. Pure and side-effect-free; any I/O
    /// error (unreadable dir, torn file mid-write) is swallowed and simply contributes nothing.
    public func scan(now: Date) -> AwaitingSessions {
        let sessionsDir = claudeHome.appendingPathComponent("sessions")
        guard let entries = try? fileManager.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil
        ) else {
            return .none
        }
        let cleanupDays = cleanupPeriodDays()
        var found: [AwaitingSession] = []
        for url in entries where url.pathExtension == "json" {
            guard let raw = try? String(contentsOf: url, encoding: .utf8),
                  isAwaiting(sessionJSON: raw) else { continue }
            found.append(session(from: raw, now: now, cleanupDays: cleanupDays))
        }
        return AwaitingSessions(found)
    }

    /// Convenience: just the count (the menu-bar hand when per-session detail isn't needed).
    public func count(now: Date) -> Int { scan(now: now).count }

    // MARK: Building a session

    /// Build an ``AwaitingSession`` from a session-file body: project = repo root (job `originCwd`,
    /// then session `cwd`), age from `updatedAt` (→ days until the `cleanupDays` cleanup deletes it).
    private func session(from sessionJSON: String, now: Date, cleanupDays: Double) -> AwaitingSession {
        // Age from updatedAt/statusUpdatedAt (ms epoch); missing → treat as brand-new (age 0).
        let updatedMs = firstMatch(Self.reUpdatedAt, in: sessionJSON).flatMap(Double.init)
        let ageDays: Double = updatedMs.map { max(0, (now.timeIntervalSince1970 * 1000 - $0) / 86_400_000) } ?? 0
        let daysLeft = cleanupDays - ageDays

        // Project: the job's originCwd (repo root, worktrees collapse) if resolvable, else session cwd.
        let cwd = firstMatch(Self.reCwd, in: sessionJSON) ?? ""
        var project = cwd
        if let jobId = firstMatch(Self.reJobID, in: sessionJSON),
           let state = try? String(contentsOf: jobStateURL(jobId), encoding: .utf8),
           let origin = firstMatch(Self.reOriginCwd, in: state), !origin.isEmpty {
            project = origin
        }
        return AwaitingSession(project: project, daysUntilDeletion: daysLeft)
    }

    /// Claude Code's cleanup horizon in days: `cleanupPeriodDays` from `~/.claude/settings.json`, or
    /// **30** (the documented default) when the key/file is absent or unparseable (ADR-0031).
    private func cleanupPeriodDays() -> Double {
        let settingsURL = claudeHome.appendingPathComponent("settings.json")
        guard let raw = try? String(contentsOf: settingsURL, encoding: .utf8),
              let value = firstMatch(Self.reCleanupDays, in: raw).flatMap(Double.init),
              value > 0 else { return 30 }
        return value
    }

    private func jobStateURL(_ jobId: String) -> URL {
        claudeHome.appendingPathComponent("jobs").appendingPathComponent(jobId)
            .appendingPathComponent("state.json")
    }

    // MARK: Per-session decision

    /// Decides whether a single session (its `sessions/<pid>.json` text) is awaiting input, reading
    /// its matching `jobs/<jobId>/state.json` when the session status alone is inconclusive.
    ///
    /// **Stale-state guard (worktree bug).** The `needs`/`tempo` fields in `jobs/*/state.json` are
    /// maintained by Claude Code's own scanner, which tails the session transcript via a stored
    /// `linkScanPath`. For **worktree** sessions that path is derived from the non-worktree project
    /// dir and points at a journal that does not exist there, so the scanner never advances and the
    /// job state **freezes** on whatever phase it last recorded — typically `needs:"approve plan"` +
    /// `tempo:"blocked"`. The session then keeps working (or goes idle) while `state.json` still
    /// advertises "awaiting", producing a phantom hand that never clears. We therefore trust the
    /// job-state signals **only while `state.json` is not meaningfully older than the session file**
    /// (which the live daemon rewrites on every status flip). A frozen `state.json` is ignored and
    /// the fresh session `status` wins. See ADR-0066 for the original source-of-truth choice.
    ///
    /// Internal (not private) so unit tests can exercise the join logic directly on fixture strings.
    func isAwaiting(sessionJSON: String) -> Bool {
        // 1. Direct real-time signal from the session file. Covers an active permission / plan prompt.
        if firstMatch(Self.reStatus, in: sessionJSON) == "waiting" { return true }

        // 2. Semantic "blocked, waiting for your decision" — the session file may still say "idle"
        //    here, so consult the daemon-computed job state (the FleetView source).
        guard let jobId = firstMatch(Self.reJobID, in: sessionJSON) else { return false }
        guard let state = try? String(contentsOf: jobStateURL(jobId), encoding: .utf8) else { return false }

        // Freshness guard: if the job state is stale relative to the live session file, its
        // needs/tempo are frozen (worktree bug above) and must not be trusted.
        guard jobStateIsFresh(sessionJSON: sessionJSON, stateJSON: state) else { return false }

        // `needs` present (a non-empty string) is the most precise "awaiting" marker; `tempo` ==
        // "blocked" is the same signal expressed as the coarse state. Either one counts.
        if let needs = firstMatch(Self.reNeeds, in: state), !needs.isEmpty { return true }
        if firstMatch(Self.reTempo, in: state) == "blocked" { return true }
        return false
    }

    /// Whether a job's `state.json` is recent enough that its `needs`/`tempo` reflect the *current*
    /// phase, rather than a frozen snapshot from a stalled worktree scanner (see ``isAwaiting``).
    ///
    /// True unless the job state is clearly older than the session: we compare the session's
    /// `statusUpdatedAt`/`updatedAt` (ms epoch) against the job state's ISO `updatedAt`, and treat
    /// the state as stale only when it lags by more than ``Self.staleToleranceMs``. When either
    /// timestamp is unreadable we **fail open** (return true) — the guard only ever *suppresses* a
    /// signal we can positively prove is frozen, so a parse gap degrades to the pre-guard behavior
    /// rather than silently dropping a real awaiting session.
    func jobStateIsFresh(sessionJSON: String, stateJSON: String) -> Bool {
        guard let sessionMs = sessionTimestampMs(sessionJSON),
              let stateMs = firstMatch(Self.reStateUpdatedAtISO, in: stateJSON)
                  .flatMap(Self.parseISOms) else { return true }
        return stateMs >= sessionMs - Self.staleToleranceMs
    }

    /// The session's last-activity epoch (ms), preferring `statusUpdatedAt` (bumped on every status
    /// change) and falling back to `updatedAt`. `nil` if neither is present/parseable.
    private func sessionTimestampMs(_ sessionJSON: String) -> Double? {
        firstMatch(Self.reStatusUpdatedAt, in: sessionJSON).flatMap(Double.init)
            ?? firstMatch(Self.reUpdatedAt, in: sessionJSON).flatMap(Double.init)
    }

    /// Slack allowed before a job state counts as stale: the daemon and the session file are written
    /// by different processes with slightly different cadences, so a small lag is normal and must not
    /// flip a genuinely-awaiting session to "not awaiting". A frozen worktree state lags by *minutes
    /// to hours*, far beyond this, so the guard stays decisive. 60 s.
    private static let staleToleranceMs: Double = 60_000

    /// Parse Claude Code's job-state `updatedAt` (`2026-08-04T01:27:32.234Z`) to epoch milliseconds,
    /// or `nil`. Uses a fixed-format `DateComponents` parse rather than `ISO8601DateFormatter` — the
    /// formatter is not `Sendable` (so it can't be a shared `static` under Swift 6 strict
    /// concurrency), and the format here is a single known shape emitted by the daemon, not arbitrary
    /// ISO-8601. Fractional seconds are optional; anything that doesn't match returns `nil`.
    static func parseISOms(_ iso: String) -> Double? {
        let range = NSRange(iso.startIndex..<iso.endIndex, in: iso)
        guard let m = reISOParts.firstMatch(in: iso, range: range) else { return nil }
        func part(_ i: Int) -> Int? {
            guard let r = Range(m.range(at: i), in: iso) else { return nil }
            return Int(iso[r])
        }
        // Groups: 1=Y 2=M 3=D 4=h 5=m 6=s 7=frac(optional). All the fixed ones are required.
        guard let y = part(1), let mo = part(2), let d = part(3),
              let h = part(4), let mi = part(5), let s = part(6) else { return nil }
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        c.timeZone = TimeZone(identifier: "UTC")
        guard let date = utcCalendar.date(from: c) else { return nil }
        // Fractional part like ".234" → 234 ms; absent → 0.
        let frac: Double
        if let r = Range(m.range(at: 7), in: iso), !iso[r].isEmpty {
            let digits = iso[r].dropFirst()  // drop the leading "."
            frac = (Double("0.\(digits)") ?? 0) * 1000
        } else {
            frac = 0
        }
        return date.timeIntervalSince1970 * 1000 + frac
    }

    /// `YYYY-MM-DDTHH:MM:SS` with an optional `.fff` fractional part and trailing `Z`.
    private static let reISOParts =
        regex(#"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?Z"#)

    /// A UTC `Calendar` for turning the parsed components into a `Date` (Gregorian, no locale drift).
    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    // MARK: Field extraction (no JSONDecoder — see type doc)

    /// `"status":"idle"` (compact, from `sessions/*.json`).
    private static let reStatus = regex(#""status"\s*:\s*"([a-z]+)""#)
    /// `"jobId":"04c0e8f2"` (compact, from `sessions/*.json`).
    private static let reJobID = regex(#""jobId"\s*:\s*"([^"]+)""#)
    /// `"needs": "approve plan"` (spaced, from `jobs/*/state.json`). Absent or `null` → no match.
    private static let reNeeds = regex(#""needs"\s*:\s*"([^"]*)""#)
    /// `"tempo": "blocked"` (spaced, from `jobs/*/state.json`).
    private static let reTempo = regex(#""tempo"\s*:\s*"([a-z]+)""#)
    /// `"updatedAt":1785777905225` (ms epoch, from `sessions/*.json`) — the session's last activity.
    private static let reUpdatedAt = regex(#""updatedAt"\s*:\s*(\d+)"#)
    /// `"cwd":"/path"` (from `sessions/*.json`) — the session working directory (project fallback).
    private static let reCwd = regex(#""cwd"\s*:\s*"([^"]*)""#)
    /// `"originCwd": "/repo/root"` (spaced, from `jobs/*/state.json`) — the repo root the session
    /// started in, so worktrees of one repo group into a single project.
    private static let reOriginCwd = regex(#""originCwd"\s*:\s*"([^"]*)""#)
    /// `"cleanupPeriodDays": 30` (from `settings.json`) — Claude Code's retention horizon (ADR-0031).
    private static let reCleanupDays = regex(#""cleanupPeriodDays"\s*:\s*(\d+)"#)
    /// `"statusUpdatedAt":1785808331664` (ms epoch, from `sessions/*.json`) — when the session last
    /// changed status. Preferred over `updatedAt` for freshness (it moves on every status flip).
    private static let reStatusUpdatedAt = regex(#""statusUpdatedAt"\s*:\s*(\d+)"#)
    /// `"updatedAt": "2026-08-04T01:27:32.234Z"` (ISO-8601, from `jobs/*/state.json`) — when the
    /// daemon last rewrote the job state. Note the **different format** from the session file's
    /// numeric `updatedAt`; the freshness guard parses both. Absent → treated as infinitely stale.
    private static let reStateUpdatedAtISO = regex(#""updatedAt"\s*:\s*"([^"]+)""#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure here is a programmer error, not runtime input.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    /// First capture group of `re` in `text`, or `nil` if the pattern does not match.
    private func firstMatch(_ re: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, range: range),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
