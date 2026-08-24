import Foundation

// MARK: - UsageMetric

/// Which quantity each grid cell measures. Step 2 of the Insights pipeline (#244) ships only the
/// pilot's diagnostic metric; utilisation/pacing metrics arrive with the window + chart (#245+).
///
/// It is an `enum` (not a `Bool`) so a new metric is an additive case — the same forward-compatible
/// discipline the journal itself follows.
public enum UsageMetric: Sendable, Equatable {
    /// `dbg_sample_messages` — the count of successful usage polls that fell into a `(day, hour)`
    /// cell. Deliberately diagnostic: it visualises **sampling density**, so cadence (3 min active /
    /// 15 min idle, ADR-0032) and screen-lock pauses show up honestly rather than being smoothed away.
    case sampleDensity
}

// MARK: - UsageGridFilter

/// The mutually-exclusive limit-window filter chosen from the Insights dropdown: 5-hour vs 7-day
/// limits. It selects **which window a metric reads** — not which records are counted, because every
/// ``UsageSample`` is a full snapshot carrying both `h5` and `d7` at once.
///
/// For ``UsageMetric/sampleDensity`` the filter is a deliberate **no-op**: a successful poll is one
/// sample regardless of which limit window you look at, so both filters yield the same per-cell
/// count. The parameter exists so the API shape is already correct for #245's utilisation metrics
/// (which will read `h5` vs `d7`); the density pilot exercises the plumbing without depending on it.
public enum UsageGridFilter: Sendable, Equatable {
    /// 5-hour limits — the `h5` window.
    case fiveHour
    /// 7-day limits — the `d7` window (and the 7-day-paced `opus`/`sonnet`/`scoped`).
    case sevenDay
}

// MARK: - GridCell

/// One `(day, hour)` cell. The two "empty-looking" states are kept distinct on purpose, the same
/// honesty rule as `ServiceStatus.unknown` / ADR-0027: a cell with **zero** samples ("0 polls landed
/// here") must never be collapsed into a cell inside a **sampling gap** ("we weren't looking").
public enum GridCell: Sendable, Equatable {
    /// Covered by a sampling gap (a ``ResumeMarker`` interval) — we weren't polling, so the true value
    /// is unknown. A reader must render this as a hole and never interpolate across it.
    case gap
    /// An observed value. For ``UsageMetric/sampleDensity`` this is the sample count as a `Double`
    /// (`0` is a genuine "nothing landed here", distinct from ``gap``).
    case value(Double)
}

// MARK: - UsageGrid

/// A days × hours bucket grid for one metric under one filter — the pure aggregate the Insights
/// window (#245) and any later chart render. Rows are days (local wall-clock), columns are the 24
/// hours of each day.
///
/// Rows run **oldest → newest**: `days[0]` is the oldest day, `days[dayCount − 1]` is the day
/// containing `now`. `cells[d][h]` is the cell for `days[d]` at local hour `h` (`0…23`).
public struct UsageGrid: Sendable, Equatable {
    /// The local-midnight start of each day row, oldest first. Count is the requested `dayCount`
    /// (clamped to `≥ 0`).
    public let days: [Date]
    /// `cells[day][hour]` — `days.count` rows × 24 columns.
    public let cells: [[GridCell]]
    /// The filter this grid was aggregated under.
    public let filter: UsageGridFilter
    /// The metric each cell measures.
    public let metric: UsageMetric

    public init(days: [Date], cells: [[GridCell]], filter: UsageGridFilter, metric: UsageMetric) {
        self.days = days
        self.cells = cells
        self.filter = filter
        self.metric = metric
    }
}

// MARK: - UsageGridAggregator

/// Turns a journal record stream into a ``UsageGrid`` — a pure, AppKit-free, deterministic function
/// (inject `now`/`timeZone`; it never calls `Date()`), mirroring ``PacingModel`` / ``CreditsPacing``.
///
/// It is the read-side inverse of ``JournalRecordDomain`` (which maps a domain snapshot → a record):
/// here records → a grid. The heterogeneous stream from ``JournalReader/parse(_:)`` is consumed in
/// file order (which is chronological); only `.usage` and `.resume` records participate.
public enum UsageGridAggregator {

