import Testing
import Foundation
@testable import TokenPaceKit

/// Covers the archiver's free-space gate (#306). Until this existed the only way to exercise a full
/// disk was to actually fill one, so the failure mode shipped untested: every per-file copy failed,
/// `sync` still returned normally, and the shell recorded the run as a success.
@Suite("ArchiveSpacePlan.verdict")
struct ArchiveSpacePlanTests {

    /// Ample free space (100 GB) — the default, so a test overrides only the gate it exercises.
    private let ampleSpace: Int64 = 100 * 1_000_000_000

    /// 6 GB free: on its own that clears the 5 GB floor, but not once `typicalPlan` is written.
    private let crampedSpace: Int64 = 6 * 1_000_000_000

    /// A 2 GB copy — realistic for a first sync of a long-lived `~/.claude` tree.
    private let typicalPlan: Int64 = 2 * 1_000_000_000

    /// A verdict with favourable defaults, so each test overrides exactly what it exercises.
    private func verdict(planned: Int64 = 1_000_000, free: Int64? = nil) -> ArchiveSpaceVerdict {
        ArchiveSpacePlan.verdict(plannedBytes: planned, freeBytes: free ?? ampleSpace)
    }

    // MARK: nothing blocking

    @Test("Ample space → proceed")
    func ampleProceeds() {
        #expect(verdict() == .proceed)
    }

    // MARK: the gate closes

    @Test("Copy would eat into the 5 GB floor → blocked, carrying both figures")
    func crampedBlocks() {
        #expect(verdict(planned: typicalPlan, free: crampedSpace)
            == .blockedInsufficientSpace(needBytes: typicalPlan, freeBytes: crampedSpace))
    }

    @Test("A plan larger than the whole volume → blocked, not negative arithmetic")
    func planLargerThanVolume() {
        #expect(verdict(planned: 10 * 1_000_000_000, free: 1_000_000_000)
            == .blockedInsufficientSpace(needBytes: 10 * 1_000_000_000, freeBytes: 1_000_000_000))
    }

    // MARK: the boundary, from both sides

    @Test("Exactly the floor plus the plan → fits")
    func boundaryFits() {
        let exact = ArchiveSpacePlan.minFreeBytesAfterCopy + typicalPlan
        #expect(verdict(planned: typicalPlan, free: exact) == .proceed)
    }

    @Test("One byte under the floor → blocked")
    func boundaryBlocks() {
        let exact = ArchiveSpacePlan.minFreeBytesAfterCopy + typicalPlan
        #expect(verdict(planned: typicalPlan, free: exact - 1)
            == .blockedInsufficientSpace(needBytes: typicalPlan, freeBytes: exact - 1))
    }

    // MARK: an empty plan is always safe

    /// The daily heartbeat over an up-to-date archive plans zero bytes. Blocking that would raise a
    /// warning about a copy that isn't happening — and it would fire every heartbeat, forever.
    @Test("Nothing to copy on a full disk → proceed")
    func emptyPlanOnFullDisk() {
        #expect(verdict(planned: 0, free: 0) == .proceed)
    }

    @Test("Zero-byte plan never blocks, whatever the volume says")
    func zeroPlanNeverBlocks() {
        #expect(verdict(planned: 0, free: 1) == .proceed)
    }

    // MARK: fail-open

    /// An unreadable volume yields `Int64.max` at the call site, mirroring `?? .max` on the update
    /// path. A diagnostic glitch must not wedge backups permanently — and the subtraction must not
    /// trap on the way through.
    @Test("Unreadable volume (.max) → proceed, no overflow")
    func failOpen() {
        #expect(verdict(planned: 500 * 1_000_000_000, free: .max) == .proceed)
    }

    // MARK: parity with the update gate

    /// The maintainer's decision in #306: one threshold, not two. Pinned so a future divergence has
    /// to be deliberate rather than accidental drift between two constants that look alike.
    @Test("Threshold matches the auto-install headroom")
    func thresholdParity() {
        #expect(ArchiveSpacePlan.minFreeBytesAfterCopy
            == Int64(UpdateInstallPlan.minFreeBytesAfterDownload))
    }
}

// MARK: - blockedExplanation

@Suite("ArchiveSpacePlan.blockedExplanation")
struct ArchiveBlockedExplanationTests {

    @Test("Proceeding → nil (nothing to explain)")
    func proceedExplainsNothing() {
        #expect(ArchiveSpacePlan.blockedExplanation(for: .proceed) == nil)
    }

    @Test("Blocked → the warning sentence, verbatim")
    func blockedSentence() {
        #expect(ArchiveSpacePlan.blockedExplanation(
            for: .blockedInsufficientSpace(needBytes: 12_000_000_000, freeBytes: 3_000_000_000))
            == "Backup paused — not enough free space on the destination disk. TokenPace keeps "
             + "5 GB free; free up space and the backup resumes by itself.")
    }

    /// The sentence quotes the threshold, so it must not drift from the constant it describes.
    @Test("The quoted figure matches the constant")
    func quotedFigureMatchesConstant() {
        let text = ArchiveSpacePlan.blockedExplanation(
            for: .blockedInsufficientSpace(needBytes: 1, freeBytes: 1)) ?? ""
        let gigabytes = ArchiveSpacePlan.minFreeBytesAfterCopy / 1_000_000_000
        #expect(text.contains("\(gigabytes) GB free"))
    }

    /// Measured figures belong in the log, not the hint — Finder would show different numbers
    /// (binary vs decimal units, purgeable space). Guards against a well-meaning future edit.
    @Test("The hint states no measured figures")
    func noMeasuredFigures() {
        let text = ArchiveSpacePlan.blockedExplanation(
            for: .blockedInsufficientSpace(needBytes: 12_000_000_000, freeBytes: 3_000_000_000)) ?? ""
        #expect(!text.contains("12"))
        #expect(!text.contains("3 GB"))
    }
}
