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

/// One `(weekday, hour)` cell. The two "empty-looking" states are kept distinct on purpose, the same
/// honesty rule as `ServiceStatus.unknown` / ADR-0027: a cell with **zero** samples ("0 polls landed
/// here") must never be collapsed into a cell we never observed at all ("we weren't looking").
public enum GridCell: Sendable, Equatable {
    /// Never observed: **every** occurrence of this `(weekday, hour)` slot across the whole history was
    /// either inside a sampling gap or before the journal began. The true value is unknown, so a reader
    /// must render this as a hole and never interpolate across it.
    case gap
    /// An observed value. For ``UsageMetric/sampleDensity`` this is the **mean sample count per observed
    /// occurrence** of the slot (`0` is a genuine "we watched and nothing landed here", distinct from
    /// ``gap``). Averaging — rather than summing — keeps rows comparable when the history holds a
    /// different number of, say, Mondays than Sundays.
    case value(Double)
}

// MARK: - UsageGrid

/// A **weekday × hours** bucket grid for one metric under one filter — the pure aggregate the Insights
/// window (#245) renders. Rows are the seven weekdays, columns are the 24 hours of the day, both in
/// local wall-clock time.
///
/// Unlike a calendar view, this folds the **whole history**: every Monday ever recorded contributes to
/// the "Monday" row, so the grid answers "when do I usually work" rather than "what did last week look
/// like". Each cell therefore holds a mean per observed occurrence (see ``GridCell/value(_:)``).
///
/// Rows are ordered by ``weekdays``, which starts at the caller's first day of the week — the pilot
/// pins Monday→Sunday; taking it from the locale is #251.
public struct UsageGrid: Sendable, Equatable {
    /// The weekday of each row, in display order. Values use Foundation's `Calendar` convention
    /// (`1 = Sunday … 7 = Saturday`), so a Monday-first grid reads `[2, 3, 4, 5, 6, 7, 1]`.
    public let weekdays: [Int]
    /// `cells[row][hour]` — `weekdays.count` rows × 24 columns.
    public let cells: [[GridCell]]
    /// The filter this grid was aggregated under.
    public let filter: UsageGridFilter
    /// The metric each cell measures.
    public let metric: UsageMetric

