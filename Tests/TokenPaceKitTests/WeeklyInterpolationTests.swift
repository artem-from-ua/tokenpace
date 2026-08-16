import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Fixtures

/// A fixed instant so every case reads as `now + k` seconds, matching `PacingModelTests`.
private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// A snapshot carrying just the two counters the interpolator reads. `resetsAt` is far enough out
/// that nothing downstream treats the windows as boundary cases.
private func snap(five: Double, weekly: Double) -> UsageSnapshot {
    UsageSnapshot(
        fiveHour: UsageWindow(utilization: five, resetsAt: iso(now + 9_000)),
        sevenDay: UsageWindow(utilization: weekly, resetsAt: iso(now + 302_400)))
}

private func iso(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
}

/// Fold a series of `(fiveHour, weekly)` polls spaced `step` apart, starting at `start`.
private func fold(
    _ polls: [(five: Double, weekly: Double)],
    from state: WeeklyInterpolator = WeeklyInterpolator(),
    step: TimeInterval = 180,
    start: Date = now
) -> (state: WeeklyInterpolator, at: Date) {
    var s = state
    var t = start
    for p in polls {
        s = s.advanced(with: snap(five: p.five, weekly: p.weekly), now: t)
        t = t.addingTimeInterval(step)
    }
    return (s, t - step)
}

/// A realistic run: `h5` climbs 1 pp per poll, resetting at 100, and `d7` ticks up every `n` points
/// of `h5`. Returns the poll list plus the true exchange rate it was built with.
private func series(polls: Int, n: Double, startWeekly: Double = 40) -> [(five: Double, weekly: Double)] {
    var out: [(five: Double, weekly: Double)] = []
    var five = 0.0
    var weekly = startWeekly
    var carry = 0.0
    for _ in 0..<polls {
        five += 1
        if five > 100 { five = 0 }          // the 5h window resets ~33.6× per week
        carry += 1 / n
        if carry >= 1 { carry -= 1; weekly += 1 }
        out.append((five, weekly))
    }
    return out
}

// MARK: - WeeklyRatio

@Suite("WeeklyRatio — robust N estimation")
struct WeeklyRatioTests {

    @Test func emptyWindowUsesTheSeed() {
        #expect(WeeklyRatio().estimate == WeeklyRatio.seed)
        #expect(WeeklyRatio().sampleCount == 0)
    }

    @Test func medianRejectsOutliers() {
        // Twelve honest 10s plus two wild samples: the mean would be 11.1, the median stays 10.
        var r = WeeklyRatio()
        for _ in 0..<12 { r.record(fiveHourGained: 10, sevenDayGained: 1) }
        r.record(fiveHourGained: 3, sevenDayGained: 1)
        r.record(fiveHourGained: 24, sevenDayGained: 1)
        #expect(r.estimate == 10)
        #expect(r.sampleCount == 14)
    }

    @Test func windowForgetsAStaleRate() {
        // A promotion moves N 10 → 15. After a full window of the new rate, nothing of the old
        // remains — this is the mechanism that makes a promo detectable at all (no API field says so).
        var r = WeeklyRatio()
        for _ in 0..<WeeklyRatio.window { r.record(fiveHourGained: 10, sevenDayGained: 1) }
        #expect(r.estimate == 10)
        for _ in 0..<WeeklyRatio.window { r.record(fiveHourGained: 15, sevenDayGained: 1) }
        #expect(r.estimate == 15)
        #expect(r.sampleCount == WeeklyRatio.window)   // capped, oldest dropped
    }

    @Test func oneMeasuredSegmentDisplacesTheSeedImmediately() {
        // The tempting alternative — "hold the seed until the estimate looks reliable" — was measured
        // against the real spread of localN and is worse: a single segment's median beats the seed
        // for any user whose true rate is not exactly 10 (10 % error vs 43 % at N = 7). The seed only
        // wins when it happens to be right, which is the case we cannot detect in advance.
        var r = WeeklyRatio()
        r.record(fiveHourGained: 7, sevenDayGained: 1)
        #expect(r.estimate == 7)                 // not 10, and not a blend
        #expect(r.sampleCount == 1)
    }

