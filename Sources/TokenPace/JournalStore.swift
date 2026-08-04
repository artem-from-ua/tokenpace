import Foundation
import TokenPaceKit

/// The read side of the usage journal (#245) — resolves the on-disk journal files and parses them into
/// `[JournalRecord]` for the Insights aggregator. The counterpart to ``UsageJournal`` (which only
/// appends); the two never share a handle.
///
/// File resolution mirrors ``UsageJournal``'s write policy:
/// - `TOKENPACE_JOURNAL_FILE` set → read exactly that one file (dev/verification override).
/// - Otherwise → the month-split files in Application Support: `usage-journal-YYYY-MM.jsonl` for a
///   release build (bundle under `/Applications`), `usage-journal-dev-YYYY-MM.jsonl` for a dev build.
///   Files are read in chronological (filename) order and concatenated, then parsed by the pure
///   ``JournalReader/parse(_:)`` (which tolerates a torn tail line).
///
/// Everything is best-effort: a missing directory / no matching files / an unreadable file yields an
/// empty result rather than an error — the Insights window then shows an honest empty state.
enum JournalStore {

    /// Load and parse the current journal into records (chronological order). Never throws.
    static func load(fileManager: FileManager = .default) -> [JournalRecord] {
        let urls = files(fileManager: fileManager)
        guard !urls.isEmpty else { return [] }
        // Concatenate the files in order; each already ends with a trailing newline, so joining is safe.
        let contents = urls.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        let result = JournalReader.parse(contents)
        if result.skipped > 0 {
            AppLogger.journal.debug("journal read: skipped \(result.skipped, privacy: .public) unparseable line(s)")
        }
        return result.records
    }

    /// The journal files to read, in chronological order.
    /// - The override file when `TOKENPACE_JOURNAL_FILE` is set (single file).
    /// - Else the month-split files for this build kind (release vs dev), sorted by name (which sorts by
    ///   `YYYY-MM` chronologically).
    static func files(fileManager: FileManager = .default) -> [URL] {
        if let override = UsageJournal.envOverrideFile {
            return fileManager.fileExists(atPath: override.path) ? [override] : []
        }
        let dir = UsageJournal.defaultDirectory
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        // `usage-journal-YYYY-MM.jsonl` (release) vs `usage-journal-dev-YYYY-MM.jsonl` (dev). The dev
        // prefix is a strict superset of the release one, so match on the exact prefix for this build.
        let prefix = UsageJournal.runningFromApplications ? "usage-journal-" : "usage-journal-dev-"
        let devPrefix = "usage-journal-dev-"
        return entries
            .filter { url in
                let name = url.lastPathComponent
                guard name.hasSuffix(".jsonl"), name.hasPrefix(prefix) else { return false }
                // Release prefix also matches dev files (shared stem) — exclude them explicitly.
                if !UsageJournal.runningFromApplications { return true }   // dev build: prefix is dev-specific
                return !name.hasPrefix(devPrefix)                          // release build: drop dev files
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
