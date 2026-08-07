import Foundation
import TokenPaceKit

// MARK: - LogArchiver

/// Copies Claude Code's raw session logs from `~/.claude/…` into a user-chosen archive folder,
/// **accumulate-only** — files Claude Code has already pruned (its 30-day `cleanupPeriodDays`
/// cleanup) are never removed from the archive (#110). The thin I/O shell around the pure
/// ``ArchiveSyncPlan`` decision: it scans the source and destination trees into `[ArchiveEntry]`
/// snapshots, asks the plan which files to copy, and copies exactly those.
///
/// **Sources are an explicit allow-list**, never "all of `~/.claude` minus excludes" — so
/// credentials (`~/.claude/.credentials.json`) and other secrets can never be mirrored by
/// construction. The roots are the per-session historical data that Claude Code age-prunes and that
/// is worth keeping:
/// - `projects/` — full session transcripts, plus each session's `subagents/` and `tool-results/`.
/// - `file-history/` — pre-edit file snapshots (checkpoint restore).
/// - `plans/` — plan-mode files.
///
/// Runs off the main thread on the daily heartbeat (`ArchiveCadence`); pure `FileManager`, no
/// subprocess (see ADR-0031 for why native Swift over `rsync`).
struct LogArchiver {

    /// The archive roots, relative to `~/.claude/`. An allow-list — see the type doc.
    static let sourceRoots = ["projects", "file-history", "plans"]

    /// Outcome of one sync run, surfaced to the Settings status line.
    struct Summary {
        /// Files copied this run (new or changed).
        let copied: Int
        /// Bytes copied this run.
        let bytes: Int64
        /// Total files in the archive after this run — the union of what was already mirrored
        /// (including files Claude Code has since pruned from the source) and everything just copied.
        let totalInArchive: Int
        /// Total bytes of every file in the archive after this run (same union as `totalInArchive`).
        let totalBytesInArchive: Int64
    }

    enum ArchiveError: Error {
        /// The destination is unset, unwritable, or could not be created.
        case destinationUnavailable
        /// Copying the planned files would leave less than ``ArchiveSpacePlan/minFreeBytesAfterCopy``
        /// free on the destination volume, so the run refused **before** writing anything (#306).
        ///
        /// Modelled as an error rather than a `Summary` field on purpose: the shell only advances the
        /// `lastArchiveSync` marker on `.success`, so a blocked run stays due and retries by itself.
        /// A field on `Summary` would land in the success branch and advance the marker — exactly the
        /// "records a failure as a success" bug this gate exists to prevent.
        ///
        /// Unlike the battery gate this is a **block**, not a silent defer: a full disk does not fix
        /// itself, so the Settings pane names the reason. Carries both figures for the log line.
        case insufficientSpace(needBytes: Int64, freeBytes: Int64)
    }

    private let claudeHome: URL
    private let fileManager: FileManager

    /// - Parameter claudeHome: The `~/.claude` directory. Injectable so a test can point at a
    ///   temporary tree; production passes the real one.
    init(claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"),
         fileManager: FileManager = .default) {
        self.claudeHome = claudeHome
        self.fileManager = fileManager
    }

    /// One root's phase-1 scan, holding everything the later phases need so each tree is walked
    /// exactly once. A root whose source is gone is represented with empty `sourceEntries`/`toCopy`,
    /// which folds to the same totals the old dedicated early-continue produced.
    private struct RootPlan {
        let sourceRoot: URL
        let destRoot: URL
        let sourceEntries: [ArchiveEntry]
        let destEntries: [ArchiveEntry]
        let toCopy: [ArchiveEntry]
    }