    @Test func sanityFiltersRejectUnusableSegments() {
        var r = WeeklyRatio()
        r.record(fiveHourGained: 0, sevenDayGained: 1)      // nothing measured
        r.record(fiveHourGained: 10, sevenDayGained: 0)     // no weekly motion
        r.record(fiveHourGained: 30, sevenDayGained: 3)     // slept through several quanta
        r.record(fiveHourGained: 100, sevenDayGained: 1)    // ratio 100 — corrupt, not merely noisy
        r.record(fiveHourGained: 2, sevenDayGained: 1)      // ratio 2 — below the plausible band
        #expect(r.sampleCount == 0)
        #expect(r.estimate == WeeklyRatio.seed)
    }

    @Test func codableRoundTripPreservesTheEstimator() throws {
        var r = WeeklyRatio()
        for v in [8.0, 9.0, 10.0, 11.0, 12.0] { r.record(fiveHourGained: v, sevenDayGained: 1) }
        let back = try JSONDecoder().decode(WeeklyRatio.self, from: JSONEncoder().encode(r))
        #expect(back == r)
        #expect(back.estimate == r.estimate)
    }
}

// MARK: - Bucket geometry

@Suite("WeeklyInterpolator — bucket geometry")
struct WeeklyBucketTests {

    @Test func edgeBucketsAreHalfWidth() {
        // The scale is bounded, so 0 and 100 cover half a point each.
        #expect(WeeklyInterpolator.floor(of: 0) == 0)
        #expect(WeeklyInterpolator.ceiling(of: 0) == 0.5)
        #expect(WeeklyInterpolator.floor(of: 100) == 99.5)
        #expect(WeeklyInterpolator.ceiling(of: 100) == 100)
    }

    @Test func interiorBucketsAreFullWidth() {
        #expect(WeeklyInterpolator.floor(of: 42) == 41.5)
        #expect(WeeklyInterpolator.ceiling(of: 42) == 42.5)
        #expect(WeeklyInterpolator.centre(of: 42) == 42)
    }

    @Test func ceilingOfTheTopBucketIsExactly100() {
        // The invariant every `>= 100` exhaustion detector in the app relies on.
        #expect(WeeklyInterpolator.ceiling(of: 100) == 100)
    }
}

// MARK: - Reconstruction

@Suite("WeeklyInterpolator — reconstruction")
struct WeeklyInterpolatorTests {

    @Test func firstPollInheritsTheBucketCentre() {
        // No bump seen yet: the position inside the bucket is unobservable, so the centre is the
        // best guess — and never worse than showing the raw value.
        let (s, _) = fold([(five: 10, weekly: 88)])
        let v = s.value(forRaw: 88)
        #expect(v.source == .inherited)
        #expect(v.effective == 88)          // centre of [87.5, 88.5)
    }

    @Test func anObservedBumpMakesTheAnchorFirmAtTheLowerEdge() {
        // The bump 88 → 89 means the true value had just crossed 88.5.
        let (s, _) = fold([(five: 10, weekly: 88), (five: 20, weekly: 89)])
        let v = s.value(forRaw: 89)
        #expect(v.source == .interpolated)
        #expect(v.effective == 88.5)        // exact lower edge, nothing accumulated on top yet
    }

    @Test func accumulatedFiveHourGainCarriesTheValueUp() {
        // After the bump, +10 pp of h5 at the seeded N = 10 buys exactly 1.0 weekly point — but the
        // bucket ceiling clips it just short of the next quantum.
        let (s, _) = fold([(five: 10, weekly: 88), (five: 20, weekly: 89), (five: 25, weekly: 89)])
        let v = s.value(forRaw: 89)
        #expect(v.effective == 89.0)        // 88.5 + 5/10
    }

