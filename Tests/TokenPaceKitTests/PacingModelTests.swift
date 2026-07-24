import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Shared fixture

/// A fixed "current time" so all date arithmetic is deterministic.
/// resetsAt is expressed as `now + k` seconds throughout these tests.
private let now = Date(timeIntervalSince1970: 1_000_000)

// MARK: - elapsedFraction

@Suite("PacingModel.elapsedFraction")
struct ElapsedFractionTests {

    // MARK: Five-hour window

    @Test func fullWindowRemainingIsZero() {
        // Exactly one full window remains — nothing elapsed yet.
        let f = PacingModel.elapsedFraction(resetsAt: now + 18_000, now: now, window: .fiveHour)
        #expect(abs(f - 0.0) < 1e-9)
    }

    @Test func halfWindowElapsed() {
        let f = PacingModel.elapsedFraction(resetsAt: now + 9_000, now: now, window: .fiveHour)
        #expect(abs(f - 0.5) < 1e-9)
    }

    @Test func quarterWindowElapsed() {
        let f = PacingModel.elapsedFraction(resetsAt: now + 13_500, now: now, window: .fiveHour)
        #expect(abs(f - 0.25) < 1e-9)
    }

    @Test func resetInPastReturnsOne() {
        // Reset already happened → entire window has elapsed.
        let f = PacingModel.elapsedFraction(resetsAt: now - 1, now: now, window: .fiveHour)
        #expect(f == 1.0)
    }

    @Test func resetExactlyNowReturnsOne() {
        // diff == 0 → bash `<= 0` branch → 100 % elapsed.
        let f = PacingModel.elapsedFraction(resetsAt: now, now: now, window: .fiveHour)
        #expect(f == 1.0)
    }

    @Test func remainingExceedsWindowReturnsZero() {
        // Clock skew: more time remaining than the full window → 0 % elapsed.
        let f = PacingModel.elapsedFraction(resetsAt: now + 18_001, now: now, window: .fiveHour)
        #expect(f == 0.0)
    }

    @Test func remainingFarExceedsWindowReturnsZero() {
        let f = PacingModel.elapsedFraction(resetsAt: now + 100_000, now: now, window: .fiveHour)
        #expect(f == 0.0)
    }

    // MARK: Seven-day window

    @Test func sevenDayHalfElapsed() {
        let f = PacingModel.elapsedFraction(resetsAt: now + 302_400, now: now, window: .sevenDay)
        #expect(abs(f - 0.5) < 1e-9)
    }

    @Test func sevenDayQuarterElapsed() {
        // 3/4 of the window remains → 1/4 elapsed.
        let f = PacingModel.elapsedFraction(resetsAt: now + 453_600, now: now, window: .sevenDay)
        #expect(abs(f - 0.25) < 1e-9)
    }

    // MARK: Range invariant

    @Test(arguments: [
        (now + 18_000, LimitWindow.fiveHour),
        (now + 9_000,  .fiveHour),
        (now - 1,      .fiveHour),
        (now,          .fiveHour),
        (now + 18_001, .fiveHour),
        (now + 302_400, .sevenDay),
        (now - 60,     .sevenDay),
    ])
    func alwaysInUnitRange(resetsAt: Date, window: LimitWindow) {
        let f = PacingModel.elapsedFraction(resetsAt: resetsAt, now: now, window: window)
        #expect(f >= 0.0 && f <= 1.0)
    }
}

// MARK: - limitIndicator

struct IndicatorCase: Sendable {
    let util: Double
    let time: Double
    let want: LimitIndicator
}

@Suite("PacingModel.limitIndicator")
struct LimitIndicatorTests {

    private static let cases: [IndicatorCase] = [
        // critical
        IndicatorCase(util: 100,    time: 50,  want: .critical),
        IndicatorCase(util: 100,    time: 95,  want: .critical), // crit ignores time
        // near-100 but truncation keeps it out of critical
        IndicatorCase(util: 99.9999, time: 95,  want: .neutral), // truncate→99, time>90
        IndicatorCase(util: 99.9999, time: 50,  want: .warning), // truncate→99 (>90), 50≤90
        // warning boundary
        IndicatorCase(util: 91,     time: 90,  want: .warning), // exactly at both thresholds
        IndicatorCase(util: 91,     time: 91,  want: .neutral), // time just above 90
        IndicatorCase(util: 95,     time: 90,  want: .warning),
        IndicatorCase(util: 95,     time: 0,   want: .warning),
        IndicatorCase(util: 95,     time: 100, want: .neutral), // late in window, high but ok
        // usage boundary: 90 is NOT > 90
        IndicatorCase(util: 90,     time: 50,  want: .neutral),
        IndicatorCase(util: 90.9,   time: 50,  want: .neutral), // truncate→90, not >90
        // neutral — normal
        IndicatorCase(util: 13,     time: 5,   want: .neutral),
        IndicatorCase(util: 0,      time: 0,   want: .neutral),
    ]

