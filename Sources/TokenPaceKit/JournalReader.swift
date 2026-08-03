import Foundation

// MARK: - JournalReader

/// Parses the append-only usage journal back into ``JournalRecord``s — the read side the downstream
/// Insights features (#239/#240/#241) consume.
///
/// Pure and I/O-free: it takes the file **contents** as a string (the shell's thin wrapper reads the
/// file and, for the month-split journal, concatenates the release `usage-journal-YYYY-MM.jsonl`
/// files in chronological order). Each line is decoded independently, and a corrupted or
/// half-written **tail** line — the classic hazard of a crash mid-append — is skipped, not fatal.
public enum JournalReader {

    /// The result of parsing: the decoded records in file order, and how many non-empty lines failed
    /// to decode (a corrupt tail, a torn line from a crash, or a line a much older reader can't parse).
    public struct Result: Sendable, Equatable {
        public let records: [JournalRecord]
        public let skipped: Int
        public init(records: [JournalRecord], skipped: Int) {
            self.records = records
            self.skipped = skipped
        }
    }

    /// Parse JSONL contents into records, tolerating a corrupt/torn tail.
    ///
    /// - Empty lines (including a trailing newline's empty final segment) are ignored — they count
    ///   neither as records nor as skips.
    /// - A non-empty line that fails to decode is **skipped** and counted in ``Result/skipped``; the
    ///   parse continues. A single torn last line (interrupted append) therefore costs one skip, never
    ///   the whole file.
    /// - An unknown `kind` is **not** a skip: it decodes to ``JournalRecord/unknown`` (a valid record),
    ///   so a forward-compatible line written by a newer build is preserved, not discarded.
    public static func parse(_ contents: String) -> Result {
        let decoder = JSONDecoder()
        var records: [JournalRecord] = []
        var skipped = 0
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(JournalRecord.self, from: data) else {
                skipped += 1
                continue
            }
            records.append(record)
        }
        return Result(records: records, skipped: skipped)
    }
}
