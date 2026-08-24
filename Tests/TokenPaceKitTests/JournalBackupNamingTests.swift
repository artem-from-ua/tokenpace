import Foundation
import Testing
@testable import TokenPaceKit

/// The naming and delete/keep decision behind `UsageJournal.swapIn` (#509).
///
/// The bug this pins down: a taken `.v<n>.bak` name was read as "the evidence is already safe" and
/// the live journal was deleted. It is safe only when the bytes match — the journal is append-only
/// and polls every three minutes, so a backup taken two days earlier never holds the current bytes.
@Suite struct JournalBackupNamingTests {

    private static let noon = Date(timeIntervalSince1970: 1_787_538_677)   // 2026-08-24T02:31:17Z

    @Test func plainSuffixNamesTheGenerationItHolds() {
        #expect(JournalBackupNaming.suffix(forVersion: 4) == ".v4.bak")
        #expect(JournalBackupNaming.suffix(forVersion: 1) == ".v1.bak")
    }

    @Test func timestampedSuffixKeepsTheGenerationAndSortsByTime() {
        let s = JournalBackupNaming.suffix(forVersion: 4, takenAt: Self.noon)
        #expect(s == ".v4.20260824T023117Z.bak")

        // Lexicographic order matches chronological order — what makes an `ls` readable.
        let later = JournalBackupNaming.suffix(forVersion: 4, takenAt: Self.noon.addingTimeInterval(3600))
        #expect(s < later)
    }

    @Test func bothShapesAreRecognizedAsBackups() {
        #expect(JournalBackupNaming.isBackup(fileName: "usage-journal-2026-08.jsonl.v4.bak"))
        #expect(JournalBackupNaming.isBackup(fileName: "usage-journal-2026-08.jsonl.v4.20260824T023117Z.bak"))
        #expect(!JournalBackupNaming.isBackup(fileName: "usage-journal-2026-08.jsonl"))
        #expect(!JournalBackupNaming.isBackup(fileName: "usage-journal-2026-08.jsonl.migrating"))
    }

    /// Case 1: nothing in the way — today's behaviour, the plain name.
    @Test func freeNameTakesThePlainSuffix() {
        let d = JournalBackupNaming.disposition(forVersion: 4, existingMatchesLive: nil, now: Self.noon)
        #expect(d == .moveAside(suffix: ".v4.bak"))
    }

    /// Case 2: the existing backup already holds these exact bytes, so deleting loses nothing —
    /// this is the one path that may delete, and #401's "never overwrite a backup" still holds.
    @Test func identicalBackupMakesDeletingANoOp() {
        let d = JournalBackupNaming.disposition(forVersion: 4, existingMatchesLive: true, now: Self.noon)
        #expect(d == .deleteAlreadyBackedUp)
    }

    /// Case 3: the regression itself. Different bytes under the taken name means two distinct
    /// generations of evidence, and neither may be lost.
    @Test func differingBackupNeverDeletesTheLiveFile() {
        let d = JournalBackupNaming.disposition(forVersion: 4, existingMatchesLive: false, now: Self.noon)
        #expect(d == .moveAside(suffix: ".v4.20260824T023117Z.bak"))
        #expect(d != .deleteAlreadyBackedUp)
    }

    /// The collision is structural: `wasVersion` comes from the oldest *usage* line, so the next
    /// migration asks for `.v5.bak` and meets the same taken name.
    @Test func theNextGenerationCollidesTheSameWay() {
        let d = JournalBackupNaming.disposition(forVersion: 5, existingMatchesLive: false, now: Self.noon)
        #expect(d == .moveAside(suffix: ".v5.20260824T023117Z.bak"))
    }
}
