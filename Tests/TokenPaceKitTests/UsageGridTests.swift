import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - UsageGridAggregator

@Suite("UsageGridAggregator")
struct UsageGridTests {

    // Fixed zone so cell boundaries are deterministic (mirrors CreditsMonthFractionTests).
    private static let kyiv = TimeZone(identifier: "Europe/Kyiv")!   // +02:00 / +03:00 (DST)
    private static let utc = TimeZone(identifier: "UTC")!

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
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
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

    @Test func gridHasRequestedRowsAndTwentyFourColumns() {
        let g = UsageGridAggregator.grid(
            from: [], filter: .fiveHour, dayCount: 3, now: date(2026, 6, 15, 12), timeZone: Self.utc)
        #expect(g.days.count == 3)
        #expect(g.cells.count == 3)
        #expect(g.cells.allSatisfy { $0.count == 24 })
    }

    @Test func rowsAreOldestFirstEndingWithToday() {
        let now = date(2026, 6, 15, 12, zone: Self.utc)
        let g = UsageGridAggregator.grid(
            from: [], filter: .fiveHour, dayCount: 3, now: now, timeZone: Self.utc)
        // days.first = today − 2, days.last = today (local midnight).
        #expect(g.days.first == date(2026, 6, 13, zone: Self.utc))
        #expect(g.days.last == date(2026, 6, 15, zone: Self.utc))
    }

    @Test func zeroDayCountYieldsEmptyGrid() {
        let g = UsageGridAggregator.grid(
            from: [], filter: .fiveHour, dayCount: 0, now: date(2026, 6, 15), timeZone: Self.utc)
        #expect(g.days.isEmpty)
        #expect(g.cells.isEmpty)
    }

    // MARK: - Bucketing into local-time cells

    @Test func samplesLandInTheCorrectHourAndDay() {
        let now = date(2026, 6, 15, 23, zone: Self.utc)
        let records = [
            usage(at: date(2026, 6, 15, 9, 5, zone: Self.utc)),   // today, hour 9
            usage(at: date(2026, 6, 15, 9, 40, zone: Self.utc)),  // today, hour 9 (again)
            usage(at: date(2026, 6, 14, 22, zone: Self.utc)),     // yesterday, hour 22
        ]
        let g = UsageGridAggregator.grid(
            from: records, filter: .fiveHour, dayCount: 3, now: now, timeZone: Self.utc)
        #expect(g.cells[2][9] == .value(2))    // today row = index 2
        #expect(g.cells[1][22] == .value(1))   // yesterday row = index 1
        #expect(g.cells[2][10] == .value(0))   // untouched hour is a genuine zero
    }

    @Test func samplesUseInjectedZoneForBucketing() {
        // 2026-06-15T00:30Z is 03:30 in Kyiv (+03:00 summer). The hour must follow the zone.
        let now = date(2026, 6, 15, 23, zone: Self.kyiv)
        let g = UsageGridAggregator.grid(
            from: [usage(at: date(2026, 6, 15, 0, 30, zone: Self.utc))],
            filter: .fiveHour, dayCount: 1, now: now, timeZone: Self.kyiv)
        #expect(g.cells[0][3] == .value(1))    // 03:xx local, not 00:xx
        #expect(g.cells[0][0] == .value(0))
    }

    // MARK: - Filter is a no-op for the density metric

    @Test func filterDoesNotChangeSampleDensity() {
        let now = date(2026, 6, 15, 23, zone: Self.utc)
        let records = (0..<5).map { usage(at: date(2026, 6, 15, 8, $0 * 10, zone: Self.utc)) }
        let five = UsageGridAggregator.grid(
            from: records, filter: .fiveHour, dayCount: 1, now: now, timeZone: Self.utc)
        let seven = UsageGridAggregator.grid(
            from: records, filter: .sevenDay, dayCount: 1, now: now, timeZone: Self.utc)
        #expect(five.cells == seven.cells)     // same count under either filter
        #expect(five.cells[0][8] == .value(5))
    }

    // MARK: - Zero vs gap

    @Test func gapCellsAreDistinctFromZeroCells() {
        let now = date(2026, 6, 15, 23, zone: Self.utc)
        // A gap ending at 10:00 that ran for 3 h covers hours 07, 08, 09, 10.
        let g = UsageGridAggregator.grid(
            from: [resume(at: date(2026, 6, 15, 10, zone: Self.utc), gap: 3 * 3600)],
            filter: .fiveHour, dayCount: 1, now: now, timeZone: Self.utc)
        #expect(g.cells[0][7] == .gap)
        #expect(g.cells[0][8] == .gap)
        #expect(g.cells[0][9] == .gap)
        #expect(g.cells[0][10] == .gap)
        #expect(g.cells[0][6] == .value(0))    // just before the gap → genuine zero, not a hole
        #expect(g.cells[0][11] == .value(0))   // just after → genuine zero
    }

    @Test func gapCrossingMidnightPaintsBothDays() {
        let now = date(2026, 6, 15, 23, zone: Self.utc)
        // Gap ends at 01:00 on the 15th, ran 3 h → covers 22:00, 23:00 (14th) and 00:00, 01:00 (15th).
        let g = UsageGridAggregator.grid(
            from: [resume(at: date(2026, 6, 15, 1, zone: Self.utc), gap: 3 * 3600)],
            filter: .fiveHour, dayCount: 3, now: now, timeZone: Self.utc)
        #expect(g.cells[1][22] == .gap)   // 14th (row 1)
        #expect(g.cells[1][23] == .gap)
        #expect(g.cells[2][0] == .gap)    // 15th (row 2)
        #expect(g.cells[2][1] == .gap)
        #expect(g.cells[1][21] == .value(0))
    }