    /// Mirror the allow-listed roots into `destination`, copying only new/changed files and never
    /// deleting. Returns how much was copied. Throws ``ArchiveError/destinationUnavailable`` if the
    /// destination cannot be prepared, or ``ArchiveError/insufficientSpace(needBytes:freeBytes:)`` if
    /// the copy would run the destination volume below the free-space floor.
    ///
    /// Runs in three phases (#306). The scan is separated from the copying so the space gate judges
    /// the **whole run** rather than whichever root it happens to reach first: gating per root could
    /// copy two roots and then refuse the third, leaving the archive half-updated — the worst of both
    /// outcomes. Nothing is written before the gate has passed.
    func sync(to destination: URL) throws -> Summary {
        try ensureDirectory(destination)

        // Phase 1 — scan every root and build the complete plan before copying a single byte.
        let plans = Self.sourceRoots.map { root -> RootPlan in
            let sourceRoot = claudeHome.appendingPathComponent(root)
            let destRoot = destination.appendingPathComponent(root)

            // The destination mirror is scanned even when the source root is gone, so a root Claude
            // Code has fully pruned still contributes its archived files to the total.
            let destEntries = scan(destRoot)
            guard fileManager.fileExists(atPath: sourceRoot.path) else {
                return RootPlan(sourceRoot: sourceRoot, destRoot: destRoot,
                                sourceEntries: [], destEntries: destEntries, toCopy: [])
            }

            let sourceEntries = scan(sourceRoot)
            let toCopy = ArchiveSyncPlan.filesToCopy(source: sourceEntries, dest: destEntries)

            AppLogger.archive.debug(
                "archive root \(root, privacy: .public): \(sourceEntries.count, privacy: .public) source files, \(toCopy.count, privacy: .public) to copy")

            return RootPlan(sourceRoot: sourceRoot, destRoot: destRoot,
                            sourceEntries: sourceEntries, destEntries: destEntries, toCopy: toCopy)
        }

        // Phase 2 — the free-space gate, once, against the combined plan. The volume read stays here
        // rather than being injected from the main actor: `volumeAvailableCapacityForImportantUsage`
        // can block while an external disk spins up, and this already runs off the main thread.
        // An unreadable volume reads as `.max` (fail-open, mirroring `?? .max` on the update path) so
        // a diagnostic glitch can never wedge backups permanently.
        let plannedBytes = plans.reduce(Int64(0)) { $0 + $1.toCopy.reduce(Int64(0)) { $0 + $1.size } }
        let freeBytes = DiskSpace.availableBytes(forVolumeContaining: destination)
            .map(Int64.init) ?? .max
        if case let .blockedInsufficientSpace(need, free) =
            ArchiveSpacePlan.verdict(plannedBytes: plannedBytes, freeBytes: freeBytes) {
            throw ArchiveError.insufficientSpace(needBytes: need, freeBytes: free)
        }

        // Phase 3 — copy, then fold the per-root totals exactly as before.
        var copied = 0
        var bytes: Int64 = 0
        var totalInArchive = 0
        var totalBytesInArchive: Int64 = 0

        for plan in plans {
            for entry in plan.toCopy {
                let from = plan.sourceRoot.appendingPathComponent(entry.relativePath)
                let to = plan.destRoot.appendingPathComponent(entry.relativePath)
                do {
                    try copyReplacing(from: from, to: to)
                    copied += 1
                    bytes += entry.size
                } catch {
                    // One unreadable/locked file must not abort the whole sync — log and continue.
                    AppLogger.archive.error(
                        "archive copy failed for \(entry.relativePath, privacy: .private): \(error.localizedDescription, privacy: .public)")
                }
            }

            // Files now in the archive for this root = the union of what was already mirrored (incl.
            // pruned-in-source files) and every source file (all present after the copies above). Size
            // per file prefers the source (freshly copied, current) and falls back to the archived
            // copy for pruned-in-source files. With empty `sourceEntries` this folds to the archived
            // count/size, matching the pruned-root case exactly.
            let sourceByPath = Dictionary(plan.sourceEntries.map { ($0.relativePath, $0.size) }, uniquingKeysWith: { a, _ in a })
            var sizeByPath = Dictionary(plan.destEntries.map { ($0.relativePath, $0.size) }, uniquingKeysWith: { a, _ in a })
            sizeByPath.merge(sourceByPath) { _, source in source }
            totalInArchive += sizeByPath.count
            totalBytesInArchive += sizeByPath.values.reduce(0, +)
        }

        return Summary(
            copied: copied, bytes: bytes,
            totalInArchive: totalInArchive, totalBytesInArchive: totalBytesInArchive)
    }

