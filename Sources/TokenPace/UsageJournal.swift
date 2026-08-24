import Foundation
import TokenPaceKit

/// The append-only usage-journal writer (#242) — the shell side of the collector. One line per
/// successful usage poll (and one per failed poll / status poll / resume), appended to a JSONL file
/// under Application Support. The record shapes and domain→line mapping live in the pure Kit
/// (``JournalRecord``); this type does only the I/O and the file-naming policy.
///
/// **Never fails a poll**: `append(_:)` and the gap helper never throw and never block the render
/// path. Any write error is logged and dropped.
///
/// **Multi-instance safe**: several TokenPace instances legitimately run at once (the notarized
/// release plus dev copies), all pointing at the same file. macOS makes `O_APPEND` atomic only up to
/// ~256 bytes — below our 300–700-byte lines — so concurrent appends would interleave and corrupt
/// lines. Each append takes an exclusive `flock` for the write, serialising instances.
///
/// **File naming**: `usage-journal[-dev]-YYYY-MM.jsonl` — `-dev` unless the running bundle lives
/// under `/Applications`, so a dev build never pollutes the release journal; `-YYYY-MM` from the
/// record's UTC timestamp for natural monthly rotation.
///
/// An `actor` so its in-memory gap clocks (`lastPollInstant`) and open error runs stay consistent
/// across the detached tasks that call it; the file lock guards *cross-process* consistency, the actor
/// guards *in-process*.
actor UsageJournal {

    private let directory: URL
    /// Whether the running bundle is the release (under `/Applications`). Fixed at init.
    private let isRelease: Bool
    private let fileManager: FileManager
    /// A dev override (`TOKENPACE_JOURNAL_FILE`): when set, every record is appended to this exact file
    /// instead of the month-split Application Support path, so a generated multi-day journal can be
    /// fed to a downstream reader without touching the real journal.
    private let overrideFile: URL?

    /// Per provider, the last instant a usage poll was **recorded**, whether or not a line was written
    /// for it.
    ///
    /// The distinction matters since consecutive identical failures collapse into one line: a
    /// suppressed write still means "we were looking", and the gap detector answers exactly that
    /// question. Stamping only on an actual write would make a long collapsed run look like an
    /// outage and emit a resume marker across time we spent polling hard.
    ///
    /// Keyed by provider, not one shared clock: a shared one lets one provider's polling advance the
    /// other's gap detector, so an outage on the quiet provider would leave **no** hole in the record
    /// and read as continuous observation — the one flaw a written-down series cannot recover from.
    ///
    /// In-memory only (resets on relaunch): after a relaunch the first poll legitimately emits a
    /// resume marker, the honest "we weren't looking while the app was down" signal.
    private var lastPollInstant: [ProviderID: Date] = [:]

    /// Per provider, the error run being accumulated — see ``ErrorRunCollapse``. In-memory only, and a
    /// hard kill loses it: acceptable, because a run still open describes a failure that has not been
    /// fixed, and the next launch records it again within one cadence.
    ///
    /// Keyed by provider for the same reason the identity tuple is: two providers failing identically
    /// on one shared slot would fold into one line carrying one of their names.
    private var openErrorRun: [ProviderID: ErrorRun] = [:]

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

    static var envOverrideFile: URL? {
        guard let path = ProcessInfo.processInfo.environment["TOKENPACE_JOURNAL_FILE"], !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// `~/Library/Application Support/<bundle-id>/`. Falls back to the home directory if Application
    /// Support can't be resolved (never in practice).
    static var defaultDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent(AppLogger.subsystem, isDirectory: true)
    }

    /// Symlinks are resolved so a `/Applications` alias still counts.
    static var runningFromApplications: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().path.hasPrefix("/Applications/")
    }

    // MARK: - Append

    /// Append one record. Before a `usage` record, emit a resume marker first if the gap since the
    /// last poll exceeds the expected interval. Never throws; logs and drops on failure.
    ///
    /// An `error` record does not necessarily write a line: consecutive identical failures are
    /// accumulated by ``ErrorRunCollapse`` and written once when the run ends (ADR-0123).
    ///
    /// - Parameters:
    ///   - record: The record to write (already built by a ``JournalRecord`` factory).
    ///   - at: The record's instant, for gap detection and month selection.
    ///   - expectedInterval: The cadence the caller expected since the last poll (for the gap marker).
    ///   - provider: whose poll this is. Selects the gap clock and the open-run slot, both per
    ///     provider.
    func append(
        _ record: JournalRecord, at instant: Date, expectedInterval: TimeInterval,
        provider: ProviderID = .claude
    ) {
        // An error may be the same error repeating: accumulate it and write only when the run ends.
        // The gap clock advances either way — the poll happened.
        if case let .error(sample) = record {
            switch ErrorRunCollapse.admit(openErrorRun[provider], sample: sample, at: instant) {
            case let .extend(run):
                openErrorRun[provider] = run
            case let .flush(closed, next):
                writeClosedRun(closed)
                openErrorRun[provider] = next
            }
            lastPollInstant[provider] = instant
            return
        }

        // Any other record ends **this provider's** run: write it out first so the file keeps its
        // order. Another provider's run is a different failure and keeps accumulating.
        flushOpenErrorRun(provider)

        if let marker = JournalGap.marker(
            previous: lastPollInstant[provider], now: instant,
            expectedInterval: expectedInterval, provider: provider) {
            writeLine(.resume(marker), at: instant)
        }
        writeLine(record, at: instant)
        lastPollInstant[provider] = instant
    }

    /// Write one provider's accumulated run, if any. Called when a non-error record arrives for it.
    func flushOpenErrorRun(_ provider: ProviderID = .claude) {
        guard let run = openErrorRun.removeValue(forKey: provider) else { return }
        writeClosedRun(run)
    }

    /// Write **every** provider's accumulated run. What termination must call: a per-provider flush
    /// there would write one run and silently drop the rest.
    func flushAllErrorRuns() {
        for provider in openErrorRun.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            flushOpenErrorRun(provider)
        }
    }

    /// Serialise one closed run at the instant of its **first** attempt — where the failure began,
    /// and where a reader scanning by time expects to find it.
    private func writeClosedRun(_ run: ErrorRun) {
        guard let sample = ErrorRunCollapse.close(run) else { return }
        // No gap check here: the run's own first attempt already advanced the clock when it arrived,
        // so this write is never the far side of a hole. The marker for a genuine outage is emitted
        // by whatever record follows the run.
        writeLine(.error(sample), at: run.first)
    }

    /// The dev-fixture path: no gap detection, no gates — the fixture already carries its own resume
    /// markers.
    func appendFixture(_ records: [(JournalRecord, Date)]) {
        for (record, instant) in records {
            writeLine(record, at: instant)
        }
    }

    /// Unlike ``append(_:at:expectedInterval:)`` this runs **no** gap detection and does **not** touch
    /// the usage gap clock — a status poll landing between two usage polls must not emit a spurious
    /// resume marker. It leaves any open error run alone for the same reason: a status poll is not a
    /// break in the *usage* series.
    func appendStatus(_ record: JournalRecord, at instant: Date) {
        writeLine(record, at: instant)
    }

    // MARK: - Line write

    /// All failures are swallowed (logged at `.error`) so a journal problem can never fail a poll.
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

    /// `flock(LOCK_EX)` so concurrent TokenPace instances serialise their appends and never
    /// interleave a line. Uses raw POSIX file descriptors because `FileHandle` does not expose the lock.
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

    /// The `TOKENPACE_JOURNAL_FILE` override wins; otherwise `usage-journal[-dev]-YYYY-MM.jsonl` in
    /// ``directory``.
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

    /// The suffix a pre-migration copy keeps. **Never deleted by the app** — see
    /// ``migrateIfNeeded()``. Naming and collision handling live in `JournalBackupNaming`, which is
    /// pure and tested; this target only does the I/O.
    static func backupSuffix(forVersion version: Int) -> String {
        JournalBackupNaming.suffix(forVersion: version)
    }

    static func isBackup(fileName: String) -> Bool {
        JournalBackupNaming.isBackup(fileName: fileName)
    }

    /// Bring every journal file up to the current sample format, in chronological order. Called once
    /// at launch, **before the first poll**, so no append can interleave with a rewrite. Each file is
    /// rewritten out-of-place and swapped in with two `rename` calls, atomic on APFS: a crash at any
    /// point leaves either the old file or the new one, never a half-written one.
    ///
    /// **The `.v<n>.bak` copies are kept forever** — after migration the field is a reconstructed
    /// value, so the backup is the only remaining record of what the server actually returned. Each
    /// generation keeps its **own** backup: a file migrated v1 → v2 → v3 leaves both `.v1.bak` and
    /// `.v2.bak`, so any single step can be re-examined.
    ///
    /// A repeat pass over the same generation asks for a name that is already taken; when the file
    /// on disk holds *different* bytes it gets a timestamped name instead (`JournalBackupNaming`).
    /// The live file is only ever deleted when an existing backup already holds its exact bytes.
    ///
    /// Reconstruction state threads from one file to the next, since the journal is split by month.
    func migrateIfNeeded() {
        let files = journalFiles()
        guard !files.isEmpty else { return }

        var state = WeeklyInterpolator()
        var migratedFiles = 0
        // A run spanning several months can touch files of different generations.
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

            // A rewrite driven purely by a colour-model bump leaves the file at the current format,
            // so the pass reports no older generation. `?? 1` would falsely claim it was v1.
            let wasVersion = outcome.migratedFromVersion ?? UsageSample.currentVersion
            if let suffix = swapIn(rewritten, at: url, wasVersion: wasVersion) {
                migratedFiles += 1
                // The suffix the original is actually under — a timestamped one when the plain name
                // was taken by different bytes. Reporting the requested name would name a file that
                // holds someone else's generation.
                backupSuffixesWritten.insert(suffix)
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

    private func journalFiles() -> [URL] {
        if let overrideFile {
            return fileManager.fileExists(atPath: overrideFile.path) ? [overrideFile] : []
        }
        let all = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return all
            .filter { JournalMigration.belongsToBuild(fileName: $0.lastPathComponent,
                                                      isRelease: isRelease) }
            // Sorted by name, which sorts chronologically since the suffix is `YYYY-MM` — so
            // reconstruction state threads through the months in order.
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Write `contents` beside `url` and swap it in atomically, putting the original aside as a
    /// `.bak`. Order matters: the new file is fully written *before* anything moves, and the
    /// original is renamed aside rather than overwritten, so the live path is never partial.
    ///
    /// **The live file is never deleted unless its exact current bytes are already stored
    /// somewhere.** The one delete path here is reachable only after a byte-for-byte match against
    /// an existing backup, which is what makes it a no-op rather than a loss.
    ///
    /// Returns the suffix the original was kept under, or `nil` if the swap failed. A successful
    /// swap that deleted a redundant copy returns the existing backup's suffix — the bytes are
    /// there under that name, which is what the completion log reports.
    private func swapIn(_ contents: String, at url: URL, wasVersion: Int) -> String? {
        let staging = url.appendingPathExtension("migrating")
        let primarySuffix = Self.backupSuffix(forVersion: wasVersion)
        let primary = URL(fileURLWithPath: url.path + primarySuffix)

        guard let data = contents.data(using: .utf8) else { return nil }
        do {
            try data.write(to: staging, options: .atomic)   // writes + renames into place, fsync'd
        } catch {
            AppLogger.journal.error(
                "journal migration: cannot stage \(url.lastPathComponent, privacy: .public)")
            return nil
        }

        // A taken primary name is expected, not exceptional: the suffix is named after the oldest
        // usage line, so every pass over the same generation asks for the same name. Whether the
        // evidence is already safe depends on the bytes, not on the name existing.
        let existingMatches: Bool? = fileManager.fileExists(atPath: primary.path)
            ? sameContents(url, primary)
            : nil

        let backup: URL?   // where the original went; nil when it was a redundant copy
        switch JournalBackupNaming.disposition(forVersion: wasVersion,
                                               existingMatchesLive: existingMatches,
                                               now: Date()) {
        case .deleteAlreadyBackedUp:
            // `primary` holds these exact bytes. Deleting loses nothing, and keeping the older
            // backup untouched preserves the rule that a backup is never overwritten (#401).
            try? fileManager.removeItem(at: url)
            backup = nil

        case .moveAside(let suffix):
            // Two backups within the same second would still be distinct evidence, so step the name
            // until it is free rather than overwriting one.
            let target = firstFreeURL(base: url, suffix: suffix)
            do {
                try fileManager.moveItem(at: url, to: target)
            } catch {
                try? fileManager.removeItem(at: staging)
                AppLogger.journal.error(
                    "journal migration: cannot back up \(url.lastPathComponent, privacy: .public)")
                return nil
            }
            backup = target
        }

        do {
            try fileManager.moveItem(at: staging, to: url)
            return backup.map { $0.lastPathComponent.dropFirst(url.lastPathComponent.count) }
                .map(String.init) ?? primarySuffix
        } catch {
            // The swap failed after the original was moved aside — put it back rather than leaving
            // the live path empty. Nothing to restore on the delete path: the live bytes are in
            // `primary` and the migrated copy never landed.
            if let backup { try? fileManager.moveItem(at: backup, to: url) }
            try? fileManager.removeItem(at: staging)
            AppLogger.journal.error(
                "journal migration: cannot swap in \(url.lastPathComponent, privacy: .public)")
            return nil
        }
    }

    /// Byte-for-byte equality. Size is compared first: these journals run to several megabytes, and
    /// a differing length settles it without reading either file.
    private func sameContents(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileSizeKey]
        let sizeA = (try? a.resourceValues(forKeys: key))?.fileSize
        let sizeB = (try? b.resourceValues(forKeys: key))?.fileSize
        guard let sizeA, let sizeB, sizeA == sizeB else { return false }
        guard let dataA = try? Data(contentsOf: a, options: .mappedIfSafe),
              let dataB = try? Data(contentsOf: b, options: .mappedIfSafe) else { return false }
        return dataA == dataB
    }

    /// `base + suffix`, or the first `-2`, `-3`, … variant that does not exist. Only reached when a
    /// timestamped name repeats within one second.
    private func firstFreeURL(base: URL, suffix: String) -> URL {
        let first = URL(fileURLWithPath: base.path + suffix)
        guard fileManager.fileExists(atPath: first.path) else { return first }
        for n in 2... {
            let candidate = URL(fileURLWithPath: base.path + suffix + "-\(n)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return first
    }
}