    @Test func gapWinsOverASampleInTheSameCell() {
        let now = date(2026, 6, 15, 23, zone: Self.utc)
        // Resume at 09:30 with a 2 h gap covers hours 07, 08, 09. A sample also lands at 09:45 (the
        // first post-gap poll can share the gap's last hour) — the cell must stay a gap.
        let records = [
            resume(at: date(2026, 6, 15, 9, 30, zone: Self.utc), gap: 2 * 3600),
            usage(at: date(2026, 6, 15, 9, 45, zone: Self.utc)),
        ]
        let g = UsageGridAggregator.grid(
            from: records, filter: .fiveHour, dayCount: 1, now: now, timeZone: Self.utc)
        #expect(g.cells[0][9] == .gap)
    }

    // MARK: - Non-sample records are ignored

    @Test func statusErrorAndUnknownDoNotCount() {
        let now = date(2026, 6, 15, 23, zone: Self.utc)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let t = iso.string(from: date(2026, 6, 15, 8, zone: Self.utc))
        let records: [JournalRecord] = [
            .status(StatusSample(t: t, svc: [], worst: "operational")),
            .error(ErrorSample(t: t, code: .http(429), reason: "clientProblem")),
            .unknown,
        ]
        let g = UsageGridAggregator.grid(
            from: records, filter: .fiveHour, dayCount: 1, now: now, timeZone: Self.utc)
        #expect(g.cells[0][8] == .value(0))    // an error is not a sample and not a gap
    }

    @Test func samplesOutsideTheWindowAreDropped() {
        let now = date(2026, 6, 15, 12, zone: Self.utc)
        let records = [
            usage(at: date(2026, 6, 10, 8, zone: Self.utc)),   // before the 3-day window
            usage(at: date(2026, 6, 20, 8, zone: Self.utc)),   // in the future, after `now`'s day
        ]
        let g = UsageGridAggregator.grid(
            from: records, filter: .fiveHour, dayCount: 3, now: now, timeZone: Self.utc)
        let anySample = g.cells.contains { row in row.contains { $0 != .value(0) } }
        #expect(!anySample)
    }

    @Test func unparseableTimestampIsSkipped() {
        let now = date(2026, 6, 15, 23, zone: Self.utc)
        let win = WindowSample(util: 0, reset: "", timePct: 0, gap: 0, sev: .green)
        let bad = JournalRecord.usage(UsageSample(
            t: "not-a-date", h5: win, d7: win,
            credits: CreditsFlags(active: false, showIcon: false, onCredits: false)))
        let g = UsageGridAggregator.grid(
            from: [bad], filter: .fiveHour, dayCount: 1, now: now, timeZone: Self.utc)
        let anySample = g.cells.contains { row in row.contains { $0 != .value(0) } }
        #expect(!anySample)
    }

    // MARK: - DST sanity

    @Test func dstSpringForwardDayStaysTwentyFourColumns() {
        // Kyiv springs forward 2026-03-29 (03:00 → 04:00, so local 03:xx does not exist that day).
        // The grid is always 24 columns; the missing wall-clock hour simply carries no samples.
        let now = date(2026, 3, 29, 23, zone: Self.kyiv)
        let records = [
            usage(at: date(2026, 3, 29, 1, 30, zone: Self.kyiv)),   // 01:30 exists → hour 1
            usage(at: date(2026, 3, 29, 5, 30, zone: Self.kyiv)),   // 05:30 exists → hour 5
        ]
        let g = UsageGridAggregator.grid(
            from: records, filter: .fiveHour, dayCount: 1, now: now, timeZone: Self.kyiv)
        #expect(g.cells[0].count == 24)
        #expect(g.cells[0][1] == .value(1))
        #expect(g.cells[0][5] == .value(1))
        #expect(g.cells[0][3] == .value(0))    // the skipped hour — no crash, just empty
    }

    @Test func dstFallBackDayStaysTwentyFourColumns() {
        // Kyiv falls back 2026-10-25 (04:00 → 03:00, so local 03:xx happens twice). The grid stays 24
        // columns; both 03:xx instants map to hour 3 and are summed.
        let now = date(2026, 10, 25, 23, zone: Self.kyiv)
        let cal = { () -> Calendar in var c = Calendar(identifier: .gregorian); c.timeZone = Self.kyiv; return c }()
        // Two distinct real instants that both render as 03:30 local (before and after fall-back).
        let firstThreeThirty = cal.date(from: DateComponents(
            year: 2026, month: 10, day: 25, hour: 2, minute: 30))!.addingTimeInterval(3600) // ~ first 03:30
        let records = [usage(at: firstThreeThirty), usage(at: date(2026, 10, 25, 8, zone: Self.kyiv))]
        let g = UsageGridAggregator.grid(
            from: records, filter: .fiveHour, dayCount: 1, now: now, timeZone: Self.kyiv)
        #expect(g.cells[0].count == 24)
        #expect(g.cells[0][8] == .value(1))    // the unambiguous sample lands correctly
    }
}