    @Test(arguments: LimitIndicatorTests.cases)
    func indicator(_ c: IndicatorCase) {
        let got = PacingModel.limitIndicator(utilization: c.util, timePercent: c.time)
        #expect(got == c.want,
            "limitIndicator(util: \(c.util), time: \(c.time)) expected \(c.want), got \(got)")
    }

    @Test func doubleJustBelow100IsNotCritical() {
        // Precision contract: 99.9999... must NOT become critical.
        // With time > 90: neutral (not warning either).
        #expect(PacingModel.limitIndicator(utilization: 99.9999, timePercent: 91) == .neutral)
        // With time ≤ 90: warning (not critical).
        #expect(PacingModel.limitIndicator(utilization: 99.9999, timePercent: 90) == .warning)
    }
}

// MARK: - barLayout

@Suite("PacingModel.barLayout")
struct BarLayoutTests {

    // Helper: build layout where resetsAt gives the given time-percent
    // (fiveHour window: remaining = (1 - timePct/100) * 18000 s).
    private static func layout(util: Double, timePct: Double) -> BarLayout {
        let remaining = (1.0 - timePct / 100) * 18_000
        let resetsAt  = now + remaining
        return PacingModel.barLayout(utilization: util, resetsAt: resetsAt, now: now, window: .fiveHour)
    }

    @Test func behindPaceIsOnPaceOrBehind() {
        let l = BarLayoutTests.layout(util: 20, timePct: 50)
        #expect(abs(l.usageFraction - 0.2)  < 1e-9)
        #expect(abs(l.timeFraction  - 0.5)  < 1e-9)
        #expect(l.pacing == .onPaceOrBehind)
        #expect(abs(l.gapStart - 0.2) < 1e-9)
        #expect(abs(l.gapEnd   - 0.5) < 1e-9)
    }

    @Test func aheadPaceIsAhead() {
        let l = BarLayoutTests.layout(util: 80, timePct: 50)
        #expect(abs(l.usageFraction - 0.8) < 1e-9)
        #expect(abs(l.timeFraction  - 0.5) < 1e-9)
        #expect(l.pacing == .ahead)
        #expect(abs(l.gapStart - 0.5) < 1e-9)
        #expect(abs(l.gapEnd   - 0.8) < 1e-9)
    }

    @Test func equalUsageAndTimeIsOnPaceOrBehind() {
        // The exact tie (usage == time) must land in the green branch —
        // matching statusline's `u_blocks <= t_blocks` dispatch.
        let l = BarLayoutTests.layout(util: 50, timePct: 50)
        #expect(l.pacing == .onPaceOrBehind)
        #expect(abs(l.gapStart - l.gapEnd) < 1e-9) // zero-width gap
    }

    @Test func zeroUsageZeroTime() {
        let l = BarLayoutTests.layout(util: 0, timePct: 0)
        #expect(l.usageFraction == 0.0)
        #expect(l.timeFraction  == 0.0)
        #expect(l.pacing == .onPaceOrBehind)
    }

    @Test func fullUsageFullTime() {
        // Reset is in the past → time = 100 %; usage = 100 %.
        let l = PacingModel.barLayout(utilization: 100, resetsAt: now - 1, now: now, window: .fiveHour)
        #expect(l.usageFraction == 1.0)
        #expect(l.timeFraction  == 1.0)
        #expect(l.pacing == .onPaceOrBehind)
    }

    @Test func usageAbove100IsClamped() {
        let l = BarLayoutTests.layout(util: 105, timePct: 50)
        #expect(l.usageFraction == 1.0)
    }

    @Test func usageBelow0IsClamped() {
        let l = BarLayoutTests.layout(util: -5, timePct: 50)
        #expect(l.usageFraction == 0.0)
    }

