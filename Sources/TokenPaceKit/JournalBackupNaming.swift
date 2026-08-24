import Foundation

// MARK: - JournalBackupNaming

/// Where a pre-migration journal is put aside, and what to do when that name is already taken.
///
/// The invariant this exists to hold: **the live journal is never deleted unless its exact current
/// bytes are already stored somewhere.** The shell (`UsageJournal.swapIn`) does the I/O; the
/// decision — which name, and whether deleting is safe — is here so it can be tested.
///
/// The collision it handles is structural, not bad luck. A backup is named after `wasVersion`, which
/// comes from ``JournalMigration/Outcome/migratedFromVersion`` — set only from **usage** lines. Every
/// archive whose oldest usage line is v4 therefore produces `.v4.bak`, so a v4 → v5 pass collides
/// with any earlier v4-generation backup by construction, and the next migration will collide the
/// same way on `.v5.bak`. Treat a taken name as expected, never as a surprise.
public enum JournalBackupNaming {

    /// The suffix a pre-migration copy keeps, named after the format version the copy **contains**
    /// (`.v2.bak` for a file that was v2). Versioned per generation: a fixed name would let a second
    /// migration overwrite the first one's backup and lose the middle generation.
    public static func suffix(forVersion version: Int) -> String { ".v\(version).bak" }

    /// A second-generation suffix for when ``suffix(forVersion:)`` is taken by *different* bytes:
    /// `.v4.20260824T023117Z.bak`.
    ///
    /// The timestamp is UTC basic-ISO, so the names sort lexicographically in the order they were
    /// written, and it keeps the `.v<n>.` prefix so a reader can still see which generation the copy
    /// belongs to. `.bak` stays last, which is what ``isBackup(fileName:)`` matches on.
    public static func suffix(forVersion version: Int, takenAt instant: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
        let stamp = String(format: "%04d%02d%02dT%02d%02d%02dZ",
                           c.year ?? 0, c.month ?? 0, c.day ?? 0,
                           c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return ".v\(version).\(stamp).bak"
    }

    /// Whether a name is one of ours — either shape. Anchored, so it matches the end of a journal
    /// file name rather than anything containing `.bak`.
    public static func isBackup(fileName: String) -> Bool {
        fileName.range(of: #"\.v\d+(\.\d{8}T\d{6}Z)?\.bak$"#, options: .regularExpression) != nil
    }

    /// What the shell should do with the live file once the migrated copy is staged.
    public enum Disposition: Equatable, Sendable {
        /// Rename the live file to this suffix. Nothing is overwritten.
        case moveAside(suffix: String)
        /// Delete the live file: an existing backup already holds these exact bytes, so no evidence
        /// is lost. This is the only path that deletes, and it is only reachable after a
        /// byte-for-byte match.
        case deleteAlreadyBackedUp
    }

    /// Decide where the live file goes, given whether the primary backup name is taken and — when it
    /// is — whether it holds the same bytes.
    ///
    /// `existingMatchesLive` is `nil` when the primary name is free, so the caller never has to
    /// compare a file that is not there. Passing `false` means the existing backup is a *different*
    /// generation of evidence and must survive untouched, so the live file takes a timestamped name.
    public static func disposition(forVersion version: Int,
                                   existingMatchesLive: Bool?,
                                   now: Date) -> Disposition {
        switch existingMatchesLive {
        case nil:    return .moveAside(suffix: suffix(forVersion: version))
        case true?:  return .deleteAlreadyBackedUp
        case false?: return .moveAside(suffix: suffix(forVersion: version, takenAt: now))
        }
    }
}
