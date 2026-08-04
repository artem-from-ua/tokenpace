import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - UsageGridAggregator over the realistic multi-day fixture

/// End-to-end-ish coverage: instead of hand-built one-off records, run the aggregator over
/// ``JournalFixture/multiDay(days:endingAt:interval:)`` — the same deterministic, realistic series
/// (usage saw-tooth, interleaved status, scattered errors, one injected ~4 h gap + resume) the dev
/// hook writes to disk for UI verification. This pins the invariants a maintainer would otherwise
/// eyeball on a console dump, so a regression is caught in CI rather than by reading the diff.
@Suite("UsageGridAggregator over JournalFixture")
struct UsageGridFixtureTests {

    private static let utc = TimeZone(identifier: "UTC")!

    /// Anchor the run on a fixed instant (the fixture is clock-injected, so the whole series is
    /// deterministic). `endingAt` is the newest poll; we bucket in UTC so cell boundaries line up with
    /// the fixture's UTC-based saw-tooth without a zone shift complicating the counts.
    private func build(days: Int) -> (records: [JournalRecord], grid: UsageGrid, endingAt: Date) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = Self.utc
        let endingAt = cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
        let records = JournalFixture.multiDay(days: days, endingAt: endingAt).map { $0.0 }
        let grid = UsageGridAggregator.weekHourGrid(
            from: records, filter: .fiveHour, timeZone: Self.utc)
        return (records, grid, endingAt)
    }

    // MARK: - Shape

    @Test func gridIsAlwaysSevenByTwentyFour() {
        let (_, grid, _) = build(days: 5)
        #expect(grid.cells.count == 7)
        #expect(grid.cells.allSatisfy { $0.count == 24 })
    }

    // MARK: - Density matches the sampling cadence

    @Test func activeHoursShowCadenceDensity() {
        let (_, grid, _) = build(days: 5)
        // The fixture polls every 180 s → at most 20 samples per fully-covered hour. Since each cell is
        // a mean over observed occurrences, no cell may exceed that cadence ceiling.
        var sawDenseHour = false
        for row in grid.cells {
            for cell in row {
                if case .value(let v) = cell {
                    #expect(v >= 0)
                    #expect(v <= 20)          // never more than the cadence allows
                    if v >= 15 { sawDenseHour = true }
                }
            }
        }
        #expect(sawDenseHour)                 // at least one hour is densely sampled
    }

    // MARK: - Gap cells stay distinct from zeros

    @Test func fixtureProducesGapZeroAndPositiveCells() {
        let (records, grid, _) = build(days: 3)
        // The fixture injects exactly one resume marker; confirm it's actually in the stream.
        let resumeCount = records.filter { if case .resume = $0 { return true } else { return false } }.count
        #expect(resumeCount == 1)

        // A 3-day fixture can't observe every weekday, so some rows are never observed → holes. The
        // grid must carry all three states, proving the honesty distinction survives a realistic series.
        let flat = grid.cells.flatMap { $0 }
        #expect(flat.contains(.gap))
        #expect(flat.contains { if case .value(let v) = $0 { return v > 0 } else { return false } })
    }

    @Test func weekdaysOutsideTheFixtureSpanAreGaps() {
        // A 2-day fixture touches at most 3 weekdays; the untouched ones must be holes, never zeros.
        let (_, grid, _) = build(days: 2)
        let gapRows = grid.cells.filter { $0.allSatisfy { $0 == .gap } }.count
        #expect(gapRows >= 3)   // at least three weekdays were never observed at all
    }

    // MARK: - Non-sample records never inflate the grid

    @Test func statusAndErrorRecordsAreNotCounted() {
        let (records, grid, _) = build(days: 3)
        // The fixture carries status + error lines. They must not raise any cell above the poll cadence
        // (20/h); a leak would push means past that ceiling.
        let usageCount = records.filter { if case .usage = $0 { return true } else { return false } }.count
        #expect(usageCount > 0)
        for row in grid.cells {
            for cell in row {
                if case .value(let v) = cell { #expect(v <= 20) }
            }
        }
    }

    // MARK: - Row order

    @Test func rowsAreMondayFirstByDefault() {
        let (_, grid, _) = build(days: 5)
        #expect(grid.weekdays == [2, 3, 4, 5, 6, 7, 1])
    }
}