    public init(weekdays: [Int], cells: [[GridCell]], filter: UsageGridFilter, metric: UsageMetric) {
        self.weekdays = weekdays
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

    /// Aggregate `records` into a **weekday × hours** grid, folding the entire history.
    ///
    /// Every `(weekday, hour)` slot occurs many times across the journal — four or five Mondays at
    /// 14:00, say. Each occurrence is classified as **observed** (we were polling) or **unobserved**
    /// (inside a sampling gap), and the cell reports the mean sample count over the observed ones only.
    /// A slot with no observed occurrence at all becomes ``GridCell/gap``.
    ///
    /// - `.usage` records add one sample to the `(weekday, hour)` slot their timestamp lands in (local
    ///   time). For ``UsageMetric/sampleDensity`` the `filter` does not change the count (see
    ///   ``UsageGridFilter``).
    /// - `.resume` records mark every hour their gap interval `[t − gap … t]` overlaps as unobserved,
    ///   including the hour that *contains* `t` (polling resumed mid-hour, so part of it was missed).
    ///   Unlike the calendar view this does **not** blank the cell outright: other weeks may have
    ///   observed the same slot, and a hole is only honest when every week missed it.
    /// - `.status` / `.error` / `.unknown` are ignored: an error is "we looked, the API failed" — a real
    ///   but non-sample event, and not a gap either — so it neither counts nor creates a hole.
    /// - A record whose timestamp can't be parsed is skipped. The function never crashes.
    ///
    /// The observed span runs from the first to the last parsable record, so hours before the journal
    /// began are simply never counted — they are not silently treated as zeros.
    ///
    /// - Parameters:
    ///   - records: The stream from ``JournalReader/parse(_:)``, in file (chronological) order.
    ///   - metric: Which quantity each cell measures. Defaults to the pilot's ``UsageMetric/sampleDensity``.
    ///   - filter: The 5-hour / 7-day limit-window filter.
    ///   - firstWeekday: Which weekday heads the grid, Foundation-style (`1 = Sunday … 7 = Saturday`).
    ///     Defaults to `2` (Monday). Taking this from the locale is #251.
    ///   - timeZone: Wall-clock zone whose midnight/hour boundaries anchor the cells. Defaults to
    ///     `.current` — the grid answers "when do I work" in the user's local time (unlike the money
    ///     window's UTC reset), so device-local buckets are what a reader expects.
    public static func weekHourGrid(
        from records: [JournalRecord],
        metric: UsageMetric = .sampleDensity,
        filter: UsageGridFilter,
        firstWeekday: Int = 2,
        timeZone: TimeZone = .current
    ) -> UsageGrid {
        // Row order: seven weekdays starting at `firstWeekday`, wrapping through the 1…7 range.
        let start = (firstWeekday >= 1 && firstWeekday <= 7) ? firstWeekday : 2
        let weekdays = (0..<7).map { ((start - 1 + $0) % 7) + 1 }
        // Row index by Foundation weekday number, so lookups don't scan the array per record.
        var rowOf = [Int](repeating: 0, count: 8)
        for (row, weekday) in weekdays.enumerated() { rowOf[weekday] = row }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // Per slot: how many samples landed, and over how many observed occurrences. Observed
        // occurrences are counted by walking the journal's span hour by hour, minus the gap hours.
        var sampleTotals = [[Double]](repeating: [Double](repeating: 0, count: 24), count: 7)
        var observed = [[Int]](repeating: [Int](repeating: 0, count: 24), count: 7)

        /// The `(row, hour)` slot an instant belongs to.
        func slot(for date: Date) -> (row: Int, hour: Int)? {
            let comps = calendar.dateComponents([.weekday, .hour], from: date)
            guard let weekday = comps.weekday, let hour = comps.hour,
                  weekday >= 1, weekday <= 7, hour >= 0, hour < 24 else { return nil }
            return (rowOf[weekday], hour)
        }

        // Pass 1: tally samples, and collect the gap intervals plus the observed span.
        var gaps: [(start: Date, end: Date)] = []
        var spanStart: Date?
        var spanEnd: Date?
        for record in records {
            switch record {
            case let .usage(sample):
                guard let date = ResetClock.parse(sample.t) else { continue }
                if let s = slot(for: date) { sampleTotals[s.row][s.hour] += 1 }
                if spanStart == nil { spanStart = date }
                spanEnd = max(spanEnd ?? date, date)

            case let .resume(marker):
                guard let gapEnd = ResetClock.parse(marker.t) else { continue }
                gaps.append((start: gapEnd.addingTimeInterval(-marker.gap), end: gapEnd))
                if spanStart == nil { spanStart = gapEnd.addingTimeInterval(-marker.gap) }
                spanEnd = max(spanEnd ?? gapEnd, gapEnd)

            case .status, .error, .unknown:
                continue
            }
        }

        guard let firstInstant = spanStart, let lastInstant = spanEnd, lastInstant >= firstInstant else {
            // Nothing parsable: every slot is unknown, so the whole grid is holes.
            let allGaps = [[GridCell]](repeating: [GridCell](repeating: .gap, count: 24), count: 7)
            return UsageGrid(weekdays: weekdays, cells: allGaps, filter: filter, metric: metric)
        }

        // Pass 2: walk the span hour by hour, counting each hour as an observed occurrence of its slot
        // unless a gap covers it. Stepping with `.hour` keeps DST correct (Foundation advances real
        // hours, so a 23- or 25-hour day lands in the right buckets).
        let hourComps = calendar.dateComponents([.year, .month, .day, .hour], from: firstInstant)
        guard var cursor = calendar.date(from: hourComps) else {
            let allGaps = [[GridCell]](repeating: [GridCell](repeating: .gap, count: 24), count: 7)
            return UsageGrid(weekdays: weekdays, cells: allGaps, filter: filter, metric: metric)
        }
        /// Whether any gap covers the hour starting at `hourStart` — the hour containing either end of a
        /// gap counts as unobserved, since polling was down for part of it.
        func isGapHour(_ hourStart: Date) -> Bool {
            let hourEnd = hourStart.addingTimeInterval(3600)
            return gaps.contains { $0.start < hourEnd && $0.end >= hourStart }
        }
        while cursor <= lastInstant {
            if !isGapHour(cursor), let s = slot(for: cursor) {
                observed[s.row][s.hour] += 1
            }
            guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor) else { break }
            cursor = next
        }

        // Mean per observed occurrence; a slot observed zero times is an honest hole.
        var cells = [[GridCell]](repeating: [GridCell](repeating: .gap, count: 24), count: 7)
        for row in 0..<7 {
            for hour in 0..<24 where observed[row][hour] > 0 {
                cells[row][hour] = .value(sampleTotals[row][hour] / Double(observed[row][hour]))
            }
        }
        return UsageGrid(weekdays: weekdays, cells: cells, filter: filter, metric: metric)
    }
}