    @Test func neverOvertakesTheNextQuantum() {
        // A deliberately low N races the accumulation ahead; the ceiling pins it and reports `clipped`.
        var polls: [(five: Double, weekly: Double)] = [(five: 0, weekly: 50)]
        for i in 1...40 { polls.append((five: Double(i), weekly: 50)) }
        let (s, _) = fold(polls)
        let v = s.value(forRaw: 50)
        #expect(v.effective == 50.5)        // pinned at the ceiling, never past it
        #expect(v.effective <= WeeklyInterpolator.ceiling(of: 50))
        #expect(v.source == .clipped)
    }

    @Test func noDownwardGapWhenTheBumpLands() {
        // The ceiling of one bucket and the floor of the next are the same point, so the transition
        // cannot step backwards — the property the whole design rests on.
        var polls: [(five: Double, weekly: Double)] = [(five: 0, weekly: 50)]
        for i in 1...40 { polls.append((five: Double(i), weekly: 50)) }
        let (before, at) = fold(polls)
        let vBefore = before.value(forRaw: 50).effective
        let after = before.advanced(with: snap(five: 41, weekly: 51), now: at + 180)
        let vAfter = after.value(forRaw: 51).effective
        #expect(vBefore <= 50.5)
        #expect(vAfter == 50.5)
        #expect(vAfter >= vBefore)
    }

    @Test func monotoneAcrossALongRealisticRun() {
        // Property-style: over a run with 5h resets and weekly bumps, the value never falls except
        // where the raw value itself fell.
        let polls = series(polls: 400, n: 10)
        var s = WeeklyInterpolator()
        var t = now
        var previous: Double? = nil
        var previousRaw: Double? = nil
        for p in polls {
            s = s.advanced(with: snap(five: p.five, weekly: p.weekly), now: t)
            let v = s.value(forRaw: p.weekly).effective
            if let prev = previous, let prevRaw = previousRaw, p.weekly >= prevRaw {
                #expect(v >= prev - 1e-9, "value fell from \(prev) to \(v) at raw \(p.weekly)")
            }
            previous = v
            previousRaw = p.weekly
            t = t.addingTimeInterval(180)
        }
    }

    @Test func staysInsideItsBucketAcrossALongRun() {
        let polls = series(polls: 400, n: 10)
        var s = WeeklyInterpolator()
        var t = now
        for p in polls {
            s = s.advanced(with: snap(five: p.five, weekly: p.weekly), now: t)
            let v = s.value(forRaw: p.weekly).effective
            #expect(v >= WeeklyInterpolator.floor(of: p.weekly) - 1e-9)
            #expect(v <= WeeklyInterpolator.ceiling(of: p.weekly) + 1e-9)
            t = t.addingTimeInterval(180)
        }
    }

    @Test func theRatioConvergesOnTheTrueRate() {
        // Built at N = 12; the rolling median should find it and displace the seed.
        let polls = series(polls: 400, n: 12)
        let (s, _) = fold(polls)
        #expect(abs(s.ratio.estimate - 12) <= 1.0)
        #expect(s.ratio.sampleCount > 0)
    }

    @Test func aWrongSeedIsDisplacedQuickly() {
        // Whatever the seed, the first real segments take over — which is why the seed is not tuned.
        let polls = series(polls: 200, n: 15)
        let seeded = WeeklyInterpolator(ratio: WeeklyRatio(segments: [5, 5, 5, 5, 5]))
        let (s, _) = fold(polls, from: seeded)
        #expect(abs(s.ratio.estimate - 15) <= 1.5)
    }
}

// MARK: - Five-hour resets and holes

@Suite("WeeklyInterpolator — resets and holes")
struct WeeklyResetTests {

    @Test func aFiveHourResetOnAFreshPollCreditsTheNewValue() {
        // h5 97 → 3 between two fresh polls: the counter reset, and those 3 points are spend that
        // happened after it. Credited in full rather than lost.
        let (s, _) = fold([(five: 90, weekly: 50), (five: 97, weekly: 50), (five: 3, weekly: 50)])
        #expect(s.fiveHourSinceAnchor == 10)   // +7 then +3
        #expect(!s.isDegraded)
    }

