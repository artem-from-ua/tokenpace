import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - UsageGridAggregator

@Suite("UsageGridAggregator")
struct UsageGridTests {

    // Fixed zone so cell boundaries are deterministic (mirrors CreditsMonthFractionTests).
    private static let kyiv = TimeZone(identifier: "Europe/Kyiv")!   // +02:00 / +03:00 (DST)
    private static let utc = TimeZone(identifier: "UTC")!

    /// Row index of a Foundation weekday number in a Monday-first grid (`2 = Mon` → `0`).
    private static func mondayFirstRow(_ weekday: Int) -> Int { (weekday + 5) % 7 }

    /// Build an instant from wall-clock components in a given zone.
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0,
                      zone: TimeZone = UsageGridTests.utc) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    /// A minimal `.usage` record at `t` — only the fields the aggregator reads matter; the windows are
    /// placeholders (the density metric ignores them).
    private func usage(at t: Date, zone: TimeZone = UsageGridTests.utc) -> JournalRecord {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = zone
        let win = WindowSample(util: 0, reset: "", timePct: 0, gap: 0, sev: .green)
        return .usage(UsageSample(
            t: iso.string(from: t), h5: win, d7: win,
            credits: CreditsFlags(active: false, showIcon: false, onCredits: false)))
    }

    private func resume(at t: Date, gap: TimeInterval, zone: TimeZone = UsageGridTests.utc) -> JournalRecord {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = zone
        return .resume(ResumeMarker(t: iso.string(from: t), gap: gap))
    }

    // MARK: - Shape

    @Test func gridHasSevenRowsAndTwentyFourColumns() {
        // 2026-08-03 is a Monday.
        let grid = UsageGridAggregator.weekHourGrid(
            from: [usage(at: date(2026, 8, 3, 10))], filter: .fiveHour, timeZone: Self.utc)
        #expect(grid.cells.count == 7)
        #expect(grid.cells.allSatisfy { $0.count == 24 })
        #expect(grid.weekdays.count == 7)
    }

    @Test func rowsStartAtTheRequestedFirstWeekday() {
        let records = [usage(at: date(2026, 8, 3, 10))]
        // Monday-first (default): 2,3,4,5,6,7,1.
        let monday = UsageGridAggregator.weekHourGrid(from: records, filter: .fiveHour, timeZone: Self.utc)
        #expect(monday.weekdays == [2, 3, 4, 5, 6, 7, 1])
        // Sunday-first (the #251 locale case): 1,2,3,4,5,6,7.
        let sunday = UsageGridAggregator.weekHourGrid(
            from: records, filter: .fiveHour, firstWeekday: 1, timeZone: Self.utc)
        #expect(sunday.weekdays == [1, 2, 3, 4, 5, 6, 7])
    }

    @Test func outOfRangeFirstWeekdayFallsBackToMonday() {
        let records = [usage(at: date(2026, 8, 3, 10))]
        let grid = UsageGridAggregator.weekHourGrid(
            from: records, filter: .fiveHour, firstWeekday: 99, timeZone: Self.utc)
        #expect(grid.weekdays == [2, 3, 4, 5, 6, 7, 1])
    }

    @Test func emptyRecordsYieldAnAllGapGrid() {
        let grid = UsageGridAggregator.weekHourGrid(from: [], filter: .fiveHour, timeZone: Self.utc)
        #expect(grid.cells.flatMap { $0 }.allSatisfy { $0 == .gap })
        #expect(grid.maxObservedValue == nil)
    }

    // MARK: - Bucketing

    @Test func samplesLandInTheCorrectWeekdayAndHour() {
        // Monday 2026-08-03 at 10:xx — three samples in the same slot.
        let records = [
            usage(at: date(2026, 8, 3, 10, 5)),
            usage(at: date(2026, 8, 3, 10, 25)),
            usage(at: date(2026, 8, 3, 10, 45)),
        ]
        let grid = UsageGridAggregator.weekHourGrid(from: records, filter: .fiveHour, timeZone: Self.utc)
        // The span is a single hour, so that slot was observed once: mean = 3 samples.
        #expect(grid.cells[Self.mondayFirstRow(2)][10] == .value(3))
    }

    @Test func allMondaysFoldIntoOneRow() {
        // Two consecutive Mondays at 09:xx — 2 samples the first week, 4 the second.
        var records = [usage(at: date(2026, 8, 3, 9, 0)), usage(at: date(2026, 8, 3, 9, 30))]
        for minute in [0, 15, 30, 45] {
            records.append(usage(at: date(2026, 8, 10, 9, minute)))
        }
        let grid = UsageGridAggregator.weekHourGrid(from: records, filter: .fiveHour, timeZone: Self.utc)
        // Both Mondays land in the same row; the span covers each Monday 09:00 once, so mean = 6/2 = 3.
        #expect(grid.cells[Self.mondayFirstRow(2)][9] == .value(3))
    }

    @Test func meanNormalisesRowsWithDifferentOccurrenceCounts() {
        // Monday appears twice in the span with 2 samples each; Tuesday appears twice with 4 each.
        var records: [JournalRecord] = []
        for day in [3, 10] {                                  // Mondays
            records += [usage(at: date(2026, 8, day, 8, 0)), usage(at: date(2026, 8, day, 8, 30))]
        }
        for day in [4, 11] {                                  // Tuesdays
            for minute in [0, 15, 30, 45] { records.append(usage(at: date(2026, 8, day, 8, minute))) }
        }
        let grid = UsageGridAggregator.weekHourGrid(from: records, filter: .fiveHour, timeZone: Self.utc)
        #expect(grid.cells[Self.mondayFirstRow(2)][8] == .value(2))   // mean per Monday
        #expect(grid.cells[Self.mondayFirstRow(3)][8] == .value(4))   // mean per Tuesday
    }

    @Test func samplesUseInjectedZoneForBucketing() {
        // 2026-08-03 23:30 UTC is Tuesday 02:30 in Kyiv (+03:00 in August) — a different row *and* hour.
        let record = usage(at: date(2026, 8, 3, 23, 30))
        let utcGrid = UsageGridAggregator.weekHourGrid(from: [record], filter: .fiveHour, timeZone: Self.utc)
        let kyivGrid = UsageGridAggregator.weekHourGrid(from: [record], filter: .fiveHour, timeZone: Self.kyiv)
        #expect(utcGrid.cells[Self.mondayFirstRow(2)][23] == .value(1))   // Monday 23:00 UTC
        #expect(kyivGrid.cells[Self.mondayFirstRow(3)][2] == .value(1))   // Tuesday 02:00 Kyiv
    }

    @Test func filterDoesNotChangeSampleDensity() {
        let records = [usage(at: date(2026, 8, 3, 10)), usage(at: date(2026, 8, 3, 10, 30))]
        let five = UsageGridAggregator.weekHourGrid(from: records, filter: .fiveHour, timeZone: Self.utc)
        let seven = UsageGridAggregator.weekHourGrid(from: records, filter: .sevenDay, timeZone: Self.utc)
        #expect(five.cells == seven.cells)
        #expect(five.filter == .fiveHour)
        #expect(seven.filter == .sevenDay)
    }

    // MARK: - Gap vs zero

    @Test func neverObservedSlotIsGapNotZero() {
        // A single sample on Monday 10:00 — every other slot was never observed.
        let grid = UsageGridAggregator.weekHourGrid(
            from: [usage(at: date(2026, 8, 3, 10))], filter: .fiveHour, timeZone: Self.utc)
        #expect(grid.cells[Self.mondayFirstRow(2)][10] == .value(1))
        #expect(grid.cells[Self.mondayFirstRow(4)][3] == .gap)   // a Wednesday hour never in the span
    }

    @Test func observedButEmptyHourIsZeroNotGap() {
        // Span runs Monday 08:00 → 11:xx with samples only at the ends; 09:00 and 10:00 were watched.
        let records = [usage(at: date(2026, 8, 3, 8, 0)), usage(at: date(2026, 8, 3, 11, 0))]
        let grid = UsageGridAggregator.weekHourGrid(from: records, filter: .fiveHour, timeZone: Self.utc)
        #expect(grid.cells[Self.mondayFirstRow(2)][9] == .value(0))
        #expect(grid.cells[Self.mondayFirstRow(2)][10] == .value(0))
    }

    @Test func slotObservedOnlyInsideAGapStaysGap() {
        // Monday 08:00 sample, then a resume at 12:00 declaring a 3 h gap (09:00–12:00 unobserved).
        let records = [
            usage(at: date(2026, 8, 3, 8, 0)),
            resume(at: date(2026, 8, 3, 12, 0), gap: 3 * 3600),
        ]
        let grid = UsageGridAggregator.weekHourGrid(from: records, filter: .fiveHour, timeZone: Self.utc)
        let row = Self.mondayFirstRow(2)
        #expect(grid.cells[row][8] == .value(1))   // observed
        #expect(grid.cells[row][10] == .gap)       // inside the gap, never observed in any week
    }

    @Test func anotherWeekObservingTheSlotOverridesAGap() {
        // Week 1: Monday 10:00 is inside a gap. Week 2: the same slot is observed with a sample.
        let records = [
            usage(at: date(2026, 8, 3, 8, 0)),
            resume(at: date(2026, 8, 3, 12, 0), gap: 3 * 3600),   // covers Mon 09:00–12:00
            usage(at: date(2026, 8, 10, 10, 30)),                 // next Monday, same 10:00 slot
        ]
        let grid = UsageGridAggregator.weekHourGrid(from: records, filter: .fiveHour, timeZone: Self.utc)
        // Observed once (week 2) with 1 sample → a real value, not a hole: only one of the two weeks
        // was blind, so the honest answer is the mean over the week we did watch.
        #expect(grid.cells[Self.mondayFirstRow(2)][10] == .value(1))
    }

    @Test func gapCrossingMidnightMarksBothWeekdays() {
        // Gap from Monday 23:00 to Tuesday 02:00, with observed samples on either side.
        let records = [
            usage(at: date(2026, 8, 3, 22, 0)),
            resume(at: date(2026, 8, 4, 2, 0), gap: 3 * 3600),
            usage(at: date(2026, 8, 4, 3, 0)),
        ]
        let grid = UsageGridAggregator.weekHourGrid(from: records, filter: .fiveHour, timeZone: Self.utc)
        #expect(grid.cells[Self.mondayFirstRow(2)][23] == .gap)   // Monday side
        #expect(grid.cells[Self.mondayFirstRow(3)][0] == .gap)    // Tuesday side
        #expect(grid.cells[Self.mondayFirstRow(3)][3] == .value(1))
    }

    // MARK: - Tolerance

    @Test func statusErrorAndUnknownDoNotCount() {
        let records: [JournalRecord] = [
            usage(at: date(2026, 8, 3, 10, 0)),
            .status(StatusSample(t: "2026-08-03T10:15:00Z", svc: [], worst: "operational")),
            .error(ErrorSample(t: "2026-08-03T10:30:00Z", code: .http(503),
                               reason: "serverProblem", ms: 10)),
            .unknown,
        ]
        let grid = UsageGridAggregator.weekHourGrid(from: records, filter: .fiveHour, timeZone: Self.utc)
        // Only the one `.usage` counts; the others neither add samples nor create holes.
        #expect(grid.cells[Self.mondayFirstRow(2)][10] == .value(1))
    }

    @Test func unparseableTimestampIsSkipped() {
        let win = WindowSample(util: 0, reset: "", timePct: 0, gap: 0, sev: .green)
        let broken = JournalRecord.usage(UsageSample(
            t: "not-a-date", h5: win, d7: win,
            credits: CreditsFlags(active: false, showIcon: false, onCredits: false)))
        let grid = UsageGridAggregator.weekHourGrid(
            from: [broken, usage(at: date(2026, 8, 3, 10))], filter: .fiveHour, timeZone: Self.utc)
        #expect(grid.cells[Self.mondayFirstRow(2)][10] == .value(1))
    }

    @Test func onlyUnparseableRecordsYieldAnAllGapGrid() {
        let win = WindowSample(util: 0, reset: "", timePct: 0, gap: 0, sev: .green)
        let broken = JournalRecord.usage(UsageSample(
            t: "nope", h5: win, d7: win,
            credits: CreditsFlags(active: false, showIcon: false, onCredits: false)))
        let grid = UsageGridAggregator.weekHourGrid(from: [broken], filter: .fiveHour, timeZone: Self.utc)
        #expect(grid.cells.flatMap { $0 }.allSatisfy { $0 == .gap })
    }

    // MARK: - DST

    @Test func dstSpringForwardKeepsTwentyFourColumns() {
        // Kyiv springs forward 2026-03-29 (03:00 never exists locally). The grid stays 7×24 and the
        // samples on either side land in their real local hours.
        let records = [
            usage(at: date(2026, 3, 29, 1, 30, zone: Self.kyiv), zone: Self.kyiv),
            usage(at: date(2026, 3, 29, 4, 30, zone: Self.kyiv), zone: Self.kyiv),
        ]
        let grid = UsageGridAggregator.weekHourGrid(from: records, filter: .fiveHour, timeZone: Self.kyiv)
        #expect(grid.cells.count == 7)
        #expect(grid.cells.allSatisfy { $0.count == 24 })
        let sunday = Self.mondayFirstRow(1)
        #expect(grid.cells[sunday][1] == .value(1))
        #expect(grid.cells[sunday][4] == .value(1))
    }

    @Test func dstFallBackKeepsTwentyFourColumns() {
        // Kyiv falls back 2026-10-25 (02:00 happens twice). Still 7×24, no crash, no duplicate rows.
        let records = [
            usage(at: date(2026, 10, 25, 1, 30, zone: Self.kyiv), zone: Self.kyiv),
            usage(at: date(2026, 10, 25, 4, 30, zone: Self.kyiv), zone: Self.kyiv),
        ]
        let grid = UsageGridAggregator.weekHourGrid(from: records, filter: .fiveHour, timeZone: Self.kyiv)
        #expect(grid.cells.count == 7)
        #expect(grid.cells.allSatisfy { $0.count == 24 })
        #expect(grid.cells[Self.mondayFirstRow(1)][4] == .value(1))
    }
}