    @Test func continuousUsageNotTruncated() {
        // The bar is pixel-accurate: 90.4 % must stay 0.904, not be floored to 0.9.
        let l = BarLayoutTests.layout(util: 90.4, timePct: 50)
        #expect(abs(l.usageFraction - 0.904) < 1e-9)
    }

    @Test func indicatorPositionEqualsTimeFraction() {
        let l = BarLayoutTests.layout(util: 10, timePct: 77)
        // The time-indicator tick sits exactly at timeFraction.
        #expect(abs(l.timeFraction - 0.77) < 1e-9)
    }
}

// MARK: - blockIndex

@Suite("PacingModel.blockIndex")
struct BlockIndexTests {

    @Test func zeroFractionGivesZero() {
        #expect(PacingModel.blockIndex(fraction: 0.0, cells: 10) == 0)
    }

    @Test func fullFractionGivesAllCells() {
        #expect(PacingModel.blockIndex(fraction: 1.0, cells: 10) == 10)
    }

    @Test func halfIsRoundedHalfUp() {
        // bash: (50 * 10 + 50) / 100 = 5
        #expect(PacingModel.blockIndex(fraction: 0.5, cells: 10) == 5)
    }

    @Test func justAboveHalfRoundsUp() {
        // 0.55 * 100 = 55; (55 * 10 + 50) / 100 = 6
        #expect(PacingModel.blockIndex(fraction: 0.55, cells: 10) == 6)
    }

    @Test func justBelowHalfRoundsDown() {
        // 0.54 * 100 = 54; (54 * 10 + 50) / 100 = 5 (integer floor)
        #expect(PacingModel.blockIndex(fraction: 0.54, cells: 10) == 5)
    }

    @Test func thirtyChellsMatchStatusline() {
        // bash (5h): build_progress_bar ... 30 — (50 * 30 + 50) / 100 = 15
        #expect(PacingModel.blockIndex(fraction: 0.5, cells: 30) == 15)
    }

    @Test func twentyEightCellsMatchStatusline() {
        // bash (7d): build_progress_bar ... 28 — (50 * 28 + 50) / 100 = 14
        #expect(PacingModel.blockIndex(fraction: 0.5, cells: 28) == 14)
    }

    @Test func fractionAboveOneIsClamped() {
        #expect(PacingModel.blockIndex(fraction: 1.5, cells: 10) == 10)
    }

    @Test func fractionBelowZeroIsClamped() {
        #expect(PacingModel.blockIndex(fraction: -0.5, cells: 10) == 0)
    }
}

// MARK: - BarLayout.isCalm (ADR-0028)

@Suite("BarLayout.isCalm")
struct BarLayoutIsCalmTests {

    /// A layout with explicit fractions; `pacing` derived exactly as `barLayout` would
    /// (`time >= usage → onPaceOrBehind`), so `isCalm` is exercised on realistic inputs.
    private static func layout(usage: Double, time: Double) -> BarLayout {
        BarLayout(usageFraction: usage, timeFraction: time,
                  pacing: time >= usage ? .onPaceOrBehind : .ahead)
    }

    @Test func onPaceIsCalm() {   // green — usage below time
        #expect(BarLayoutIsCalmTests.layout(usage: 0.3, time: 0.5).isCalm)
    }

    @Test func exactTieIsCalm() { // green — the equality tie folds into on-pace
        #expect(BarLayoutIsCalmTests.layout(usage: 0.5, time: 0.5).isCalm)
    }

    @Test func slightlyAheadIsCalm() {   // yellow — 10 points ahead (< 0.15)
        #expect(BarLayoutIsCalmTests.layout(usage: 0.5, time: 0.4).isCalm)
    }

    @Test func exactlyFifteenPointsAheadIsNoisy() {  // boundary is strict (< 0.15): 0.15 → orange
        #expect(!BarLayoutIsCalmTests.layout(usage: 0.55, time: 0.4).isCalm)
    }

    @Test func farAheadIsNoisy() {   // orange — 20 points ahead
        #expect(!BarLayoutIsCalmTests.layout(usage: 0.7, time: 0.5).isCalm)
    }

    @Test func exhaustedIsNoisyEvenWhenNearlyOnPace() {  // red — usage == 1 overrides the yellow window
        #expect(!BarLayoutIsCalmTests.layout(usage: 1.0, time: 0.95).isCalm)
    }
}
