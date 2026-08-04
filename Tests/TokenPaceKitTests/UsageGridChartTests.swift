import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - UsageGrid chart-model helpers (#245)

@Suite("UsageGrid chart helpers")
struct UsageGridChartTests {

    /// Build a grid from a compact 2D array of cells (rows = weekdays, cols = hours). Weekday numbers
    /// start at Monday (`2`) and simply run on, which is all these pure helpers care about.
    private func grid(_ rows: [[GridCell]]) -> UsageGrid {
        let weekdays = (0..<rows.count).map { ((1 + $0) % 7) + 1 }
        return UsageGrid(weekdays: weekdays, cells: rows, filter: .fiveHour, metric: .sampleDensity)
    }

    // MARK: points

    @Test func pointsFlattenRowMajorWithStableIds() {
        let g = grid([
            [.value(0), .value(3)],
            [.gap,      .value(1)],
        ])
        let pts = g.points
        #expect(pts.count == 4)
        #expect(pts[0].rowIndex == 0 && pts[0].hour == 0 && pts[0].cell == .value(0))
        #expect(pts[1].rowIndex == 0 && pts[1].hour == 1 && pts[1].cell == .value(3))
        #expect(pts[2].rowIndex == 1 && pts[2].hour == 0 && pts[2].cell == .gap)
        #expect(pts[3].rowIndex == 1 && pts[3].hour == 1 && pts[3].cell == .value(1))
        // ids unique
        #expect(Set(pts.map(\.id)).count == 4)
    }

    @Test func emptyGridHasNoPoints() {
        let g = UsageGrid(weekdays: [], cells: [], filter: .fiveHour, metric: .sampleDensity)
        #expect(g.points.isEmpty)
    }

    @Test func pointValueAndGapDistinguishZeroFromHole() {
        let zero = UsageGridPoint(rowIndex: 0, hour: 0, cell: .value(0))
        let gapPt = UsageGridPoint(rowIndex: 0, hour: 1, cell: .gap)
        let three = UsageGridPoint(rowIndex: 0, hour: 2, cell: .value(3))
        #expect(zero.value == 0 && !zero.isGap)         // genuine zero: value 0, not a gap
        #expect(gapPt.value == nil && gapPt.isGap)      // hole: nil value, gap
        #expect(three.value == 3 && !three.isGap)
    }

    // MARK: maxObservedValue

    @Test func maxIsLargestNonGapValue() {
        let g = grid([[.value(0), .value(7), .gap, .value(3)]])
        #expect(g.maxObservedValue == 7)   // gap ignored
    }

    @Test func maxIsNilWhenAllGap() {
        let g = grid([[.gap, .gap], [.gap, .gap]])
        #expect(g.maxObservedValue == nil)   // nothing observed → nothing to scale against
    }

    @Test func maxIsNilForEmptyGrid() {
        let g = UsageGrid(weekdays: [], cells: [], filter: .fiveHour, metric: .sampleDensity)
        #expect(g.maxObservedValue == nil)
    }

    @Test func maxIsZeroWhenAllObservedZero() {
        // Data exists but is all zero — 0, not nil (distinct from "all gap").
        let g = grid([[.value(0), .value(0)], [.gap, .value(0)]])
        #expect(g.maxObservedValue == 0)
    }
}