    @Test func aServerSideReductionIsNotCreditedAsSpend() {
        // Found in the real journal: `49 → 42`, `67 → 21`, `53 → 51`, all minutes apart. Those are the
        // server lowering its own counter, not 42 points of spend in three minutes — but the
        // "it fell, so the new value is post-reset spend" rule would credit the whole thing.
        var s = WeeklyInterpolator()
        var t = now
        for five in [40.0, 45, 49] {
            s = s.advanced(with: snap(five: five, weekly: 50), now: t)
            t = t.addingTimeInterval(180)
        }
        let before = s.fiveHourSinceAnchor
        s = s.advanced(with: snap(five: 42, weekly: 50), now: t)      // 49 → 42, three minutes later
        let credited = s.fiveHourSinceAnchor - before
        #expect(credited < 42, "the whole post-drop value was credited as spend")
        #expect(credited <= WeeklyInterpolator.maxCreditableSpend(over: 180) + 1e-9)
    }

    @Test func aWrappingCounterCreditsOnlyTheStepItTook() {
        // A counter that wraps (96 → 0) used to hand over its whole new value, so each lap added a
        // phantom jump on top of the real 4 pp step. Caught by the `weekly-interp` stub, whose
        // five-hour counter wraps by construction. The accumulation itself is *expected* to grow —
        // what must not grow is the amount credited per poll.
        var s = WeeklyInterpolator()
        var t = now
        var previousAcc = 0.0
        for n in 0..<120 {
            s = s.advanced(with: snap(five: Double((n * 4) % 100), weekly: 50), now: t)
            let credited = s.fiveHourSinceAnchor - previousAcc
            #expect(credited <= WeeklyInterpolator.maxCreditableSpend(over: 180) + 1e-9,
                    "poll \(n): credited \(credited) pp in one 3-minute step")
            previousAcc = s.fiveHourSinceAnchor
            t = t.addingTimeInterval(180)
        }
    }

    @Test func aFiveHourResetAcrossAHoleIsNotCredited() {
        // The same drop after a long gap may hide more than one reset, so nothing is credited and
        // the state degrades — the raw value is shown instead of a guess.
        var s = WeeklyInterpolator()
        var t = now
        for five in [10.0, 20, 30, 40, 50, 60] {           // establish the cadence
            s = s.advanced(with: snap(five: five, weekly: 50), now: t)
            t = t.addingTimeInterval(180)
        }
        let beforeHole = s.value(forRaw: 50).effective
        s = s.advanced(with: snap(five: 5, weekly: 50), now: t + 7_200)   // 2 h gap, counter fell
        #expect(s.isDegraded)
        let v = s.value(forRaw: 50)
        #expect(v.source == .degraded)
        // The hole stops the value advancing — it must not drag it back. What the reconstruction had
        // already earned for this bucket stays on screen, and the floor is never below the bucket's
        // lower edge (the one thing an observed `k` guarantees).
        #expect(v.effective >= beforeHole)
        #expect(v.effective >= WeeklyInterpolator.floor(of: 50))
        #expect(v.effective <= WeeklyInterpolator.ceiling(of: 50))
    }

    @Test func degradationHoldsInsteadOfFallingBackToTheQuantum() {
        // Regression guard for the two faults the journal replay caught: the fallback must not be
        // the bare quantum `k` (that is the bucket *centre*, an over-claim that later forces a
        // visible step down), and degradation must not latch until the next weekly bump.
        var s = WeeklyInterpolator()
        var t = now
        for five in stride(from: 10.0, through: 70, by: 10) {
            s = s.advanced(with: snap(five: five, weekly: 50), now: t)
            t = t.addingTimeInterval(180)
        }
        s = s.advanced(with: snap(five: 75, weekly: 50), now: t + 7_200)   // hole
        #expect(s.isDegraded)
        #expect(s.value(forRaw: 50).effective >= WeeklyInterpolator.floor(of: 50))

        // The very next healthy poll measures again — degradation does not wait for a bump.
        s = s.advanced(with: snap(five: 80, weekly: 50), now: t + 7_380)
        #expect(!s.isDegraded)
        #expect(s.value(forRaw: 50).source != .degraded)
    }

    @Test func aBumpAfterAHoleReanchorsFirmly() {
        var s = WeeklyInterpolator()
        var t = now
        for five in [10.0, 20, 30, 40, 50, 60] {
            s = s.advanced(with: snap(five: five, weekly: 50), now: t)
            t = t.addingTimeInterval(180)
        }
        s = s.advanced(with: snap(five: 5, weekly: 50), now: t + 7_200)
        #expect(s.isDegraded)
        s = s.advanced(with: snap(five: 8, weekly: 51), now: t + 7_380)
        #expect(!s.isDegraded)
        #expect(s.value(forRaw: 51).source == .interpolated)
        #expect(s.value(forRaw: 51).effective == 50.5)   // firm anchor at the new bucket's edge
    }

    @Test func aWeeklyResetKeepsTheRatioWindow() {
        // The week turning over says nothing about the tier, so the estimate must survive it.
        let polls = series(polls: 300, n: 10)
        let (warm, at) = fold(polls)
        let samplesBefore = warm.ratio.sampleCount
        #expect(samplesBefore > 0)
        let afterReset = warm.advanced(with: snap(five: 5, weekly: 0), now: at + 180)
        #expect(afterReset.ratio.sampleCount == samplesBefore)
        #expect(afterReset.fiveHourSinceAnchor == 0)
    }

    @Test func aZeroLengthIntervalDoesNotPoisonTheThreshold() {
        // Seen on a real launch: a forced refresh right after the first poll records a 0 s gap. A mean
        // would drag the expected cadence down and start calling normal polls holes; the median
        // absorbs it once the window fills.
        var s = WeeklyInterpolator()
        var t = now
        s = s.advanced(with: snap(five: 10, weekly: 50), now: t)
        s = s.advanced(with: snap(five: 10, weekly: 50), now: t)      // forced refresh, 0 s later
        for five in [11.0, 12, 13, 14, 15] {
            t = t.addingTimeInterval(180)
            s = s.advanced(with: snap(five: five, weekly: 50), now: t)
        }
        #expect(!s.isDegraded)
        // The next normal-cadence poll must still read as normal, not as a hole.
        s = s.advanced(with: snap(five: 16, weekly: 50), now: t.addingTimeInterval(180))
        #expect(!s.isDegraded)
    }

    @Test func theHoleThresholdAdaptsToTheObservedCadence() {
        // A 15-minute cadence is normal, not a hole — the Pro journal mislabelled 576 of 862 samples
        // when the threshold was anchored to the 3-minute base instead.
        var s = WeeklyInterpolator()
        var t = now
        for five in [10.0, 20, 30, 40, 50, 60, 70] {
            s = s.advanced(with: snap(five: five, weekly: 50), now: t)
            t = t.addingTimeInterval(900)        // 15 min
        }
        #expect(!s.isDegraded)
    }
}

