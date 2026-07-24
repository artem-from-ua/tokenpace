import Foundation

// MARK: - ArchiveEntry

/// One file discovered while scanning a source (or destination) tree — the injected, testable shape
/// the shell builds from `FileManager` so ``ArchiveSyncPlan`` can decide without touching disk (#110).
///
/// `relativePath` is the path **relative to the sync root** (e.g. `projects/foo/<sid>.jsonl`), so a
/// source entry and its destination counterpart share the same key. `size` participates in the
/// change check because session `.jsonl` files are *appended to* while a session runs — a longer file
/// with an unchanged mtime (coarse-grained on some filesystems) must still re-copy.
public struct ArchiveEntry: Equatable {
    public let relativePath: String
    public let modified: Date
    public let size: Int64

    public init(relativePath: String, modified: Date, size: Int64) {
        self.relativePath = relativePath
        self.modified = modified
        self.size = size
    }
}

// MARK: - ArchiveSyncPlan

/// The heart of the log archiver (#110): given a snapshot of the source tree and the destination
/// tree, decide **which files to copy** — and, crucially, never decide to *delete*.
///
/// This is what makes the archive *accumulate-only*: a file Claude Code has already pruned from the
/// source (30-day `cleanupPeriodDays` cleanup) is simply absent from `source`, so it never appears in
/// the copy list and its destination copy is left untouched. The archive therefore outlives the
/// source and grows monotonically. There is no `--delete` equivalent, by construction.
///
/// A source file is (re)copied when it is **new** (no destination counterpart) or **changed** — the
/// source is newer by mtime **or** differs in size (an appended-to `.jsonl` grows without necessarily
/// bumping a coarse mtime). Pure and deterministic: the shell injects the two tree snapshots and
/// performs the resulting copies. Lives in `TokenPaceKit` precisely so this decision is unit-tested.
public enum ArchiveSyncPlan {
    /// The subset of `source` that must be copied into the destination. Order follows `source`.
    ///
    /// - Parameters:
    ///   - source: Every file currently under the sync roots in `~/.claude/…`.
    ///   - dest: Every file currently mirrored in the archive folder, keyed by the same
    ///     `relativePath`.
    public static func filesToCopy(source: [ArchiveEntry], dest: [ArchiveEntry]) -> [ArchiveEntry] {
        let mirrored = Dictionary(dest.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        return source.filter { entry in
            guard let existing = mirrored[entry.relativePath] else { return true }  // new → copy
            // Changed → copy. mtime OR size: an appended `.jsonl` grows even if mtime is coarse.
            return entry.modified > existing.modified || entry.size != existing.size
        }
    }
}
