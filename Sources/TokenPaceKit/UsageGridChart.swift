import Foundation

// MARK: - UsageGrid → chart-model helpers

/// One `(day, hour)` cell flattened for charting — the shape a heatmap iterates over. Pure and
/// AppKit-free (the SwiftUI/Charts view in the shell consumes these), so the flattening and the
/// colour-normalisation denominator stay testable in Kit (#245).
public struct UsageGridPoint: Sendable, Equatable, Identifiable {
    /// Row index into ``UsageGrid/weekdays`` (`0` = the grid's first weekday).
    public let rowIndex: Int
    /// Local hour `0…23`.
    public let hour: Int
    /// The cell at `(rowIndex, hour)`.
    public let cell: GridCell

    /// Stable identity for SwiftUI `ForEach` / Charts — unique per `(weekday, hour)`.
    public var id: Int { rowIndex * 24 + hour }

    public init(rowIndex: Int, hour: Int, cell: GridCell) {
        self.rowIndex = rowIndex
        self.hour = hour
        self.cell = cell
    }

    /// The observed mean sample count, or `nil` for a ``GridCell/gap`` (unknown — draw a hole, don't
    /// colour it on the count scale). A genuine `.value(0)` returns `0`, distinct from a gap's `nil`.
    public var value: Double? {
        if case let .value(v) = cell { return v }
        return nil
    }

    /// Whether this cell is a sampling gap (draw distinctly from a zero — ADR-0027 honesty).
    public var isGap: Bool { cell == .gap }
}

extension UsageGrid {
    /// Every cell flattened to a `(rowIndex, hour, cell)` point, row-major (weekday outer, hour inner) —
    /// the list a heatmap `Chart`/`ForEach` iterates. Empty when the grid has no rows.
    public var points: [UsageGridPoint] {
        var out: [UsageGridPoint] = []
        out.reserveCapacity(weekdays.count * 24)
        for (rowIndex, row) in cells.enumerated() {
            for (hour, cell) in row.enumerated() {
                out.append(UsageGridPoint(rowIndex: rowIndex, hour: hour, cell: cell))
            }
        }
        return out
    }

    /// Short localised names for the grid's rows, in display order (e.g. `["Mon", …, "Sun"]`). Built from
    /// the calendar's own symbols, so a Ukrainian locale reads `["пн", …, "нд"]`.
    public func weekdayLabels(locale: Locale = .current) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.shortStandaloneWeekdaySymbols   // index 0 = Sunday (weekday 1)
        return weekdays.map { weekday in
            let index = weekday - 1
            return (index >= 0 && index < symbols.count) ? symbols[index] : "\(weekday)"
        }
    }

    /// The largest observed sample count across all non-gap cells — the denominator for normalising the
    /// colour scale. `nil` when there are **no observed values at all** (every cell is a gap, or the
    /// grid is empty): the caller then has nothing to scale against and should render only holes.
    ///
    /// A grid whose observed values are all `0` returns `0` (not `nil`) — there is data, it's just all
    /// zero; the caller decides how to colour a `0/0` scale (typically the lightest shade).
    public var maxObservedValue: Double? {
        var found = false
        var maxValue = 0.0
        for row in cells {
            for cell in row {
                if case let .value(v) = cell {
                    found = true
                    if v > maxValue { maxValue = v }
                }
            }
        }
        return found ? maxValue : nil
    }
}
