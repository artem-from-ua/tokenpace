import Foundation

// MARK: - ArchiveSpaceVerdict

/// Whether one archive sync may write, given how much it intends to copy and how much room the
/// destination volume has left (#306) — the pure counterpart to ``ArchiveSyncPlan/filesToCopy(source:dest:)``:
/// that one decides *what* to copy, this one decides *whether to copy at all*.
///
/// Unlike the update installer's `deferOnBattery` — a condition that fixes itself the moment the
/// adapter goes back in — a full disk stays full until the user acts. So this is a **block**, not a
/// defer: the run refuses, the `lastArchiveSync` marker stays put, and the Settings pane says why.
///
/// The blocking case carries both figures so the shell can log precise diagnostics without
/// re-reading the volume, and so the UI never has to re-derive them.
public enum ArchiveSpaceVerdict: Sendable, Equatable {
    /// Enough headroom — copy away.
    case proceed
    /// Copying `needBytes` onto a volume holding `freeBytes` would leave less than
    /// ``ArchiveSpacePlan/minFreeBytesAfterCopy`` free.
    case blockedInsufficientSpace(needBytes: Int64, freeBytes: Int64)
}

// MARK: - ArchiveSpacePlan

/// The pure "may this archive sync write?" decision (#306) — no clock, no I/O, unit-tested with
/// literals (ADR-0009). The shell (`LogArchiver`) scans the trees, sums the planned bytes, reads the
/// volume, and asks here; it never re-derives the arithmetic.
///
/// **Only the free-space gate lives here.** The sibling battery gate is deliberately *not* modelled:
/// the two run at different times (battery before the scan, on the daily-heartbeat path only; space
/// after the scan, on every path) and have different bypass rules (a manual "Archive Now" skips the
/// battery gate but never this one). Folding both into one `decide` would force every call site to
/// pass a fabricated value for the gate it isn't evaluating — the `onACPower: true` lie
/// ``UpdateInstallPlan`` has to document at length for forced installs. The battery gate is one
/// `guard` with no arithmetic, so there is nothing in it to unit-test.
///
/// The threshold matches ``UpdateInstallPlan/minFreeBytesAfterDownload`` on purpose: one promise
/// ("TokenPace never runs your disk to the brink") is easier to explain than two different numbers.
public enum ArchiveSpacePlan {

    /// The free space that must remain **after** the copy: 5 GB, the same headroom auto-install
    /// reserves (``UpdateInstallPlan/minFreeBytesAfterDownload``). Decimal, matching Finder.
    public static let minFreeBytesAfterCopy: Int64 = 5 * 1_000_000_000

    /// Decide whether a sync that would write `plannedBytes` may run.
    ///
    /// - Parameters:
    ///   - plannedBytes: Total size of the files the sync intends to copy — the sum of
    ///     ``ArchiveEntry/size`` across **every** root's copy list, not one root's. A per-root check
    ///     could pass twice and then refuse on the third root, leaving the archive half-updated.
    ///   - freeBytes: Free space on the volume holding the archive. Callers pass `Int64.max` when the
    ///     figure is unreadable — fail-open, mirroring `?? .max` on the update path: a diagnostic
    ///     glitch must never permanently wedge backups.
    public static func verdict(plannedBytes: Int64, freeBytes: Int64) -> ArchiveSpaceVerdict {
        // Nothing to copy can never fill a disk. Without this, the daily heartbeat over an archive
        // that is already up to date would raise a scary warning about a copy that isn't happening.
        guard plannedBytes > 0 else { return .proceed }
        guard freeBytes - plannedBytes >= minFreeBytesAfterCopy else {
            return .blockedInsufficientSpace(needBytes: plannedBytes, freeBytes: freeBytes)
        }
        return .proceed
    }

    /// The warning sentence for a blocked sync, or `nil` when nothing blocks.
    ///
    /// The wording lives in the kit rather than the view for the same reason
    /// ``UpdateDeferralReason/clause`` does (ADR-0009): the kit names the condition, the view decides
    /// how to draw it (here: a ⚠️ hint under the Sessions-backup status line).
    ///
    /// **Deliberately free of measured figures.** Naming "needs 12 GB, only 3 GB free" invites the
    /// user to check Finder and find different numbers: ``ByteSize/humanReadable(_:)`` is binary
    /// (1 KB = 1024 B) while this threshold is decimal, and the free figure counts purgeable space.
    /// The exact bytes go to the log, where they are diagnostics; the hint states only the constant.
    public static func blockedExplanation(for verdict: ArchiveSpaceVerdict) -> String? {
        switch verdict {
        case .proceed:
            return nil
        case .blockedInsufficientSpace:
            return "Backup paused — not enough free space on the destination disk. TokenPace keeps "
                 + "5 GB free; free up space and the backup resumes by itself."
        }
    }
}