// MARK: - Applying to a snapshot

@Suite("WeeklyUtilization — applying to a snapshot")
struct WeeklyUtilizationTests {

    @Test func rewritesOnlyTheWeeklyWindow() {
        let v = WeeklyUtilization(raw: 88, effective: 88.34, source: .interpolated,
                                  ratio: 9.8, sampleCount: 12)
        let out = v.applied(to: snap(five: 40, weekly: 88))
        #expect(out.sevenDay.utilization == 88.34)
        #expect(out.fiveHour.utilization == 40)          // untouched
    }

    @Test func isANoOpAtZero() {
        // A zero window must stay exactly zero: `> 0` predicates key off it.
        let v = WeeklyUtilization(raw: 0, effective: 0.3, source: .interpolated,
                                  ratio: 10, sampleCount: 5)
        #expect(v.applied(to: snap(five: 10, weekly: 0)).sevenDay.utilization == 0)
    }

    @Test func isANoOpWhenTheAnchorDesynchronised() {
        // The snapshot no longer carries the value the interpolator measured — e.g. `optimisticReset`
        // zeroed the window locally. Without this guard the gain would land on top of a fresh zero.
        let v = WeeklyUtilization(raw: 88, effective: 88.34, source: .interpolated,
                                  ratio: 9.8, sampleCount: 12)
        #expect(v.applied(to: snap(five: 40, weekly: 0)).sevenDay.utilization == 0)
    }

