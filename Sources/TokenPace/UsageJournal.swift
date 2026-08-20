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

    // MARK: - Migration (#386)

    /// The suffix a pre-migration copy keeps, named after the format version the copy **contains**
    /// (`.v2.bak` for a file that was v2). **Never deleted by the app** — see ``migrateIfNeeded()``.
    ///
    /// Versioned since #401. It used to be a hardcoded `.v1.bak`, which described the contents
    /// exactly while there was only one migration and started lying as soon as there were two: the
    /// v2 → v3 pass found a `.v1.bak` already in place, kept it (correctly — it must never overwrite
    /// older evidence) and discarded the v2 state instead of preserving it under its own name. The
    /// archive then jumped v1 → v3 with the middle generation gone.
    ///
    /// Existing `.v1.bak` files need no migration of their own: they hold v1 and are already named
    /// correctly under this rule.
    static func backupSuffix(forVersion version: Int) -> String { ".v\(version).bak" }

    /// Matches any versioned backup, for callers that need to recognise one without knowing which
    /// generation it holds (file listing, tests).
    static func isBackup(fileName: String) -> Bool {
        fileName.range(of: #"\.v\d+\.bak$"#, options: .regularExpression) != nil
    }

    /// Bring every journal file up to the current sample format, in chronological order.
    ///
    /// Called once at launch, **before the first poll**, so no append can interleave with a rewrite.
    /// Files already in the current format are detected and skipped without being touched — so this
    /// costs one read per file on every launch after the first, and nothing else.
    ///
    /// Each file is rewritten out-of-place and swapped in with two `rename` calls, which are atomic on
    /// APFS: a crash at any point leaves either the old file or the new one, never a half-written one.
    ///
    /// **The `.v<n>.bak` copies are kept forever.** After migration `util` is the reconstructed
    /// value, so the backup is the only remaining record of what the server actually returned — if
    /// the algorithm turns out to have a flaw, that is the only way to redo the history. The app
    /// never deletes them; removing them is the maintainer's call.
    ///
    /// Each generation keeps its **own** backup (#401): a file migrated v1 → v2 → v3 leaves both
    /// `.v1.bak` and `.v2.bak`, so any single step can be re-examined without replaying the ones
    /// before it. A fixed name would have meant only the first migration's state survived.
    ///
    /// The reconstruction state is threaded from one file to the next, because the journal is split by
    /// month and starting each file cold would leave every line of a new month on an inherited anchor
    /// for no reason.
    func migrateIfNeeded() {
        let files = journalFiles()
        guard !files.isEmpty else { return }

        var state = WeeklyInterpolator()
        var migratedFiles = 0
        // Which backup names this run actually wrote. A run spanning several months can touch files
        // of different generations, so the log names what it produced rather than one fixed suffix.
        var backupSuffixesWritten: Set<String> = []

        for url in files {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                AppLogger.journal.error(
                    "journal migration: cannot read \(url.lastPathComponent, privacy: .public)")
                continue
            }
            let (rewritten, carried, outcome) = JournalMigration.migrate(contents: contents, state: state)
            state = carried
            guard outcome.changedAnything else { continue }

            // A rewrite driven purely by a colour-model bump (#426) leaves the file at the current
            // format, so the pass reports no older generation and the backup is named after what the
            // file still is. `?? 1` would have claimed it was v1 — the one thing it certainly is not.
            let wasVersion = outcome.migratedFromVersion ?? UsageSample.currentVersion
            if swapIn(rewritten, at: url, wasVersion: wasVersion) {
                migratedFiles += 1
                backupSuffixesWritten.insert(Self.backupSuffix(forVersion: wasVersion))
                AppLogger.journal.notice(
                    "\(url.lastPathComponent, privacy: .public): \(outcome.logMessage, privacy: .public)")
            }
        }
        if migratedFiles > 0 {
            let suffixes = backupSuffixesWritten.sorted().joined(separator: ", ")
            AppLogger.journal.notice(
                "journal migration complete: \(migratedFiles, privacy: .public) file(s); originals kept as \(suffixes, privacy: .public)")
        }
    }

    /// Every journal file this instance owns, oldest first — the month suffix sorts chronologically
    /// as a string, which is the whole reason it is `YYYY-MM`.
    private func journalFiles() -> [URL] {
        if let overrideFile {
            return fileManager.fileExists(atPath: overrideFile.path) ? [overrideFile] : []
        }
        let all = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return all
            .filter { JournalMigration.belongsToBuild(fileName: $0.lastPathComponent,
                                                      isRelease: isRelease) }
            // Sorted by name, which sorts chronologically — that is the whole reason the suffix is
            // `YYYY-MM` — so the reconstruction state threads through the months in order.
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Write `contents` beside `url` and swap it in atomically, keeping the original as
    /// `.v<wasVersion>.bak`.
    ///
    /// Order matters: the new file is fully written and `fsync`ed *before* anything moves, and the
    /// original is renamed aside rather than overwritten, so at no point does the live path hold a
    /// partial file. Returns whether the swap happened.
    ///
    /// - Parameter wasVersion: the format generation `url` currently holds, which names its backup.
    private func swapIn(_ contents: String, at url: URL, wasVersion: Int) -> Bool {
        let staging = url.appendingPathExtension("migrating")
        let backup = URL(fileURLWithPath: url.path + Self.backupSuffix(forVersion: wasVersion))

        guard let data = contents.data(using: .utf8) else { return false }
        do {
            try data.write(to: staging, options: .atomic)   // writes + renames into place, fsync'd
        } catch {
            AppLogger.journal.error(
                "journal migration: cannot stage \(url.lastPathComponent, privacy: .public)")
            return false
        }

        // Move the original aside under the name of the generation it holds. Because the suffix is
        // versioned (#401), a second migration no longer collides with the first one's backup: the
        // v1 → v2 pass leaves `.v1.bak`, the v2 → v3 pass leaves `.v2.bak`, and the chain of states
        // stays complete. Before that fix this branch found the existing `.v1.bak`, kept it (right)
        // and deleted the v2 file (wrong) — losing the middle generation.
        //
        // A backup under *this* version already existing still means a previous run migrated this
        // same generation, so the original evidence is already safe and the current file is a
        // duplicate of work already recorded. Never overwrite it.
        if !fileManager.fileExists(atPath: backup.path) {
            do {
                try fileManager.moveItem(at: url, to: backup)
            } catch {
                try? fileManager.removeItem(at: staging)
                AppLogger.journal.error(
                    "journal migration: cannot back up \(url.lastPathComponent, privacy: .public)")
                return false
            }
        } else {
            try? fileManager.removeItem(at: url)
        }

        do {
            try fileManager.moveItem(at: staging, to: url)
            return true
        } catch {
            // The swap failed after the original was moved aside — put it back rather than leaving
            // the live path empty.
            try? fileManager.moveItem(at: backup, to: url)
            try? fileManager.removeItem(at: staging)
            AppLogger.journal.error(
                "journal migration: cannot swap in \(url.lastPathComponent, privacy: .public)")
            return false
        }
    }
}
