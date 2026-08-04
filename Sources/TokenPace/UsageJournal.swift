import Foundation
import TokenPaceKit

/// The append-only usage-journal writer (#242) — the shell side of the collector.
///
/// One line per successful usage poll (and one per failed poll / status poll / resume), appended to a
/// JSONL file under Application Support. The record shapes and all domain→line mapping live in the
/// pure Kit (``JournalRecord``); this type does only the I/O and the file-naming policy.
///
/// ## Never fails a poll
/// `append(_:)` and the gap helper never throw and never block the render path. Any write error is
/// logged and dropped — a missing journal line must never surface to the user or interrupt polling.
/// The caller dispatches it off the main actor (a detached task, like the archiver).
///
/// ## Multi-instance safe
/// Several TokenPace instances legitimately run at once (the notarized release plus dev copies), all
/// pointing at the same file. macOS makes `O_APPEND` atomic only up to ~256 bytes — well below our
/// 300–700-byte lines — so concurrent appends would interleave and corrupt lines. Each append takes an
/// exclusive `flock` for the write, serialising instances. Contention is nil (a write every few
/// minutes), so the lock is effectively free.
///
/// ## File naming
/// `usage-journal[-dev]-YYYY-MM.jsonl`:
/// - `-dev` unless the running bundle lives under `/Applications` — a dev build (`swift run`, or a
///   dev `.app` outside `/Applications`) must not pollute the release journal the maintainer relies on.
/// - `-YYYY-MM` from the record's UTC timestamp — natural monthly rotation for a future log-rotate,
///   and a bounded per-file size.
///
/// This type is an `actor` so its in-memory gap clock (`lastWriteInstant`) stays consistent across the
/// detached tasks that call it; the file lock guards *cross-process* consistency, the actor guards
/// *in-process*.
actor UsageJournal {

    /// The directory holding the journal files — `~/Library/Application Support/com.artem-n.tokenpace/`.
    private let directory: URL
    /// Whether the running bundle is the release (under `/Applications`). Fixed at init.
    private let isRelease: Bool
    private let fileManager: FileManager
    /// A dev override (`TOKENPACE_JOURNAL_FILE`): when set, every record is appended to this exact file
    /// instead of the month-split Application Support path. Lets a generated multi-day journal be fed to
    /// a downstream reader for UI verification without touching the real journal. `nil` in normal runs.
    private let overrideFile: URL?

    /// The instant of the last record written this process lifetime, for gap detection. In-memory
    /// only (resets on relaunch): after a relaunch the first poll legitimately emits a resume marker,
    /// which is the honest "we weren't looking while the app was down" signal.
    private var lastWriteInstant: Date?

    /// - Parameters:
    ///   - directory: Journal directory. Defaults to the Application Support subdirectory; injectable
    ///     so a test can point at a temporary tree.
    ///   - isRelease: Whether this is the release bundle. Defaults to the `/Applications` check;
    ///     injectable for tests.
    ///   - fileManager: Injectable for tests.
    init(
        directory: URL = UsageJournal.defaultDirectory,
        isRelease: Bool = UsageJournal.runningFromApplications,
        fileManager: FileManager = .default,
        overrideFile: URL? = UsageJournal.envOverrideFile
    ) {
        self.directory = directory
        self.isRelease = isRelease
        self.fileManager = fileManager
        self.overrideFile = overrideFile
    }

    /// The `TOKENPACE_JOURNAL_FILE` override, expanded, or `nil` when unset — a dev/verification hook.
    static var envOverrideFile: URL? {
        guard let path = ProcessInfo.processInfo.environment["TOKENPACE_JOURNAL_FILE"], !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// The default journal directory, `~/Library/Application Support/<bundle-id>/`. Falls back to the
    /// home directory if Application Support can't be resolved (never in practice).
    static var defaultDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent(AppLogger.subsystem, isDirectory: true)
    }

    /// Whether the running bundle lives under `/Applications` — the notarized release the maintainer
    /// launches from there. Symlinks are resolved so a `/Applications` alias still counts.
    static var runningFromApplications: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().path.hasPrefix("/Applications/")
    }

    // MARK: - Append

    /// Append one record. Before a `usage`/`error`/`status` record, emit a resume marker first if the
    /// gap since the last write exceeds the expected interval. Never throws; logs and drops on failure.
    ///
    /// - Parameters:
    ///   - record: The record to write (already built by a ``JournalRecord`` factory).
    ///   - at: The record's instant, for gap detection and month selection.
    ///   - expectedInterval: The cadence the caller expected since the last poll (for the gap marker).
    func append(_ record: JournalRecord, at instant: Date, expectedInterval: TimeInterval) {
        if let marker = JournalGap.marker(previous: lastWriteInstant, now: instant, expectedInterval: expectedInterval) {
            writeLine(.resume(marker), at: instant)
        }
        writeLine(record, at: instant)
        lastWriteInstant = instant
    }

    /// Append a batch of already-built records verbatim (no gap detection, no gates) — the dev-fixture
    /// path (#242). The fixture already carries its own resume markers, so this just serialises each
    /// record to the target file in order. Records are placed by their timestamp's month like any other
    /// write (or all into the override file when `TOKENPACE_JOURNAL_FILE` is set).
    func appendFixture(_ records: [(JournalRecord, Date)]) {
        for (record, instant) in records {
            writeLine(record, at: instant)
        }
    }

    /// Append a `status` record — an independent data sample on the status poll's own cadence. Unlike
    /// ``append(_:at:expectedInterval:)`` it runs **no** gap detection and does **not** touch the usage
    /// gap clock: the gap markers belong to the usage series, and a status poll landing between two
    /// usage polls must not reset that clock or emit a spurious resume marker.
    func appendStatus(_ record: JournalRecord, at instant: Date) {
        writeLine(record, at: instant)
    }

    // MARK: - Line write

    /// Encode a single record and append it under an exclusive file lock. All failures are swallowed
    /// (logged at `.error`) so a journal problem can never fail a poll.
    private func writeLine(_ record: JournalRecord, at instant: Date) {
        let url = fileURL(for: instant)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            var data = try encoder.encode(record)
            data.append(0x0A)  // '\n'

            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            appendLocked(data, to: url)
        } catch {
            AppLogger.journal.error("journal write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Append `data` to `url` under an exclusive advisory lock (`flock(LOCK_EX)`), so concurrent
    /// TokenPace instances serialise their appends and never interleave a line. Creates the file if
    /// absent. Uses raw POSIX file descriptors because `flock` needs one and `FileHandle` does not
    /// expose the lock.
    private func appendLocked(_ data: Data, to url: URL) {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            AppLogger.journal.error("journal open failed: errno=\(errno, privacy: .public)")
            return
        }
        defer { close(fd) }

        guard flock(fd, LOCK_EX) == 0 else {
            AppLogger.journal.error("journal lock failed: errno=\(errno, privacy: .public)")
            return
        }
        defer { flock(fd, LOCK_UN) }

        data.withUnsafeBytes { raw in
            var written = 0
            let total = raw.count
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            while written < total {
                let n = write(fd, base?.advanced(by: written), total - written)
                if n <= 0 {
                    AppLogger.journal.error("journal write() failed: errno=\(errno, privacy: .public)")
                    return
                }
                written += n
            }
        }
    }

    // MARK: - File naming

    /// The journal file for a given instant. The `TOKENPACE_JOURNAL_FILE` override wins (a single fixed
    /// file); otherwise `usage-journal[-dev]-YYYY-MM.jsonl` in ``directory``.
    private func fileURL(for instant: Date) -> URL {
        if let overrideFile { return overrideFile }
        return directory.appendingPathComponent(
            "usage-journal\(isRelease ? "" : "-dev")-\(Self.monthComponent(instant)).jsonl")
    }

    /// The `YYYY-MM` component of an instant in UTC (the month the record belongs to).
    static func monthComponent(_ instant: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month], from: instant)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}