    /// Count the files and total bytes already sitting in `destination` — a read-only scan of the
    /// allow-listed roots, no copying. Lets the Settings status line show the archive's size on every
    /// window open, independent of whether a sync has run in this process session (the in-memory
    /// `Summary` is lost across relaunches, but the archive on disk is not). Returns `(0, 0)` for an
    /// empty or missing destination.
    func archiveStats(at destination: URL) -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        for root in Self.sourceRoots {
            let entries = scan(destination.appendingPathComponent(root))
            files += entries.count
            bytes += entries.reduce(0) { $0 + $1.size }
        }
        return (files, bytes)
    }

    // MARK: - Tree scan

    /// Walk `root` and build one ``ArchiveEntry`` per regular file, keyed by path relative to `root`.
    /// A missing root yields an empty snapshot (the destination mirror doesn't exist on first run).
    private func scan(_ root: URL) -> [ArchiveEntry] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var entries: [ArchiveEntry] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let relative = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
            entries.append(ArchiveEntry(
                relativePath: relative,
                modified: values.contentModificationDate ?? .distantPast,
                size: Int64(values.fileSize ?? 0)))
        }
        return entries
    }

    // MARK: - Copy helpers

    /// Copy `from` to `to`, creating parent directories and replacing any existing copy **atomically**
    /// — a grown `.jsonl` overwrites the shorter mirrored version without the archive ever being left
    /// without one (#306).
    ///
    /// This used to remove the destination and then copy, which opened a window where the previously
    /// archived copy was already gone and the new one had not landed. On a full disk the copy failed
    /// exactly there, so the archive silently lost a file it was often the *last* holder of — the
    /// worst possible failure mode for an accumulate-only store that exists to outlive Claude Code's
    /// 30-day cleanup.
    ///
    /// `replaceItemAt` **moves** its `withItemAt:` argument and consumes it, so `from` — a real log
    /// under `~/.claude` — must never be passed to it directly. Hence the staging copy, which is
    /// written beside the destination so the swap is a same-volume rename rather than a cross-volume
    /// copy that could fail partway (the archive typically lives on an external disk). The staging
    /// name is dotted because ``scan(_:)`` uses `.skipsHiddenFiles`: a staging file orphaned by a
    /// crash can never be counted as an archived file nor re-copied.
    ///
    /// It costs the destination twice one file's size for the duration of the swap; that is
    /// comfortably inside the 5 GB headroom the space gate reserves against the whole run.
    private func copyReplacing(from: URL, to: URL) throws {
        let parent = to.deletingLastPathComponent()
        try ensureDirectory(parent)

        // Nothing to replace — a plain copy of a new path is already all-or-nothing.
        guard fileManager.fileExists(atPath: to.path) else {
            try fileManager.copyItem(at: from, to: to)
            return
        }

        let staged = parent.appendingPathComponent(".tokenpace-staging-\(UUID().uuidString)")
        try fileManager.copyItem(at: from, to: staged)
        do {
            // `copyItem` preserves the source's modification date and `replaceItemAt` moves that very
            // file into place, so the archived copy keeps the source mtime — which is what
            // `ArchiveSyncPlan.filesToCopy` compares against. Losing it would silently re-copy every
            // file on every run.
            _ = try fileManager.replaceItemAt(to, withItemAt: staged)
        } catch {
            try? fileManager.removeItem(at: staged)   // swap failed → don't leak the staging file
            throw error
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ArchiveError.destinationUnavailable
        }
    }
}
