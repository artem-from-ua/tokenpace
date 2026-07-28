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
    let want: LimitIndicator
}

@Suite("PacingModel.limitIndicator")
struct LimitIndicatorTests {

    private static let cases: [IndicatorCase] = [
        // critical — usage truncates to exactly 100
        IndicatorCase(util: 100,     want: .critical),
        IndicatorCase(util: 100.4,   want: .critical), // truncate→100
        // near-100 but truncation keeps it out of critical
        IndicatorCase(util: 99.9999, want: .neutral),  // truncate→99, not exhausted
        IndicatorCase(util: 95,      want: .neutral),  // high but not at the cap → no glyph now
        IndicatorCase(util: 91,      want: .neutral),
        IndicatorCase(util: 90,      want: .neutral),
        // neutral — normal
        IndicatorCase(util: 13,      want: .neutral),
        IndicatorCase(util: 0,       want: .neutral),
    ]

    @Test(arguments: LimitIndicatorTests.cases)
    func indicator(_ c: IndicatorCase) {
        let got = PacingModel.limitIndicator(utilization: c.util)
        #expect(got == c.want,
            "limitIndicator(util: \(c.util)) expected \(c.want), got \(got)")
    }

    @Test func doubleJustBelow100IsNotCritical() {
        // Precision contract: 99.9999... truncates to 99 and must NOT become critical.
        #expect(PacingModel.limitIndicator(utilization: 99.9999) == .neutral)
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

    @Test func remainingSecondsIsResetMinusNow() {
        // 50 % of the 5h window elapsed → 9000 s (half of 18000) left until reset.
        let l = BarLayoutTests.layout(util: 20, timePct: 50)
        #expect(abs(l.remainingSeconds - 9000) < 1e-9)
    }

    @Test func nearResetForcesOrangeEndToEnd() {
        // Reset in 10 min with only a 1-point lead: below any dynamic threshold, yet the ≤20-min
        // override makes it orange (`.ahead`) — proves `remainingSeconds` is wired through `severity`.
        let l = PacingModel.barLayout(utilization: 99, resetsAt: now + 600, now: now, window: .fiveHour)
        #expect(abs(l.remainingSeconds - 600) < 1e-9)
        #expect(l.pacing == .ahead)          // usage 0.99 > time ≈ 0.967
        #expect(l.severity == .ahead)        // override active (usage < 1, remaining ≤ 1200)
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
    /// (`time >= usage → onPaceOrBehind`), so `isCalm` is exercised on realistic inputs. `remaining`
    /// defaults to a full week so the 20-minute orange override is inactive and only the dynamic
    /// threshold decides — pass a small value to exercise the override.
    private static func layout(usage: Double, time: Double,
                               remaining: TimeInterval = 7 * 24 * 3600) -> BarLayout {
        BarLayout(usageFraction: usage, timeFraction: time,
                  pacing: time >= usage ? .onPaceOrBehind : .ahead, remainingSeconds: remaining)
    }

    @Test func onPaceIsCalm() {   // green — usage below time
        #expect(BarLayoutIsCalmTests.layout(usage: 0.3, time: 0.5).isCalm)
    }

    @Test func exactTieIsCalm() { // green — the equality tie folds into on-pace
        #expect(BarLayoutIsCalmTests.layout(usage: 0.5, time: 0.5).isCalm)
    }

    @Test func mildlyAheadIsCalm() {   // yellow — 5 pts ahead at t=0.4 (< threshold 0.16·0.6 = 0.096)
        #expect(BarLayoutIsCalmTests.layout(usage: 0.45, time: 0.4).isCalm)
    }

    @Test func aheadPastDynamicThresholdIsNoisy() {  // orange — 15 pts ahead at t=0.4 (≥ 0.096)
        #expect(!BarLayoutIsCalmTests.layout(usage: 0.55, time: 0.4).isCalm)
    }

    @Test func farAheadIsNoisy() {   // orange — 20 points ahead at t=0.5 (≥ threshold 0.08)
        #expect(!BarLayoutIsCalmTests.layout(usage: 0.7, time: 0.5).isCalm)
    }

    @Test func nearResetOverrideIsNoisy() {  // orange — tiny lead but window resets in ≤ 20 min
        #expect(!BarLayoutIsCalmTests.layout(usage: 0.51, time: 0.5, remaining: 1200).isCalm)
    }

    @Test func exhaustedIsNoisyEvenWhenNearlyOnPace() {  // red — usage == 1 overrides the yellow window
        #expect(!BarLayoutIsCalmTests.layout(usage: 1.0, time: 0.95).isCalm)
    }
}

// MARK: - BarLayout.severity (ADR-0028/0029)

@Suite("BarLayout.severity")
struct BarLayoutSeverityTests {

    private static func layout(usage: Double, time: Double,
                               remaining: TimeInterval = 7 * 24 * 3600) -> BarLayout {
        BarLayout(usageFraction: usage, timeFraction: time,
                  pacing: time >= usage ? .onPaceOrBehind : .ahead, remainingSeconds: remaining)
    }

    @Test func greenIsCalm() {   // usage below time
        #expect(BarLayoutSeverityTests.layout(usage: 0.3, time: 0.5).severity == .calm)
    }

    @Test func tieIsCalm() {     // usage == time folds into on-pace → calm
        #expect(BarLayoutSeverityTests.layout(usage: 0.5, time: 0.5).severity == .calm)
    }

    @Test func yellowIsCalm() {  // 5 pts ahead at t=0.4 (< threshold 0.096) → still calm
        #expect(BarLayoutSeverityTests.layout(usage: 0.45, time: 0.4).severity == .calm)
    }

    @Test func aheadPastDynamicThresholdIsAhead() {  // 15 pts ahead at t=0.4 (≥ 0.096) → orange
        #expect(BarLayoutSeverityTests.layout(usage: 0.55, time: 0.4).severity == .ahead)
    }

    @Test func farAheadIsAhead() {   // 20 points ahead at t=0.5, usage < 1 → orange
        #expect(BarLayoutSeverityTests.layout(usage: 0.7, time: 0.5).severity == .ahead)
    }

    @Test func exhaustedIsExhausted() {  // usage >= 1 → red, even while ahead
        #expect(BarLayoutSeverityTests.layout(usage: 1.0, time: 0.6).severity == .exhausted)
    }

    @Test func exhaustedOverridesNearlyOnPace() {  // usage == 1 with time just behind → red, not calm
        #expect(BarLayoutSeverityTests.layout(usage: 1.0, time: 0.95).severity == .exhausted)
    }

    // MARK: dynamic threshold — the boundary moves with elapsed time

    /// The same 10-point lead is calm early in a window but noisy past half-way, because the
    /// threshold shrinks (`0.16·(1−t)`): 0.16 at t=0 vs 0.08 at t=0.5.
    @Test func sameLeadFlipsWithElapsedTime() {
        #expect(BarLayoutSeverityTests.layout(usage: 0.10, time: 0.0).severity == .calm)   // thr 0.16
        #expect(BarLayoutSeverityTests.layout(usage: 0.60, time: 0.5).severity == .ahead)  // thr 0.08
    }

    /// Strict `<` at t=0 (threshold exactly 0.16): 0.15 lead is yellow, 0.16 lead is orange.
    @Test func thresholdBoundaryIsStrictAtStart() {
        #expect(BarLayoutSeverityTests.layout(usage: 0.15, time: 0.0).severity == .calm)   // 0.15 < 0.16
        #expect(BarLayoutSeverityTests.layout(usage: 0.16, time: 0.0).severity == .ahead)  // 0.16 ≮ 0.16
    }

    // MARK: 20-minute orange override

    /// A lead below the dynamic threshold is forced orange when the window resets in ≤ 20 min.
    @Test func nearResetForcesOrange() {  // delta 0.01 ≪ thr 0.08, but remaining == 1200 → orange
        #expect(BarLayoutSeverityTests.layout(usage: 0.51, time: 0.5, remaining: 1200).severity == .ahead)
    }

    /// Just outside the override window (1201 s), the same fractions fall back to the formula → calm.
    @Test func justOutsideOverrideStaysCalm() {
        #expect(BarLayoutSeverityTests.layout(usage: 0.51, time: 0.5, remaining: 1201).severity == .calm)
    }

    /// The override does not outrank the earlier rungs: behind pace stays calm, exhausted stays red,
    /// even with a near reset.
    @Test func overrideDoesNotOutrankPaceOrExhaustion() {
        #expect(BarLayoutSeverityTests.layout(usage: 0.5, time: 0.6, remaining: 60).severity == .calm)
        #expect(BarLayoutSeverityTests.layout(usage: 1.0, time: 0.5, remaining: 60).severity == .exhausted)
    }
}

// MARK: - PacingModel.aheadThreshold

@Suite("PacingModel.aheadThreshold")
struct AheadThresholdTests {

    @Test func curveHitsExpectedNodes() {
        #expect(abs(PacingModel.aheadThreshold(timeFraction: 0.0)  - 0.16) < 1e-9)
        #expect(abs(PacingModel.aheadThreshold(timeFraction: 0.5)  - 0.08) < 1e-9)
        #expect(abs(PacingModel.aheadThreshold(timeFraction: 0.75) - 0.04) < 1e-9)
        #expect(abs(PacingModel.aheadThreshold(timeFraction: 1.0)  - 0.00) < 1e-9)
    }

    @Test func clampsOutOfRangeInput() {
        #expect(abs(PacingModel.aheadThreshold(timeFraction: -0.5) - 0.16) < 1e-9)   // t < 0 → 0.16
        #expect(abs(PacingModel.aheadThreshold(timeFraction:  1.5) - 0.00) < 1e-9)   // t > 1 → 0
    }
}
