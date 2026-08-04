import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - JournalReader

@Suite("JournalReader")
struct JournalReaderTests {

    private let validLine = #"{"kind":"resume","t":"2026-08-03T13:40:00Z","gap":900}"#

    @Test func parsesEveryLine() {
        let contents = [validLine, validLine, validLine].joined(separator: "\n")
        let result = JournalReader.parse(contents)
        #expect(result.records.count == 3)
        #expect(result.skipped == 0)
    }

    @Test func skipsCorruptTailNotWholeFile() {
        // Two good lines, then a torn last line (a crash mid-append) → 2 records, 1 skip.
        let contents = validLine + "\n" + validLine + "\n" + #"{"kind":"usage","t":"partial"#
        let result = JournalReader.parse(contents)
        #expect(result.records.count == 2)
        #expect(result.skipped == 1)
    }

    @Test func ignoresBlankLinesAndTrailingNewline() {
        let contents = validLine + "\n\n" + validLine + "\n"
        let result = JournalReader.parse(contents)
        #expect(result.records.count == 2)
        #expect(result.skipped == 0)
    }

    @Test func unknownKindIsRecordNotSkip() {
        // A forward-compatible line (unknown kind) is preserved as `.unknown`, not counted as a skip.
        let contents = validLine + "\n" + #"{"kind":"future","x":1}"#
        let result = JournalReader.parse(contents)
        #expect(result.records.count == 2)
        #expect(result.skipped == 0)
        #expect(result.records.last == .unknown)
    }

    @Test func emptyContentsYieldsNothing() {
        let result = JournalReader.parse("")
        #expect(result.records.isEmpty)
        #expect(result.skipped == 0)
    }
}

// MARK: - JournalGap

@Suite("JournalGap resume markers")
struct JournalGapTests {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func noPreviousYieldsNoMarker() {
        #expect(JournalGap.marker(previous: nil, now: base, expectedInterval: 180) == nil)
    }

    @Test func withinCadenceYieldsNoMarker() {
        // One skipped tick (≤ 2×) is normal — no marker.
        let now = base.addingTimeInterval(300)   // 1.67× of 180
        #expect(JournalGap.marker(previous: base, now: now, expectedInterval: 180) == nil)
    }

    @Test func beyondThresholdYieldsMarker() {
        let now = base.addingTimeInterval(900)   // 5× of 180 → gap
        let marker = JournalGap.marker(previous: base, now: now, expectedInterval: 180)
        #expect(marker != nil)
        #expect(marker?.gap == 900)
    }

    @Test func exactlyAtThresholdYieldsNoMarker() {
        // Strictly greater than 2× — exactly 2× is not yet a gap.
        let now = base.addingTimeInterval(360)   // exactly 2× of 180
        #expect(JournalGap.marker(previous: base, now: now, expectedInterval: 180) == nil)
    }

    @Test func zeroIntervalIsSafe() {
        #expect(JournalGap.marker(previous: base, now: base.addingTimeInterval(1000), expectedInterval: 0) == nil)
    }
}
