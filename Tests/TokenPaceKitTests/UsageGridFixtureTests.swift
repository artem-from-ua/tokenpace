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
        let grid = UsageGridAggregator.grid(
            from: records, filter: .fiveHour, dayCount: days + 1, now: endingAt, timeZone: Self.utc)
        return (records, grid, endingAt)
    }

    // MARK: - Density matches the sampling cadence

    @Test func activeHoursShowCadenceDensity() {
        let (_, grid, _) = build(days: 5)
        // The fixture polls every 180 s → 20 samples per fully-covered hour. Away from the injected
        // gap and day edges, cells should sit around that density, never absurdly high or negative.
        var sawFullHour = false
        for row in grid.cells {
            for cell in row {
                if case .value(let v) = cell {
                    #expect(v >= 0)
                    #expect(v <= 20)          // never more than the cadence allows
                    if v == 20 { sawFullHour = true }
                }
            }
        }
        #expect(sawFullHour)                  // at least one hour is fully, densely sampled
    }

    // MARK: - The injected gap surfaces as gap cells, distinct from zeros

    @Test func injectedGapProducesGapCellsNotZeros() {
        let (records, grid, _) = build(days: 3)
        // The fixture injects exactly one resume marker; confirm it's actually in the stream.
        let resumeCount = records.filter { if case .resume = $0 { return true } else { return false } }.count
        #expect(resumeCount == 1)

        // That gap must paint at least one cell as `.gap` (the ~4 h hole spans several hours).
        let gapCells = grid.cells.flatMap { $0 }.filter { $0 == .gap }.count
        #expect(gapCells >= 1)

        // Sanity: gaps and zeros coexist and are not the same thing — the grid has all three of
        // gap / zero / positive, proving the honesty distinction survives a realistic series.
        let flat = grid.cells.flatMap { $0 }
        #expect(flat.contains(.gap))
        #expect(flat.contains(.value(0)))
        #expect(flat.contains { if case .value(let v) = $0 { return v > 0 } else { return false } })
    }

    // MARK: - Every in-window usage sample is counted exactly once

    @Test func totalCountEqualsInWindowUsageRecords() {
        let (records, grid, _) = build(days: 4)
        // The aggregator counts every in-window usage sample once, EXCEPT those that fall in a cell the
        // injected gap already claimed (gap wins over sample — an intentional, unit-tested rule). The
        // fixture's gap is ~4 h, so at most ~4 hours × 20 polls/h ≈ 80 samples can be absorbed by
        // `.gap`. Thus: never over-count, and undercount only by that bounded, gap-attributable amount.
        let usageCount = records.filter { if case .usage = $0 { return true } else { return false } }.count
        var counted = 0
        for row in grid.cells { for c in row { if case .value(let v) = c { counted += Int(v) } } }
        #expect(counted <= usageCount)        // never over-counts
        #expect(counted >= usageCount - 80)   // shortfall bounded by the ~4 h gap's worth of samples
        #expect(counted > 0)
    }

    // MARK: - Non-sample records never inflate the grid

    @Test func statusAndErrorRecordsAreNotCounted() {
        let (records, grid, _) = build(days: 3)
        // The fixture carries status + error lines. If they leaked into the count, the total would
        // exceed the usage-record count — assert it does not.
        let usageCount = records.filter { if case .usage = $0 { return true } else { return false } }.count
        var counted = 0
        for row in grid.cells { for c in row { if case .value(let v) = c { counted += Int(v) } } }
        #expect(counted <= usageCount)
    }

    // MARK: - The newest day is partial, ending at `now`

    @Test func lastRowEndsAtNow() {
        let (_, grid, endingAt) = build(days: 5)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = Self.utc
        let nowHour = cal.component(.hour, from: endingAt)   // 12
        // Hours strictly after `now`'s hour on the last row saw no polls → all zero (never gap here,
        // since the injected gap is earlier in the day).
        let lastRow = grid.cells[grid.cells.count - 1]
        for hour in (nowHour + 1)..<24 {
            #expect(lastRow[hour] == .value(0))
        }
    }
}
