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
/// tolerate optional whitespace. A full scan measured ~0.18 ms.
///
/// **Incremental by mtime (in-memory cache).** The shell polls this every ~5 s (only while Claude
/// Code is running and the screen is unlocked). To avoid re-reading unchanged files, the scanner
/// keeps a per-session cache `path → (mtime, awaiting)` and re-reads a session file **only** when
/// its modification date is newer than the cached one — otherwise it reuses the cached verdict.
/// Sessions whose files vanished are dropped from the cache each tick. The cache lives **only in
/// memory** and is deliberately **not persisted across launches**: a fresh process starts with an
/// empty cache, so the first tick reads every live session and subsequent ticks go incremental.
///
/// **Private, undocumented format.** The file layout and the `status`/`state`/`tempo`/`needs`
/// values are Claude Code internals (observed on v2.1.212) and may change without notice. Every
/// lookup degrades gracefully: a missing field / dir / new value is treated as "not awaiting", so
/// the count never crashes and the feature quietly reads zero rather than misbehaving.
///
/// `claudeHome` and `fileManager` are injectable so a test can point at a fixture tree, mirroring
/// ``LogArchiver``. A `final class` (not a value type) because it owns the mutable mtime cache; the
/// shell drives ``scan()`` from its single poll heartbeat, so it is not concurrently mutated.
public final class AwaitingInputScanner {
    /// The `~/.claude` directory. Injectable so a test can point at a fixture tree.
    private let claudeHome: URL
    private let fileManager: FileManager

    /// Per-session incremental cache: the session file's last-seen mtime and the awaiting verdict
    /// derived from it. In-memory only, never persisted (see type doc).
    private struct CacheEntry {
        var mtime: Date
        var awaiting: Bool
    }
    private var cache: [String: CacheEntry] = [:]

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
    /// Re-reads only session files whose mtime advanced since the last call; reuses cached verdicts
    /// otherwise. Any I/O error (unreadable dir, torn file mid-write) is swallowed and simply
    /// contributes nothing to the count.
    public func scan() -> Int {
        let sessionsDir = claudeHome.appendingPathComponent("sessions")
        guard let entries = try? fileManager.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            cache.removeAll()   // sessions dir gone → nothing awaiting, forget stale entries
            return 0
        }

        var count = 0
        var seen = Set<String>()
        for url in entries where url.pathExtension == "json" {
            let key = url.path
            seen.insert(key)
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate

            // Reuse the cached verdict if the file has not been modified since we last read it.
            if let mtime, let cached = cache[key], cached.mtime >= mtime {
                if cached.awaiting { count += 1 }
                continue
            }

            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                // Unreadable (e.g. torn mid-write) — skip this tick, keep any prior cache entry.
                if cache[key]?.awaiting == true { count += 1 }
                continue
            }
            let awaiting = isAwaiting(sessionJSON: raw)
            if let mtime { cache[key] = CacheEntry(mtime: mtime, awaiting: awaiting) }
            if awaiting { count += 1 }
        }

        // Drop cache entries for sessions whose files disappeared this tick.
        cache = cache.filter { seen.contains($0.key) }
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