    /// Aggregate `records` into a days × hours grid.
    ///
    /// - `.usage` records increment the sample count of the `(day, hour)` cell their timestamp lands
    ///   in (local time). For ``UsageMetric/sampleDensity`` the `filter` does not change the count
    ///   (see ``UsageGridFilter``).
    /// - `.resume` records mark every cell their gap interval `[t − gap … t]` overlaps as ``GridCell/gap``,
    ///   including the hour that *contains* `t` (the hour polling resumed in — part of it was still
    ///   unobserved). A gap wins over samples: once a cell is a gap it stays a gap even if a later
    ///   sample lands in it, because part of that cell was unobserved and honesty requires the hole.
    /// - `.status` / `.error` / `.unknown` are ignored: an error is "we looked, the API failed" — a
    ///   real but non-sample event, and not a gap either — so it neither counts nor creates a hole.
    /// - A record whose timestamp can't be parsed, or that falls outside the grid window, is skipped.
    ///   The function never crashes; unresolved calendar boundaries degrade to an empty grid.
    ///
    /// - Parameters:
    ///   - records: The stream from ``JournalReader/parse(_:)``, in file (chronological) order.
    ///   - metric: Which quantity each cell measures. Defaults to the pilot's ``UsageMetric/sampleDensity``.
    ///   - filter: The 5-hour / 7-day limit-window filter.
    ///   - provider: Whose series to count. **Defaults to `.claude`, not `nil`** — a mixed file counted
    ///     without a filter double-counts every hour both providers polled, and the result looks
    ///     plausible: nothing in a density cell says it summed two series. `nil` asks for all of them
    ///     deliberately.
    ///   - dayCount: How many day-rows to build (the most recent `dayCount` days ending with `now`).
    ///   - now: Current instant (inject for deterministic tests; do **not** call `Date()` here).
    ///   - timeZone: Wall-clock zone whose midnight/hour boundaries anchor the cells. Defaults to
    ///     `.current` — the grid answers "when do I work" in the user's local time (unlike the money
    ///     window's UTC reset), so device-local buckets are what a reader expects.
    public static func grid(
        from records: [JournalRecord],
        metric: UsageMetric = .sampleDensity,
        filter: UsageGridFilter,
        provider: ProviderID? = .claude,
        dayCount: Int,
        now: Date,
        timeZone: TimeZone = .current
    ) -> UsageGrid {
        let empty = UsageGrid(days: [], cells: [], filter: filter, metric: metric)
        guard dayCount > 0 else { return empty }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // Row anchors: local-midnight starts of the most recent `dayCount` days, oldest first, with
        // `days.last` the day containing `now`.
        let today = calendar.startOfDay(for: now)
        var days: [Date] = []
        days.reserveCapacity(dayCount)
        for offset in stride(from: dayCount - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return empty
            }
            days.append(day)
        }
        // The grid window is [days.first 00:00 … days.last + 1 day 00:00); anything outside is dropped.
        guard let windowStart = days.first,
              let windowEnd = calendar.date(byAdding: .day, value: 1, to: today) else {
            return empty
        }

        // Cells start as "observed, zero samples". A gap flips a cell to `.gap` and pins it there.
        var cells = [[GridCell]](repeating: [GridCell](repeating: .value(0), count: 24), count: dayCount)

        // Map a Date to its (row, col) in the grid, or nil if outside the window.
        func indices(for date: Date) -> (day: Int, hour: Int)? {
            guard date >= windowStart, date < windowEnd else { return nil }
            let comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            guard
                let hour = comps.hour,
                let dayStart = calendar.date(from: DateComponents(
                    year: comps.year, month: comps.month, day: comps.day)),
                let row = calendar.dateComponents([.day], from: windowStart, to: dayStart).day,
                row >= 0, row < dayCount, hour >= 0, hour < 24
            else { return nil }
            return (row, hour)
        }

        for record in records {
            switch record {
            case let .usage(sample):
                guard provider == nil || sample.provider == provider?.rawValue,
                      let date = ResetClock.parse(sample.t), let idx = indices(for: date) else {
                    continue
                }
                // A gap already claimed this cell — honesty wins, leave the hole.
                if case .value(let count) = cells[idx.day][idx.hour] {
                    cells[idx.day][idx.hour] = .value(count + 1)
                }

            case let .resume(marker):
                // The gap covers [t − gap … t]. Mark every cell whose hour overlaps that interval.
                // Another provider's hole is not this one's: it kept polling through it.
                guard provider == nil || marker.provider == provider?.rawValue,
                      let gapEnd = ResetClock.parse(marker.t) else { continue }
                let gapStart = gapEnd.addingTimeInterval(-marker.gap)
                markGap(from: gapStart, to: gapEnd, in: &cells, calendar: calendar,
                        windowStart: windowStart, dayCount: dayCount, indices: indices)

            case .status, .error, .unknown:
                continue
            }
        }

        return UsageGrid(days: days, cells: cells, filter: filter, metric: metric)
    }

    /// Flip every whole-hour cell overlapping `[gapStart, gapEnd]` to ``GridCell/gap``. Walks hour by
    /// hour from the start of the gap's first hour so a multi-hour or day-crossing gap paints every
    /// cell it touches. `indices` clamps both grid edges, so out-of-window hours are simply no-ops.
    private static func markGap(
        from gapStart: Date,
        to gapEnd: Date,
        in cells: inout [[GridCell]],
        calendar: Calendar,
        windowStart: Date,
        dayCount: Int,
        indices: (Date) -> (day: Int, hour: Int)?
    ) {
        guard gapEnd > gapStart else { return }
        // Start at the top of the hour containing gapStart (clamped into the window), then step by one
        // hour. Using dateComponents([.hour]) keeps DST correct — Foundation advances real hours.
        let clampedStart = max(gapStart, windowStart)
        let hourComps = calendar.dateComponents([.year, .month, .day, .hour], from: clampedStart)
        guard var cursor = calendar.date(from: hourComps) else { return }
        // Walk hour-starts while the hour still overlaps the gap, i.e. while the hour's start is ≤
        // gapEnd — so the hour *containing* gapEnd (the hour we resumed polling in) is itself painted
        // as a gap: part of it was unobserved, and honesty shows the hole.
        // Bound the walk so a corrupt/huge gap can't loop unboundedly (24 h × rows is the whole grid).
        var guardSteps = dayCount * 24 + 1
        while cursor <= gapEnd && guardSteps > 0 {
            if let idx = indices(cursor) {
                cells[idx.day][idx.hour] = .gap
            }
            guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor) else { break }
            cursor = next
            guardSteps -= 1
        }
    }
}
