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
///         OR jobs/<jobId>/state.json .needs  != null
///         OR jobs/<jobId>/state.json .tempo  == "blocked"
/// ```
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

    /// The number of live sessions currently awaiting user input. `0` when the feature has nothing
    /// to show (no live sessions, or none blocked) — the UI hides its indicator at `0`.
    ///
    /// Pure and side-effect-free. Any I/O error (unreadable dir, torn file mid-write) is swallowed
    /// and simply contributes nothing to the count.
    public func scan() -> Int {
        let sessionsDir = claudeHome.appendingPathComponent("sessions")
        guard let entries = try? fileManager.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil
        ) else {
            return 0
        }
        var count = 0
        for url in entries where url.pathExtension == "json" {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if isAwaiting(sessionJSON: raw) { count += 1 }
        }
        return count
    }

    // MARK: Per-session decision

    /// Decides whether a single session (its `sessions/<pid>.json` text) is awaiting input, reading
    /// its matching `jobs/<jobId>/state.json` when the session status alone is inconclusive.
    ///
    /// Internal (not private) so unit tests can exercise the join logic directly on fixture strings.
    func isAwaiting(sessionJSON: String) -> Bool {
        // 1. Direct real-time signal from the session file. Covers an active permission / plan prompt.
        if firstMatch(Self.reStatus, in: sessionJSON) == "waiting" { return true }

        // 2. Semantic "blocked, waiting for your decision" — the session file may still say "idle"
        //    here, so consult the daemon-computed job state (the FleetView source).
        guard let jobId = firstMatch(Self.reJobID, in: sessionJSON) else { return false }
        let stateURL = claudeHome
            .appendingPathComponent("jobs")
            .appendingPathComponent(jobId)
            .appendingPathComponent("state.json")
        guard let state = try? String(contentsOf: stateURL, encoding: .utf8) else { return false }

        // `needs` present (a non-empty string) is the most precise "awaiting" marker; `tempo` ==
        // "blocked" is the same signal expressed as the coarse state. Either one counts.
        if let needs = firstMatch(Self.reNeeds, in: state), !needs.isEmpty { return true }
        if firstMatch(Self.reTempo, in: state) == "blocked" { return true }
        return false
    }

    // MARK: Field extraction (no JSONDecoder — see type doc)

    /// `"status":"idle"` (compact, from `sessions/*.json`).
    private static let reStatus = regex(#""status"\s*:\s*"([a-z]+)""#)
    /// `"jobId":"04c0e8f2"` (compact, from `sessions/*.json`).
    private static let reJobID = regex(#""jobId"\s*:\s*"([^"]+)""#)
    /// `"needs": "approve plan"` (spaced, from `jobs/*/state.json`). Absent or `null` → no match.
    private static let reNeeds = regex(#""needs"\s*:\s*"([^"]*)""#)
    /// `"tempo": "blocked"` (spaced, from `jobs/*/state.json`).
    private static let reTempo = regex(#""tempo"\s*:\s*"([a-z]+)""#)

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
