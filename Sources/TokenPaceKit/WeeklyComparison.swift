import Foundation

/// This week's weekly-limit use set against the journal's past weeks: where last week stood at the
/// same point of its window, where it ended, and how recent weeks ended.
///
/// Built from the journal rather than token counts because the 7-day window is the constraint the
/// user plans against, and the journal covers the whole account — every surface that spends quota —
/// where local transcripts see this Mac only.
public enum WeeklyComparison {

    /// One 7-day reading from the journal.
    public struct Point: Sendable, Equatable {
        public let reset: Date
        public let timePct: Double
        public let util: Double
        public init(reset: Date, timePct: Double, util: Double) {
            self.reset = reset
            self.timePct = timePct
            self.util = util
        }
    }

    /// The 7-day readings of one provider's usage lines. A reading with no parseable reset has no
    /// week to belong to and is dropped.
    public static func points(from records: [JournalRecord], provider: String = "claude") -> [Point] {
        records.compactMap { record in
            guard case let .usage(sample) = record, sample.provider == provider,
                  let week = sample.d7, let reset = ResetClock.parse(week.reset) else { return nil }
            return Point(reset: reset, timePct: week.timePct, util: week.util)
        }
    }

    /// One past window.
    public struct Week: Sendable, Equatable {
        public let reset: Date
        public let points: [Point]
        /// The highest reading, not the last: the counter can roll back inside a window.
        public var peak: Double { points.map(\.util).max() ?? 0 }
        /// Seen running at its reset, so ``peak`` is the window's real final value.
        public var isComplete: Bool { (points.map(\.timePct).max() ?? 0) >= completeTimePct }
    }

    /// A window counts as finished only if a reading landed this close to its reset.
    static let completeTimePct = 0.985

    /// How far the nearest reading in last week may sit from the current point of the window and
    /// still stand for it — 0.02 of a week is about 3 h.
    static let samePointTolerance = 0.02

    /// Group readings into windows. The same reset arrives in spellings a second apart, so the key is
    /// the reset rounded to the hour.
    public static func weeks(from points: [Point]) -> [Week] {
        let grouped = Dictionary(grouping: points) { ($0.reset.timeIntervalSince1970 / 3_600).rounded() }
        return grouped.values
            .map { group in
                let sorted = group.sorted { $0.timePct < $1.timePct }
                return Week(reset: sorted[0].reset, points: sorted)
            }
            .sorted { $0.reset < $1.reset }
    }

    public struct Summary: Sendable, Equatable {
        /// Last week's use at the point of its window this one has reached, or `nil` when the app was
        /// not running near that point.
        public let lastWeekByNow: Double?
        /// Last week's final peak, or `nil` when the app did not see it reset.
        public let lastWeekFinal: Double?
        /// Final peaks of the most recent complete weeks, oldest first.
        public let recentFinals: [Double]
    }

    /// - Parameters:
    ///   - currentReset: The current 7-day window's reset.
    ///   - currentTimePct: How much of the current window has elapsed, 0…1.
    ///   - lookback: How many recent complete weeks feed ``Summary/recentFinals``.
    public static func summary(weeks: [Week], currentReset: Date, currentTimePct: Double,
                               lookback: Int = 4) -> Summary {
        let week: TimeInterval = 7 * 86_400
        let past = weeks.filter { $0.reset < currentReset.addingTimeInterval(-week / 2) }
        let last = past.last { abs($0.reset.timeIntervalSince(currentReset.addingTimeInterval(-week))) < 3_600 }

        var byNow: Double?
        if let last,
           last.points.contains(where: { abs($0.timePct - currentTimePct) <= samePointTolerance }) {
            byNow = last.points.filter { $0.timePct <= currentTimePct }.map(\.util).max()
        }
        let finals = past.filter(\.isComplete).suffix(lookback).map(\.peak)
        return Summary(lastWeekByNow: byNow,
                       lastWeekFinal: last.flatMap { $0.isComplete ? $0.peak : nil },
                       recentFinals: Array(finals))
    }

    /// `"last week by now 24% · ended at 85%"`, or `nil` when neither half is known.
    public static func lastWeekLine(_ summary: Summary) -> String? {
        let parts = [
            summary.lastWeekByNow.map { "last week by now \(percent($0))" },
            summary.lastWeekFinal.map { "ended at \(percent($0))" },
        ].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// `"past 4 weeks ended 64–92% · avg 81%"`, or `nil` with fewer than two complete weeks — one
    /// week is already the line above.
    public static func recentLine(_ summary: Summary) -> String? {
        let finals = summary.recentFinals
        guard finals.count >= 2, let low = finals.min(), let high = finals.max() else { return nil }
        let average = finals.reduce(0, +) / Double(finals.count)
        return "past \(finals.count) weeks ended \(Int(low.rounded()))–\(percent(high)) · avg \(percent(average))"
    }

    private static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
}