    @Test func neverCarriesAValueAcrossTheExhaustionLine() {
        // The invariant that keeps every `>= 100` detector untouched.
        let polls = series(polls: 400, n: 10, startWeekly: 96)
        var s = WeeklyInterpolator()
        var t = now
        for p in polls {
            let weekly = min(100, p.weekly)
            s = s.advanced(with: snap(five: p.five, weekly: weekly), now: t)
            let v = s.value(forRaw: weekly)
            if weekly < 100 { #expect(v.effective < 100) }
            if weekly == 100 { #expect(v.effective == 100) }
            t = t.addingTimeInterval(180)
        }
    }

    @Test func anExhaustedWindowIsPassedThroughUntouched() {
        // Regression guard. Interpolating inside the top bucket lands in [99.5, 100), and every
        // exhaustion detector tests `>= 100` — so a reconstructed 99.7 would un-exhaust a blocked
        // week: no red bar, no blocking reset, no switch to credits.
        var s = WeeklyInterpolator()
        var t = now
        for five in [10.0, 20, 30, 40, 50, 60, 70] {
            s = s.advanced(with: snap(five: five, weekly: 100), now: t)
            t = t.addingTimeInterval(180)
        }
        let v = s.value(forRaw: 100)
        #expect(v.effective == 100)
        #expect(v.applied(to: snap(five: 70, weekly: 100)).sevenDay.utilization >= 100)
    }

    @Test func troubleshootLineDisclosesBothValues() {
        let v = WeeklyUtilization(raw: 88, effective: 88.34, source: .interpolated,
                                  ratio: 9.8, sampleCount: 12)
        #expect(v.troubleshootLine == "weekly: 88 % raw → 88.34 % est (N ≈ 9.8, 12 samples)")

        let clipped = WeeklyUtilization(raw: 88, effective: 88.49, source: .clipped,
                                        ratio: 9.8, sampleCount: 12)
        #expect(clipped.troubleshootLine?.hasSuffix("clipped)") == true)

        let degraded = WeeklyUtilization(raw: 88, effective: 88, source: .degraded,
                                         ratio: 9.8, sampleCount: 12)
        #expect(degraded.troubleshootLine == "weekly: 88 % raw (degraded — polling gap)")

        // Nothing to disclose when the reconstruction did not move the value.
        let identical = WeeklyUtilization(raw: 88, effective: 88, source: .interpolated,
                                          ratio: 9.8, sampleCount: 12)
        #expect(identical.troubleshootLine == nil)
    }
}

// MARK: - Persistence

@Suite("WeeklyInterpolator — persistence")
struct WeeklyPersistenceTests {

    @Test func codableRoundTrip() throws {
        let polls = series(polls: 120, n: 10)
        let (s, _) = fold(polls)
        let back = try JSONDecoder().decode(WeeklyInterpolator.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func aShortBreakKeepsTheAccumulation() {
        let polls = series(polls: 120, n: 10)
        let (s, at) = fold(polls)
        let resumed = s.resumed(at: at + 600)          // 10 min
        #expect(resumed == s)
    }

    @Test func aLongBreakKeepsTheRatioButDropsTheAccumulation() {
        // N is a property of the plan and does not spoil while the app is closed; the accumulation
        // is tied to a bucket the five-hour counter has certainly left.
        let polls = series(polls: 300, n: 10)
        let (s, at) = fold(polls)
        #expect(s.ratio.sampleCount > 0)
        let resumed = s.resumed(at: at + 30 * 86_400)   // a month away
        #expect(resumed.ratio == s.ratio)
        #expect(resumed.fiveHourSinceAnchor == 0)
        #expect(resumed.lastPollAt == nil)              // next poll inherits a fresh anchor
    }
}
