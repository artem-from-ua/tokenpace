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
        /// `lastArchiveSync` marker on `.success`, so a blocked run stays due and retries by itself —
        /// a `Summary` field would land in the success branch and record the failure as a success.
        case insufficientSpace(needBytes: Int64, freeBytes: Int64)
    }

    private let claudeHome: URL
    private let fileManager: FileManager

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
    /// deleting.
    ///
    /// Runs in three phases (#306): scan is separated from copying so the space gate judges the
    /// **whole run** rather than whichever root it happens to reach first — gating per root could
    /// copy two roots and then refuse the third, leaving the archive half-updated. Nothing is written
    /// before the gate has passed.
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

        // Phase 2 — the free-space gate, once, against the combined plan. Read here rather than
        // injected from the main actor: `volumeAvailableCapacityForImportantUsage` can block while an
        // external disk spins up. An unreadable volume reads as `.max` (fail-open), so a diagnostic
        // glitch can never wedge backups permanently.
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

            // Files now in the archive = union of what was already mirrored (incl. pruned-in-source
            // files) and every source file. Size per file prefers the source (fresh) and falls back
            // to the archived copy for pruned-in-source files.
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

    /// A read-only scan, no copying — lets the Settings status line show the archive's size on every
    /// window open, independent of whether a sync has run this process session.
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

    /// Copy `from` to `to`, replacing any existing copy **atomically** — a grown `.jsonl` overwrites
    /// the shorter mirrored version without the archive ever being left without one (#306): a
    /// remove-then-copy would leave the archive without a copy if the write failed partway on a full
    /// disk, the worst failure mode for an accumulate-only store.
    ///
    /// `replaceItemAt` **moves** its `withItemAt:` argument, so `from` — a real log under `~/.claude`
    /// — must never be passed to it directly; hence the staging copy, written beside the destination
    /// so the swap is a same-volume rename. The staging name is dotted because ``scan(_:)`` uses
    /// `.skipsHiddenFiles`: a staging file orphaned by a crash can never be counted or re-copied.
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
            // `copyItem` preserves the source's modification date, so the archived copy keeps the
            // source mtime — what `ArchiveSyncPlan.filesToCopy` compares against. Losing it would
            // silently re-copy every file on every run.
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
