import Testing
import Foundation
@testable import TokenPaceKit

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func entry(_ path: String, mtime: TimeInterval = 0, size: Int64 = 100) -> ArchiveEntry {
    ArchiveEntry(relativePath: path, modified: t0.addingTimeInterval(mtime), size: size)
}

@Suite("ArchiveSyncPlan.filesToCopy")
struct ArchiveSyncPlanTests {

    @Test func newFileIsCopied() {
        let plan = ArchiveSyncPlan.filesToCopy(
            source: [entry("projects/a/s.jsonl")],
            dest: [])
        #expect(plan.map(\.relativePath) == ["projects/a/s.jsonl"])
    }

    @Test func unchangedFileIsSkipped() {
        let same = entry("projects/a/s.jsonl", mtime: 10, size: 500)
        let plan = ArchiveSyncPlan.filesToCopy(source: [same], dest: [same])
        #expect(plan.isEmpty)
    }

    @Test func newerFileIsCopied() {
        let plan = ArchiveSyncPlan.filesToCopy(
            source: [entry("projects/a/s.jsonl", mtime: 20, size: 500)],
            dest: [entry("projects/a/s.jsonl", mtime: 10, size: 500)])
        #expect(plan.count == 1)
    }

    @Test func appendedFileIsCopiedEvenWithSameMtime() {
        // A session `.jsonl` that grew but whose mtime didn't advance (coarse fs) must still re-copy.
        let plan = ArchiveSyncPlan.filesToCopy(
            source: [entry("projects/a/s.jsonl", mtime: 10, size: 900)],
            dest: [entry("projects/a/s.jsonl", mtime: 10, size: 500)])
        #expect(plan.count == 1)
    }

    @Test func fileDeletedInSourceIsNotInPlan() {
        // Claude Code pruned it (30-day cleanup): absent from source → never copied, never deleted.
        // The plan only ever contains copies, so the destination copy simply survives untouched.
        let plan = ArchiveSyncPlan.filesToCopy(
            source: [],
            dest: [entry("projects/a/old.jsonl")])
        #expect(plan.isEmpty)
    }

    @Test func emptyTreesProduceEmptyPlan() {
        #expect(ArchiveSyncPlan.filesToCopy(source: [], dest: []).isEmpty)
    }

    @Test func mixedTreeCopiesOnlyNewAndChanged() {
        let source = [
            entry("projects/a/new.jsonl", mtime: 5, size: 100),      // new
            entry("projects/a/same.jsonl", mtime: 5, size: 100),     // unchanged
            entry("file-history/x/f@v2", mtime: 9, size: 300),       // grew
        ]
        let dest = [
            entry("projects/a/same.jsonl", mtime: 5, size: 100),
            entry("file-history/x/f@v2", mtime: 9, size: 200),
            entry("projects/a/pruned.jsonl", mtime: 1, size: 50),    // gone from source
        ]
        let plan = ArchiveSyncPlan.filesToCopy(source: source, dest: dest)
        #expect(Set(plan.map(\.relativePath)) == ["projects/a/new.jsonl", "file-history/x/f@v2"])
    }
}
