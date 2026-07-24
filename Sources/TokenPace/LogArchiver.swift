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
        let copied: Int
        let bytes: Int64
    }

    enum ArchiveError: Error {
        /// The destination is unset, unwritable, or could not be created.
        case destinationUnavailable
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

    /// Mirror the allow-listed roots into `destination`, copying only new/changed files and never
    /// deleting. Returns how much was copied. Throws ``ArchiveError/destinationUnavailable`` if the
    /// destination cannot be prepared.
    func sync(to destination: URL) throws -> Summary {
        try ensureDirectory(destination)

        var copied = 0
        var bytes: Int64 = 0

        for root in Self.sourceRoots {
            let sourceRoot = claudeHome.appendingPathComponent(root)
            guard fileManager.fileExists(atPath: sourceRoot.path) else { continue }
            let destRoot = destination.appendingPathComponent(root)

            let sourceEntries = scan(sourceRoot)
            let destEntries = scan(destRoot)
            let toCopy = ArchiveSyncPlan.filesToCopy(source: sourceEntries, dest: destEntries)

            AppLogger.archive.debug(
                "archive root \(root, privacy: .public): \(sourceEntries.count, privacy: .public) source files, \(toCopy.count, privacy: .public) to copy")

            for entry in toCopy {
                let from = sourceRoot.appendingPathComponent(entry.relativePath)
                let to = destRoot.appendingPathComponent(entry.relativePath)
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
        }

        return Summary(copied: copied, bytes: bytes)
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

    /// Copy `from` to `to`, creating parent directories and atomically replacing any existing copy
    /// (a grown `.jsonl` overwrites the shorter mirrored version).
    private func copyReplacing(from: URL, to: URL) throws {
        try ensureDirectory(to.deletingLastPathComponent())
        if fileManager.fileExists(atPath: to.path) {
            try fileManager.removeItem(at: to)
        }
        try fileManager.copyItem(at: from, to: to)
    }

    private func ensureDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ArchiveError.destinationUnavailable
        }
    }
}
