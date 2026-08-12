import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - PacingBucket

/// The journal's objective 5-way colour bucket. Boundaries are exercised directly on `BarLayout`
/// values so the thresholds (ahead 0.16·(1−t), behind 2 h/5h · medium, the two 20-min overrides,
/// exhaustion) are pinned. All at the shipped **medium** behind-multiplier, independent of any user
/// `CalmColorMode` / `FarBehindInterval` — the "control-freak" contract of ``PacingBucket``.
@Suite("PacingBucket boundaries")
struct PacingBucketTests {

    private let fiveHour = LimitWindow.fiveHour.durationSeconds   // 18 000

    /// A layout mid-window (so neither 20-min override fires) with the given usage/time fractions.
    private func layout(usage: Double, time: Double, blueAllowed: Bool = true) -> BarLayout {
        // Place the window half-elapsed so `remainingSeconds` and `elapsed` are both well past 1200 s.
        let remaining = Double(fiveHour) * 0.5
        let pacing: PacingState = time >= usage ? .onPaceOrBehind : .ahead
        return BarLayout(
            usageFraction: usage, timeFraction: time, pacing: pacing,
            remainingSeconds: remaining, windowDurationSeconds: fiveHour,
            blueAllowed: blueAllowed)
    }

    @Test func exhaustedIsRedEvenWhenOnPace() {
        // usage >= 1 wins on both sides (a just-reset 100 % window can read as on-pace).
        #expect(PacingBucket.of(layout(usage: 1.0, time: 1.0)) == .red)
        #expect(PacingBucket.of(layout(usage: 1.0, time: 0.2)) == .red)
    }

    @Test func mildlyAheadIsYellow() {
        // Ahead by less than aheadThreshold(0.5) = 0.08 → yellow.
        #expect(PacingBucket.of(layout(usage: 0.55, time: 0.5)) == .yellow)   // lead 0.05 < 0.08
    }

    @Test func clearlyAheadIsOrange() {
        // Ahead by more than the threshold → orange.
        #expect(PacingBucket.of(layout(usage: 0.7, time: 0.5)) == .orange)    // lead 0.20 > 0.08
    }

    @Test func onPaceIsGreen() {
        // time >= usage, surplus below the behind-threshold (0.40) → green.
        #expect(PacingBucket.of(layout(usage: 0.5, time: 0.5)) == .green)     // tie → on-pace → green
        #expect(PacingBucket.of(layout(usage: 0.4, time: 0.5)) == .green)     // surplus 0.10 < 0.40
    }

    @Test func deepBehindIsBlue() {
        // Surplus above the medium behind-threshold (2 h / 5 h = 0.40) → blue.
        #expect(PacingBucket.of(layout(usage: 0.0, time: 0.5)) == .blue)      // surplus 0.50 > 0.40
    }

    @Test func orangeOverrideNearReset() {
        // Within 20 min of reset, any ahead lead is orange regardless of the dynamic threshold.
        let l = BarLayout(
            usageFraction: 0.51, timeFraction: 0.5, pacing: .ahead,
            remainingSeconds: 600, windowDurationSeconds: fiveHour)
        #expect(PacingBucket.of(l) == .orange)   // lead 0.01 < threshold, but ≤ 20 min → orange
    }

    @Test func greenStartOverrideEarlyInWindow() {
        // In the first 20 min, a big surplus stays green (blue must not flicker at window start).
        let elapsed = 600.0  // 10 min in
        let l = BarLayout(
            usageFraction: 0.0, timeFraction: 0.9, pacing: .onPaceOrBehind,
            remainingSeconds: Double(fiveHour) - elapsed,
            windowDurationSeconds: fiveHour)
        #expect(PacingBucket.of(l) == .green)
    }

    @Test func blueRespectsBlueAllowed() {
        // `blueAllowed` is not a cosmetic user setting but an objective fact about the data (the weekly
        // window has no headroom), so the journal must honour it: the same deep surplus that reads blue
        // with the gate open reads green with it closed.
        #expect(PacingBucket.of(layout(usage: 0.0, time: 0.5)) == .blue)
        #expect(PacingBucket.of(layout(usage: 0.0, time: 0.5, blueAllowed: false)) == .green)
    }

    @Test func codableRawValuesAreStable() {
        // Persisted in the journal — pin the strings.
        #expect(PacingBucket.blue.rawValue == "blue")
        #expect(PacingBucket.green.rawValue == "green")
        #expect(PacingBucket.yellow.rawValue == "yellow")
        #expect(PacingBucket.orange.rawValue == "orange")
        #expect(PacingBucket.red.rawValue == "red")
    }
}
