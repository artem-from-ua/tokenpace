import Foundation
import Testing
@testable import TokenPaceKit

@Suite("WeeklyComparison")
struct WeeklyComparisonTests {

    static let week: TimeInterval = 7 * 86_400
    static let currentReset = ResetClock.parse("2026-11-18T21:00:00+00:00")!

    /// Readings across the window that ends `weeksAgo` weeks before the current one.
    static func window(weeksAgo: Int, readings: [(Double, Double)], jitter: TimeInterval = 0) -> [WeeklyComparison.Point] {
        let reset = currentReset.addingTimeInterval(-Double(weeksAgo) * week)
        return readings.enumerated().map { i, r in
            // Odd readings carry the one-second double of the same reset.
            .init(reset: reset.addingTimeInterval(i.isMultiple(of: 2) ? 0 : jitter), timePct: r.0, util: r.1)
        }
    }

    @Test func resetDoublesASecondApartAreOneWeek() {
        let points = Self.window(weeksAgo: 1, readings: [(0.1, 5), (0.2, 10), (0.5, 30)], jitter: -0.4)
        #expect(WeeklyComparison.weeks(from: points).count == 1)
    }

    @Test func lastWeekBySamePointAndFinal() {
        let points = Self.window(weeksAgo: 1, readings: [(0.10, 8), (0.20, 22), (0.21, 24), (0.60, 50), (0.99, 85)])
        let summary = WeeklyComparison.summary(
            weeks: WeeklyComparison.weeks(from: points), currentReset: Self.currentReset, currentTimePct: 0.21)
        #expect(summary.lastWeekByNow == 24)
        #expect(summary.lastWeekFinal == 85)
        #expect(WeeklyComparison.lastWeekLine(summary) == "last week by now 24% · ended at 85%")
    }

    @Test func peakNotLastValue() {
        // The counter rolled back inside the window; the peak is what was consumed.
        let points = Self.window(weeksAgo: 1, readings: [(0.5, 67), (0.7, 21), (0.995, 40)])
        let summary = WeeklyComparison.summary(
            weeks: WeeklyComparison.weeks(from: points), currentReset: Self.currentReset, currentTimePct: 0.5)
        #expect(summary.lastWeekFinal == 67)
    }

    @Test func unseenResetHasNoFinal() {
        let points = Self.window(weeksAgo: 1, readings: [(0.2, 20), (0.9, 70)])
        let summary = WeeklyComparison.summary(
            weeks: WeeklyComparison.weeks(from: points), currentReset: Self.currentReset, currentTimePct: 0.2)
        #expect(summary.lastWeekFinal == nil)
        #expect(WeeklyComparison.lastWeekLine(summary) == "last week by now 20%")
    }

    @Test func gapAtTheSamePointHasNoByNow() {
        // Nothing within ~3 h of 0.40: the app was off, so "by now" is unknown rather than stale.
        let points = Self.window(weeksAgo: 1, readings: [(0.1, 10), (0.7, 60), (0.99, 80)])
        let summary = WeeklyComparison.summary(
            weeks: WeeklyComparison.weeks(from: points), currentReset: Self.currentReset, currentTimePct: 0.40)
        #expect(summary.lastWeekByNow == nil)
        #expect(WeeklyComparison.lastWeekLine(summary) == "ended at 80%")
    }

    @Test func recentFinalsSkipIncompleteAndCurrentWeeks() {
        let points = Self.window(weeksAgo: 4, readings: [(0.99, 92)])
            + Self.window(weeksAgo: 3, readings: [(0.99, 64)])
            + Self.window(weeksAgo: 2, readings: [(0.5, 50)])          // never seen at its reset
            + Self.window(weeksAgo: 1, readings: [(0.99, 85)])
            + Self.window(weeksAgo: 0, readings: [(0.2, 18)])           // the current week
        let summary = WeeklyComparison.summary(
            weeks: WeeklyComparison.weeks(from: points), currentReset: Self.currentReset, currentTimePct: 0.2)
        #expect(summary.recentFinals == [92, 64, 85])
        #expect(WeeklyComparison.recentLine(summary) == "past 3 weeks ended 64–92% · avg 80%")
    }

    @Test func oneCompleteWeekGivesNoRecentLine() {
        let points = Self.window(weeksAgo: 1, readings: [(0.99, 85)])
        let summary = WeeklyComparison.summary(
            weeks: WeeklyComparison.weeks(from: points), currentReset: Self.currentReset, currentTimePct: 0.2)
        #expect(WeeklyComparison.recentLine(summary) == nil)
    }

    @Test func emptyJournalSaysNothing() {
        let summary = WeeklyComparison.summary(weeks: [], currentReset: Self.currentReset, currentTimePct: 0.5)
        #expect(WeeklyComparison.lastWeekLine(summary) == nil)
        #expect(WeeklyComparison.recentLine(summary) == nil)
    }
}
