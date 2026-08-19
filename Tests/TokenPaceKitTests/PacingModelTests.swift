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

// MARK: - Ribbon length (#307)

/// The marker-less bar's ribbon length across the reachable state space, on **both** scales.
///
/// The states are the thirteen surveyed in #307's working artefact — the same `(t, u)` pairs whose
/// rendered widths the proposal was measured on. Keeping them in one table lets the two scales be
/// compared row by row:
///
/// - **window scale** (`gapEnd - gapStart` = `|u − t|`) — what the marker-less bar drew before #307.
/// - **remaining scale** (``BarLayout/pressureLength`` = `clamp((u − t)/(1 − t), 0, 1)`, i.e. the
///   ahead half of ``BarLayout/balanceOffset``) — what it draws now (ADR-0101).
///
/// `minPillFraction` is the renderer's floor expressed as a fraction of the bar: `minStripWidth`
/// is ¾ of the bar height less 1 pt (2.75 pt at the menu bar's 5 pt, #326) against a 34 pt track
/// ⇒ ~8.1 %. It is
/// duplicated here as a plain constant because the geometry that enforces it lives in the AppKit
/// target, which has no tests — see #307. A state below this floor renders as the minimum pill,
/// i.e. indistinguishable from every other state below it.
@Suite("BarLayout ribbon length")
struct RibbonLengthTests {

    /// One surveyed state: window-elapsed percent, utilisation percent, and a label matching the
    /// artefact's row so a failure names the state a human recognises.
    private struct State {
        let name: String
        let timePct: Double
        let utilPct: Double
    }

    /// The renderer inflates anything narrower than this to the minimum pill (~8.1 % of the track:
    /// `minStripWidth` 2.75 pt / `barWidth` 34 pt).
    private static let minPillFraction = 2.75 / 34

    private static let states: [State] = [
        .init(name: "Deep behind",       timePct: 80, utilPct: 30),
        .init(name: "Behind, early",     timePct: 20, utilPct: 5),
        .init(name: "Behind, mid",       timePct: 50, utilPct: 35),
        .init(name: "Behind, late",      timePct: 90, utilPct: 70),
        .init(name: "Mildly behind",     timePct: 60, utilPct: 50),
        .init(name: "Dead on pace",      timePct: 55, utilPct: 55),
        .init(name: "Mild lead, early",  timePct: 30, utilPct: 38),
        .init(name: "Mild lead, late",   timePct: 82, utilPct: 86),
        .init(name: "Ahead, mid-window", timePct: 50, utilPct: 70),
        .init(name: "Ahead, late",       timePct: 82, utilPct: 90),
        .init(name: "Ahead, very late",  timePct: 93, utilPct: 97),
        .init(name: "Exhausted, early",  timePct: 10, utilPct: 100),
        .init(name: "Exhausted",         timePct: 70, utilPct: 100),
    ]

    private static func layout(_ s: State) -> BarLayout {
        let resetsAt = now + (1.0 - s.timePct / 100) * 18_000
        return PacingModel.barLayout(
            utilization: s.utilPct, resetsAt: resetsAt, now: now, window: .fiveHour)
    }

    private static func state(_ name: String) -> State {
        states.first { $0.name == name }!
    }

    /// The window scale, pinned state by state. This is the behaviour #307 replaces for the
    /// marker-less bar; `Progress` (`.pacing`) still draws its gap on exactly these numbers, so
    /// these expectations must keep holding after the change.
    @Test func windowScaleWidthsPerState() {
        let expected: [String: Double] = [
            "Deep behind": 0.50, "Behind, early": 0.15, "Behind, mid": 0.15,
            "Behind, late": 0.20, "Mildly behind": 0.10, "Dead on pace": 0.00,
            "Mild lead, early": 0.08, "Mild lead, late": 0.04, "Ahead, mid-window": 0.20,
            "Ahead, late": 0.08, "Ahead, very late": 0.04, "Exhausted, early": 0.90,
            "Exhausted": 0.30,
        ]
        for s in Self.states {
            let l = Self.layout(s)
            #expect(abs((l.gapEnd - l.gapStart) - expected[s.name]!) < 1e-9, "\(s.name)")
        }
    }

    /// A chunk of the reachable state space renders as the minimum pill on the window scale. Among
    /// the surveyed states four do: "almost exactly on pace" and "three points from exhaustion"
    /// draw the same mark. This is the defect #307 was filed against.
    ///
    /// Was five until #326 narrowed `minStripWidth` by 1 pt: "Mildly behind" (a 10 pp gap) now clears
    /// the floor at 8.1 % where it did not at 11 %. The narrower floor swallows strictly less, so this
    /// list can only ever shrink — an entry reappearing here means the floor grew again.
    @Test func windowScaleCollapsesFourStatesIntoTheMinimumPill() {
        let collapsed = Self.states.filter { s in
            let l = Self.layout(s)
            let width = l.gapEnd - l.gapStart
            return width > 0 && width < Self.minPillFraction
        }.map(\.name)
        #expect(collapsed.sorted() == [
            "Ahead, late", "Ahead, very late", "Mild lead, early", "Mild lead, late",
        ])
    }

    /// Walking the ahead-group by increasing severity gives `8 → 4 → 20 → 8 → 4`: a wider bar does
    /// not mean a worse state, so width cannot be trusted at a glance.
    @Test func windowScaleIsNonMonotonicAcrossTheAheadGroup() {
        let widths = Self.aheadGroup.map { name -> Double in
            let l = Self.layout(Self.state(name))
            return l.gapEnd - l.gapStart
        }
        // Not ascending — and the sharpest state ends up narrowest of all.
        #expect(widths != widths.sorted())
        #expect(widths.last! < widths.first!)
    }

    /// The ahead group in order of increasing severity (later window, larger lead).
    private static let aheadGroup = [
        "Mild lead, early", "Mild lead, late", "Ahead, mid-window", "Ahead, late", "Ahead, very late",
    ]

    // MARK: - The remaining scale (#307)

    /// The renormalised scale, pinned state by state — the counterpart of
    /// ``windowScaleWidthsPerState``. **Six** of the thirteen collapse to zero: every state at or
    /// behind pace (`u ≤ t`) sits at the ribbon's zero, which is `t` itself (ADR-0101).
    @Test func remainingScaleWidthsPerState() {
        let expected: [String: Double] = [
            "Deep behind": 0.00,       // computed −2.50 — behind pace
            "Behind, early": 0.00,     // computed −0.19 — behind pace
            "Behind, mid": 0.00,       // computed −0.30 — behind pace
            "Behind, late": 0.00,      // computed −2.00 — behind pace
            "Mildly behind": 0.00,     // computed −0.25 — behind pace
            "Dead on pace": 0.00,      // u == t is the zero
            "Mild lead, early": 4.0 / 35,   // 0.1143
            "Mild lead, late": 2.0 / 9,     // 0.2222
            "Ahead, mid-window": 0.40,
            "Ahead, late": 4.0 / 9,         // 0.4444
            "Ahead, very late": 4.0 / 7,    // 0.5714
            "Exhausted, early": 1.00,
            "Exhausted": 1.00,
        ]
        for s in Self.states {
            #expect(abs(Self.layout(s).pressureLength - expected[s.name]!) < 1e-3, "\(s.name)")
        }
    }

    /// The defect from ``windowScaleIsNonMonotonicAcrossTheAheadGroup``, fixed: walking the
    /// ahead-group by increasing severity now gives a strictly widening bar, so width can be
    /// trusted at a glance.
    @Test func remainingScaleIsMonotonicAcrossTheAheadGroup() {
        let widths = Self.aheadGroup.map { Self.layout(Self.state($0)).pressureLength }
        #expect(widths == widths.sorted())
        #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 < $1 })   // strictly, no ties
    }

    /// What the renderer's floor swallows on this scale, stated honestly.
    ///
    /// The scale is **continuous through zero**, so unlike the window scale there is no clean
    /// "nothing lands in `(0, minPill)`" guarantee: a state just above the ribbon's zero has a
    /// hair-thin width and floors to the same pill as zero itself. That is correct — those states
    /// *are* essentially no pressure — but it means the pill covers a band, not a point.
    ///
    /// What matters is where the band ends: every state the model calls **`.ahead`** (the ones that
    /// ask for an action) is far clear of it, so the floor never swallows an urgent state. That is
    /// the defect ``windowScaleCollapsesFiveStatesIntoTheMinimumPill`` records for the old scale,
    /// where "three points from exhaustion" drew the minimum pill.
    @Test func theFloorOnlySwallowsCalmStates() {
        for timePct in stride(from: 1.0, through: 98.0, by: 1) {
            for utilPct in stride(from: 0.0, through: 99.0, by: 1) {
                let l = Self.layout(.init(name: "grid", timePct: timePct, utilPct: utilPct))
                guard l.pressureLength < Self.minPillFraction else { continue }
                // Anything the floor swallows must be calm — never `.ahead`.
                #expect(l.severity != .ahead, "t=\(timePct) u=\(utilPct) → \(l.pressureLength)")
            }
        }
    }

    /// **The severity bands are fixed positions on the bar**, identical at any point in the window —
    /// the property that makes width alone readable as a state. `u == t` is always the zero, and the
    /// yellow→orange crossover always `0.16` — which is `aheadThreshold` itself, because the drawn
    /// length *is* the number the colour rule compares (ADR-0101). Checked against the live
    /// threshold, not a copied constant, so a change to the colour rule fails here rather than
    /// drifting silently.
    @Test func severityThresholdsSitAtFixedWidths() {
        for timePct in [0.0, 10, 30, 50, 82, 93, 99] {
            let t = timePct / 100
            let onPace = Self.layout(.init(name: "tie", timePct: timePct, utilPct: timePct))
            #expect(onPace.pressureLength == 0, "on-pace at t=\(timePct)")

            let threshold = PacingModel.aheadThreshold(timeFraction: t)
            let atOrange = Self.layout(
                .init(name: "orange", timePct: timePct, utilPct: (t + threshold) * 100))
            #expect(abs(atOrange.pressureLength - 0.16) < 1e-9, "orange boundary at t=\(timePct)")
        }
    }

    /// **Signed, not absolute** — the property that decided #307 against the earlier `|u − t|` form.
    ///
    /// Trace an early burst followed by silence: usage frozen at 40 % while the window elapses. The
    /// ribbon must decay to zero and *stay* there. Under `|u − t| / (1 − t)` it instead bottoms out
    /// at `u == t` and climbs back to a full bar — the calmest state of the session drawing the
    /// loudest geometry.
    @Test func pressureDecaysAndDoesNotReboundWhenSpendingStops() {
        let widths = [20.0, 30, 40, 50, 60, 70, 85].map {
            Self.layout(.init(name: "frozen", timePct: $0, utilPct: 40)).pressureLength
        }
        // Monotonically non-increasing, and it ends at zero rather than rebounding.
        #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 >= $1 }, "\(widths)")
        #expect(widths.first! > 0)
        #expect(widths.last! == 0)
    }

    /// Width alone determines the colour: the bands tile without overlap. Anything the model calls
    /// `.ahead` (orange) is at or past the yellow band's top; anything at or behind pace is **exactly
    /// zero** — the ribbon's zero is `t` itself, so there is nothing between "behind" and "leading"
    /// to overlap (ADR-0101). Swept over the reachable grid.
    @Test func widthBandsDoNotOverlapAcrossTheGrid() {
        for timePct in stride(from: 1.0, through: 98.0, by: 1) {
            for utilPct in stride(from: 0.0, through: 99.0, by: 1) {
                let l = Self.layout(.init(name: "grid", timePct: timePct, utilPct: utilPct))
                if utilPct <= timePct {
                    #expect(l.pressureLength == 0, "calm t=\(timePct) u=\(utilPct)")
                }
                // The 20-min end-of-window override forces orange without a matching lead, so it is
                // excluded: this is about the dynamic threshold's own geometry.
                if l.severity == .ahead, l.remainingSeconds > PacingModel.pacingOrangeOverrideSeconds {
                    #expect(l.pressureLength >= 0.16 - 1e-9, "ahead t=\(timePct) u=\(utilPct)")
                }
            }
        }
    }

    /// `u >= 1` is a full bar for any `t`: red never shrinks. On the window scale these same two
    /// states differ (90 % vs 30 %) — a shrinking red bar that reads as "the problem is easing"
    /// while work is just as blocked.
    @Test func exhaustedAlwaysFillsTheBar() {
        for timePct in [0.0, 10, 50, 70, 99] {
            let l = Self.layout(.init(name: "exhausted", timePct: timePct, utilPct: 100))
            #expect(l.pressureLength == 1.0, "t=\(timePct)")
        }
    }

    /// `t = 1` (reset due or past) would divide by zero. There is no time left to press against, so
    /// the bar is full whatever the usage — never NaN or infinity.
    @Test func resetDueDoesNotDivideByZero() {
        for util in [0.0, 40, 100] {
            let l = PacingModel.barLayout(
                utilization: util, resetsAt: now - 1, now: now, window: .fiveHour)
            #expect(l.timeFraction == 1.0)
            #expect(l.pressureLength == 1.0, "u=\(util)")
        }
    }

    /// `usage == time` **is** the ribbon's zero, at any point in the window (ADR-0101). The
    /// renderers floor it to the minimum pill, so "dead on pace" still draws a mark rather than an
    /// empty track — but the mark is the zero, not a position a fifth of the way along.
    @Test func deadOnPaceIsTheZero() {
        for pct in [0.0, 25, 55, 90, 99] {
            let l = Self.layout(.init(name: "tie", timePct: pct, utilPct: pct))
            #expect(l.pressureLength == 0, "t=u=\(pct)")
        }
    }

    /// The ribbon's zero sits at `t`, so **everything at or behind pace collapses onto it** and the
    /// ribbon starts growing the moment usage passes time. At `t = 50 %` that boundary is `u = 50 %`
    /// exactly. This is the deliberate cost of ADR-0101 — the whole calm side shares one mark,
    /// because there the action is carried by the colour, and by ``BarStyle/balance`` for anyone who
    /// wants the surplus drawn.
    @Test func calmStatesCollapseOntoTheZeroAtTime() {
        let t = 0.50
        for (util, expectZero) in [(20.0, true), (49.0, true), (50.0, true), (50.5, false), (60.0, false)] {
            let l = Self.layout(.init(name: "calm", timePct: t * 100, utilPct: util))
            #expect((l.pressureLength == 0) == expectZero, "u=\(util) (zero at t = \(t * 100) %)")
        }
    }
}

// MARK: - balanceOffset (#326)

/// The **centred** scale: the same signed lead `pressureLength` measures, with zero moved to the
/// bar's middle so the underpace half renders at all (ADR-0079). The states are the same surveyed
/// set `RibbonLengthTests` uses, so the two scales can be compared row by row.
@Suite("BarLayout balance offset")
struct BalanceOffsetTests {

    private struct State {
        let name: String
        let timePct: Double
        let utilPct: Double
    }

    private static let states: [State] = [
        .init(name: "Deep behind",       timePct: 80, utilPct: 30),
        .init(name: "Behind, early",     timePct: 20, utilPct: 5),
        .init(name: "Behind, mid",       timePct: 50, utilPct: 35),
        .init(name: "Behind, late",      timePct: 90, utilPct: 70),
        .init(name: "Mildly behind",     timePct: 60, utilPct: 50),
        .init(name: "Dead on pace",      timePct: 55, utilPct: 55),
        .init(name: "Mild lead, early",  timePct: 30, utilPct: 38),
        .init(name: "Mild lead, late",   timePct: 82, utilPct: 86),
        .init(name: "Ahead, mid-window", timePct: 50, utilPct: 70),
        .init(name: "Ahead, late",       timePct: 82, utilPct: 90),
        .init(name: "Ahead, very late",  timePct: 93, utilPct: 97),
        .init(name: "Exhausted, early",  timePct: 10, utilPct: 100),
        .init(name: "Exhausted",         timePct: 70, utilPct: 100),
    ]

    private static func layout(_ s: State) -> BarLayout {
        let resetsAt = now + (1.0 - s.timePct / 100) * 18_000
        return PacingModel.barLayout(
            utilization: s.utilPct, resetsAt: resetsAt, now: now, window: .fiveHour)
    }

    private static let aheadGroup = [
        "Mild lead, early", "Mild lead, late", "Ahead, mid-window", "Ahead, late", "Ahead, very late",
    ]

    /// The offset of each surveyed state, pinned. Negatives are behind pace (ribbon left of centre),
    /// positives ahead (right). Note the two states the shipped scales cannot separate — "Deep
    /// behind" and "Behind, late" both saturate at `−1` here, but they at least reach the edge
    /// instead of collapsing onto the same minimum pill as "Dead on pace".
    @Test func balanceOffsetsPerState() {
        let expected: [String: Double] = [
            "Deep behind":       -1.0,      // r = −2.5, clamped
            "Behind, early":     -0.1875,
            "Behind, mid":       -0.30,
            "Behind, late":      -1.0,      // r = −2, clamped: the surplus is twice the time left
            "Mildly behind":     -0.25,
            "Dead on pace":       0.0,      // the centre — and Pressure's zero too (ADR-0101)
            "Mild lead, early":   4.0 / 35,   // 0.1143
            "Mild lead, late":    2.0 / 9,    // 0.2222
            "Ahead, mid-window":  0.40,
            "Ahead, late":        4.0 / 9,    // 0.4444
            "Ahead, very late":   4.0 / 7,    // 0.5714
            "Exhausted, early":   1.0,
            "Exhausted":          1.0,
        ]
        for s in Self.states {
            let got = Self.layout(s).balanceOffset
            #expect(abs(got - expected[s.name]!) < 1e-3, "\(s.name): \(got)")
        }
    }

    /// `u >= 1` fills the whole ahead half at any `t` — the same first-checked rule
    /// `pressureLength` has, so a spent limit never shrinks back as the reset approaches.
    @Test func exhaustedAlwaysFillsTheRightHalf() {
        for pct in [0.0, 10, 50, 70, 99] {
            let l = Self.layout(.init(name: "spent", timePct: pct, utilPct: 100))
            #expect(l.balanceOffset == 1.0, "t=\(pct)")
        }
    }

    /// The left half saturates when the surplus reaches the time remaining, i.e. `u <= 2t − 1`.
    /// Impossible before `t = 50 %`, then increasingly common — the trade-off ADR-0079 accepts,
    /// mirroring Pressure's flatness near the *start* of a window.
    ///
    /// Tested with a tolerance rather than `== −1`: `2t − 1` is not exactly representable (`1 − 0.9`
    /// is `0.09999999999999998`), so a state sitting *on* the boundary lands a few ulps short of the
    /// clamp. That is a property of the boundary, not of the formula — either side of it by any
    /// visible margin behaves as stated, and a sub-ulp difference is thousandths of a point on screen.
    @Test func deepSurplusFillsTheLeftHalf() {
        for (timePct, utilPct, expectFull) in [
            (90.0, 70.0, true),     // surplus 20 pp vs 10 pp left — twice over
            (90.0, 79.0, true),     // just past the boundary
            (90.0, 85.0, false),    // inside it
            (70.0, 40.0, true),
            (40.0, 0.0, false),     // before t = 50 % the left half cannot saturate at all
        ] {
            let o = Self.layout(.init(name: "surplus", timePct: timePct, utilPct: utilPct)).balanceOffset
            #expect((o <= -1.0 + 1e-9) == expectFull, "t=\(timePct) u=\(utilPct): \(o)")
        }
    }

    /// The acceptance criterion from #326, in its final form (ADR-0101): switching Pressure ↔ Balance
    /// cannot change what the **ahead** side says, because there is only one expression —
    /// `pressureLength` *is* `max(0, balanceOffset)`.
    ///
    /// Asserted as an exact identity over the whole reachable grid, with no epsilon: the two are the
    /// same `Double`, not two derivations that happen to agree. Before this the relationship was a
    /// constant difference of `0.20` that only held on the ahead group and had to be maintained by
    /// hand in two parallel formulas.
    @Test func pressureIsTheBalanceAheadHalf() {
        for timePct in stride(from: 1.0, through: 98.0, by: 1) {
            for utilPct in stride(from: 0.0, through: 99.0, by: 1) {
                let l = Self.layout(.init(name: "grid", timePct: timePct, utilPct: utilPct))
                #expect(l.pressureLength == max(0, l.balanceOffset), "t=\(timePct) u=\(utilPct)")
            }
        }
    }

    /// The ahead group stays strictly widening on this scale, as it does on Pressure's — width can
    /// be trusted at a glance in both styles.
    @Test func aheadHalfIsMonotonic() {
        let offsets = Self.aheadGroup.map { name -> Double in
            Self.layout(Self.states.first { $0.name == name }!).balanceOffset
        }
        #expect(offsets.allSatisfy { $0 > 0 })
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 }, "\(offsets)")
    }

    /// `u == t` is the **centre**, at any point in the window — and Pressure's zero as well, since
    /// that scale is this one's ahead half. The renderers floor the degenerate span to a centred
    /// pill so it still reads as a mark rather than an empty track.
    @Test func deadOnPaceIsTheCentre() {
        for pct in [0.0, 25, 55, 90, 99] {
            let l = Self.layout(.init(name: "tie", timePct: pct, utilPct: pct))
            #expect(abs(l.balanceOffset) < 1e-9, "t=u=\(pct)")
        }
    }

    /// A due reset (`t = 1`) would divide by zero; the guard makes it the full ahead half whatever
    /// the usage — never NaN or infinity. Mirrors `pressureLength`'s own guard.
    @Test func resetDueDoesNotDivideByZero() {
        for util in [0.0, 40, 100] {
            let l = PacingModel.barLayout(
                utilization: util, resetsAt: now - 1, now: now, window: .fiveHour)
            #expect(l.balanceOffset == 1.0, "u=\(util)")
        }
    }

    /// Across the whole reachable grid the offset stays inside `[−1, +1]` and is never NaN — the
    /// renderers map it straight onto half the track, so an out-of-range value would draw outside
    /// the bar.
    @Test func offsetStaysInRange() {
        for timePct in stride(from: 1.0, through: 98.0, by: 1.0) {
            for utilPct in stride(from: 0.0, through: 99.0, by: 1.0) {
                let o = Self.layout(.init(name: "grid", timePct: timePct, utilPct: utilPct)).balanceOffset
                #expect(!o.isNaN, "t=\(timePct) u=\(utilPct)")
                #expect(o >= -1.0 && o <= 1.0, "t=\(timePct) u=\(utilPct): \(o)")
            }
        }
    }

    /// The sign is the reading: behind pace goes left, ahead goes right, the tie is neither. Pinned
    /// across the grid because the whole style rests on it — a sign error would invert every verdict
    /// while leaving lengths plausible.
    @Test func signFollowsPacing() {
        for timePct in stride(from: 1.0, through: 98.0, by: 1.0) {
            for utilPct in stride(from: 0.0, through: 99.0, by: 1.0) {
                let l = Self.layout(.init(name: "grid", timePct: timePct, utilPct: utilPct))
                let o = l.balanceOffset
                if utilPct > timePct { #expect(o > 0, "t=\(timePct) u=\(utilPct)") }
                else if utilPct < timePct { #expect(o < 0, "t=\(timePct) u=\(utilPct)") }
                else { #expect(o == 0, "t=\(timePct) u=\(utilPct)") }
            }
        }
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
    /// defaults to a full week so the 20-minute orange override is inactive — pass a small value to
    /// exercise it. `duration` defaults to twice the default `remaining` so `elapsed = duration −
    /// remaining` is well past the 20-minute blue start override. (`isCalm` is true for both green and
    /// blue, so the exact behind-threshold here doesn't change these outcomes.)
    private static func layout(usage: Double, time: Double,
                               remaining: TimeInterval = 7 * 24 * 3600,
                               duration: Int = 14 * 24 * 3600,
                               blueAllowed: Bool = true) -> BarLayout {
        BarLayout(usageFraction: usage, timeFraction: time,
                  pacing: time >= usage ? .onPaceOrBehind : .ahead, remainingSeconds: remaining,
                  windowDurationSeconds: duration, blueAllowed: blueAllowed)
    }

    @Test func onPaceIsCalm() {   // blue (farBehind, big surplus) — still counts as calm
        #expect(BarLayoutIsCalmTests.layout(usage: 0.3, time: 0.5).isCalm)
    }

    @Test func farBehindIsCalm() {  // blue is calmer than green, so isCalm is true
        // Synthetic duration → fallback width 0.20·duration, ×2 = threshold 0.40; surplus 0.45 > 0.40.
        #expect(BarLayoutIsCalmTests.layout(usage: 0.15, time: 0.6).isCalm)
        #expect(BarLayoutIsCalmTests.layout(usage: 0.15, time: 0.6).severity == .farBehind)
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

    /// Defaults model the **5-hour** window (`duration = 18000`, so the behind-threshold is a fixed
    /// 3600/18000 = **0.20**), with `remaining = 9000` (`elapsed = 9000` — well past the 20-min blue
    /// start override). Tests pass explicit `remaining`/`duration` to exercise the override or the 7d
    /// window.
    private static func layout(usage: Double, time: Double,
                               remaining: TimeInterval = 9000,
                               duration: Int = 18_000,
                               blueAllowed: Bool = true) -> BarLayout {
        BarLayout(usageFraction: usage, timeFraction: time,
                  pacing: time >= usage ? .onPaceOrBehind : .ahead, remainingSeconds: remaining,
                  windowDurationSeconds: duration, blueAllowed: blueAllowed)
    }

    @Test func mildlyBehindIsCalm() {   // surplus 0.15 ≤ thr 0.20 (5h) → green
        #expect(BarLayoutSeverityTests.layout(usage: 0.35, time: 0.5).severity == .calm)
    }

    @Test func tieIsCalm() {     // usage == time folds into on-pace → calm (green)
        #expect(BarLayoutSeverityTests.layout(usage: 0.5, time: 0.5).severity == .calm)
    }

    // MARK: blue (farBehind) — the fixed-width split of green

    @Test func deepBehindIsFarBehind() {   // surplus 0.45 > thr 0.40 (5h) → blue
        #expect(BarLayoutSeverityTests.layout(usage: 0.05, time: 0.5).severity == .farBehind)
    }

    /// The fixed 5h boundary is 0.40 (2 h / 5 h): a surplus just below is green, just above blue.
    /// Values kept a hair off exact 0.40 to avoid float-equality noise; the strict-`>` convention is
    /// asserted in the Kit source.
    @Test func behindThresholdBoundaryIsStrict() {
        #expect(BarLayoutSeverityTests.layout(usage: 0.12, time: 0.50).severity == .calm)      // 0.38 < 0.40 → green
        #expect(BarLayoutSeverityTests.layout(usage: 0.08, time: 0.50).severity == .farBehind) // 0.42 > 0.40 → blue
    }

    /// The 7-day window has a different fixed width (2 d / 7 d ≈ 0.2857) than the 5-hour one (0.40),
    /// so the same surplus can be green on the 5h window and blue on the 7d one.
    @Test func thresholdDiffersPerWindow() {
        // surplus 0.35: green on 5h (thr 0.40), blue on 7d (thr ≈0.2857).
        #expect(BarLayoutSeverityTests.layout(usage: 0.15, time: 0.50).severity == .calm)      // 5h defaults
        let sevenD = BarLayoutSeverityTests.layout(usage: 0.15, time: 0.50,
                                                   remaining: 302_400, duration: 604_800)
        #expect(sevenD.severity == .farBehind)   // surplus 0.35 > 0.2857
    }

    /// `blueAllowed: false` (the weekly gate closed, or an inert/non-token bar) forces the behind side
    /// to plain green at any surplus — the early exit that replaced `FarBehindInterval.off`.
    @Test func blueAllowedFalseKeepsBehindGreen() {
        #expect(BarLayoutSeverityTests.layout(usage: 0.05, time: 0.5).severity == .farBehind)
        #expect(BarLayoutSeverityTests.layout(usage: 0.05, time: 0.5, blueAllowed: false).severity == .calm)
    }

    // MARK: 20-minute blue start override

    /// Within the first 20 min of the window, a deep surplus is still plain green (blue must not
    /// flicker at start). elapsed = duration − remaining = 1200 here → green.
    @Test func startOverrideForcesGreen() {
        let l = BarLayoutSeverityTests.layout(usage: 0.0, time: 0.5, remaining: 18000 - 1200, duration: 18000)
        #expect(l.severity == .calm)
    }

    /// Just past the start override (elapsed 1201 s), the same deep surplus becomes blue.
    @Test func justPastStartOverrideIsFarBehind() {
        let l = BarLayoutSeverityTests.layout(usage: 0.0, time: 0.5, remaining: 18000 - 1201, duration: 18000)
        #expect(l.severity == .farBehind)
    }

    /// The start override touches only the on-pace/behind side — the ahead grading is unaffected
    /// early in the window (a real lead early on still grades by the ahead-threshold).
    @Test func startOverrideDoesNotAffectAheadSide() {
        // 10 pts ahead at t=0.02, well within 20 min; ahead-threshold ≈ 0.157 so this is still yellow
        // (calm) by the ahead formula — proving the start override didn't reclassify the ahead side.
        let l = BarLayoutSeverityTests.layout(usage: 0.12, time: 0.02, remaining: 18000 - 300, duration: 18000)
        #expect(l.severity == .calm)   // yellow, via the ahead-threshold — not touched by the blue override
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

    /// The near-reset **orange** override is on the ahead side only: it never outranks the on-pace/behind
    /// branch (a big surplus here is `.farBehind`, not orange) nor exhaustion (which stays red). elapsed
    /// (= 18000 − 60) is past the 20-min start override, so the deep surplus grades to blue by the
    /// fixed-width behind-threshold (0.40 for 5h; surplus 0.55 > 0.40).
    @Test func overrideDoesNotOutrankPaceOrExhaustion() {
        #expect(BarLayoutSeverityTests.layout(usage: 0.05, time: 0.6, remaining: 60).severity == .farBehind)
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

// MARK: - PacingModel.behindThreshold

@Suite("PacingModel.behindThreshold")
struct BehindThresholdTests {

    /// The shipped fixed width: 2 h / 5 h = 0.40, 2 d / 7 d ≈ 0.2857.
    @Test func fixedWidthPerWindow() {
        #expect(abs(PacingModel.behindThreshold(windowDurationSeconds: 18_000) - 0.40) < 1e-9)   // 2·3600/18000
        #expect(abs(PacingModel.behindThreshold(windowDurationSeconds: 604_800) - (172_800.0 / 604_800.0)) < 1e-9)
    }

    /// The multiplier is a fixed constant now, not a user setting — pin it so a silent change to the
    /// shipped width fails here rather than in someone's menu bar.
    @Test func widthMultiplierIsFixedAtTwo() {
        #expect(PacingModel.farBehindWidthMultiplier == 2)
        #expect(abs(PacingModel.behindThreshold(windowDurationSeconds: 18_000)
                    - Double(3600 * PacingModel.farBehindWidthMultiplier) / 18_000.0) < 1e-9)
    }

    /// It answers only **how wide** the blue zone is, never **whether** it applies (that is
    /// `BarLayout.blueAllowed`), so it always returns a finite, comparable width.
    @Test func alwaysFinite() {
        #expect(PacingModel.behindThreshold(windowDurationSeconds: 18_000) < .greatestFiniteMagnitude)
        #expect(PacingModel.behindThreshold(windowDurationSeconds: 604_800) < .greatestFiniteMagnitude)
    }

    /// Unlike `aheadThreshold`, it does NOT depend on how far the window has elapsed — same value
    /// regardless of timeFraction (the input is the window length, not the elapsed fraction).
    @Test func independentOfElapsedTime() {
        // Both computed from the 5-hour duration → identical, no timeFraction term.
        let a = PacingModel.behindThreshold(windowDurationSeconds: 18_000)
        let b = PacingModel.behindThreshold(windowDurationSeconds: 18_000)
        #expect(a == b)
        #expect(abs(a - 0.40) < 1e-9)
    }

    /// Non-positive duration (inert placeholder bars) returns 0 — any surplus reads as the calmer green.
    @Test func nonPositiveDurationIsZero() {
        #expect(PacingModel.behindThreshold(windowDurationSeconds: 0) == 0)
        #expect(PacingModel.behindThreshold(windowDurationSeconds: -1) == 0)
    }
}

// MARK: - standBySecondsForGreen

/// A seven-day bar at the given usage/elapsed fractions, far enough from its reset that the 20-minute
/// end-of-window override never fires unless a test asks for it.
private func weekly(usage u: Double, elapsed t: Double,
                    remaining: TimeInterval? = nil) -> BarLayout {
    let d = LimitWindow.sevenDay.durationSeconds
    return BarLayout(
        usageFraction: u,
        timeFraction: t,
        pacing: t >= u ? .onPaceOrBehind : .ahead,
        remainingSeconds: remaining ?? Double(d) * (1 - t),
        windowDurationSeconds: d)
}

@Suite("PacingModel.standBySecondsForGreen")
struct StandBySecondsForGreenTests {

    /// The wait is the lead converted back into window time — no threshold coefficient involved.
    /// u = 45 %, t = 30 % → 604 800 · 0.15 ≈ 25.2 h. (The lead must clear `aheadThreshold` — 0.112 at
    /// this point in the window — or the bar would be yellow and offer no wait at all.)
    @Test func waitIsTheLeadInWindowSeconds() {
        let bar = weekly(usage: 0.45, elapsed: 0.30)
        #expect(bar.severity == .ahead)
        let standBy = try! #require(PacingModel.standBySecondsForGreen(bar))
        #expect(abs(standBy - 604_800 * 0.15) < 1e-6)
    }

    /// **The invariant that pins this to the real colour.** Applying the returned wait must land the
    /// bar on the *green* side (`usage <= time`), and a minute less must not.
    ///
    /// Deliberately asserts on `pacing`, NOT on `severity == .calm`: `.calm` covers green **and**
    /// yellow, so a `.calm` assertion would also pass for a wait that only reaches yellow — exactly
    /// the under-report this function must never make.
    @Test func waitingExactlyThatLongReachesGreen() {
        let u = 0.42, t = 0.25
        let bar = weekly(usage: u, elapsed: t)
        let standBy = try! #require(PacingModel.standBySecondsForGreen(bar))
        let d = Double(LimitWindow.sevenDay.durationSeconds)

        // Having waited the full amount: green (the calm side), not merely `.calm`.
        let after = weekly(usage: u, elapsed: t + standBy / d)
        #expect(after.pacing == .onPaceOrBehind)

        // One minute short: still ahead of pace.
        let justBefore = weekly(usage: u, elapsed: t + (standBy - 60) / d)
        #expect(justBefore.pacing == .ahead)
    }

    /// A **yellow** bar (ahead, but by less than `aheadThreshold`) is not orange, so there is no line
    /// and no wait. This is the regression guard against `0.16` creeping back into the formula: a
    /// severity-based solve would return a value here.
    @Test func yellowOffersNoWait() {
        // t = 0.50 → threshold 0.08; a 0.05 lead stays yellow.
        let bar = weekly(usage: 0.55, elapsed: 0.50)
        #expect(bar.severity == .calm)
        #expect(PacingModel.standBySecondsForGreen(bar) == nil)
    }

    /// Green, and deep-behind blue, have nothing to wait out.
    @Test func calmSidesOfferNoWait() {
        #expect(PacingModel.standBySecondsForGreen(weekly(usage: 0.20, elapsed: 0.30)) == nil)  // green
        #expect(PacingModel.standBySecondsForGreen(weekly(usage: 0.10, elapsed: 0.60)) == nil)  // blue
    }

    /// Exhausted (red) is cleared by the reset alone: usage is pinned at the ceiling, so the clock can
    /// never catch up to it.
    @Test func exhaustedOffersNoWait() {
        let bar = weekly(usage: 1.0, elapsed: 0.40)
        #expect(bar.severity == .exhausted)
        #expect(PacingModel.standBySecondsForGreen(bar) == nil)
    }

    /// Inside the last 20 minutes the bar is orange whatever the lead (`pacingOrangeOverrideSeconds`),
    /// so green is unreachable and no wait is offered — even for a tiny lead.
    @Test func endOfWindowOverrideOffersNoWait() {
        let bar = weekly(usage: 0.99, elapsed: 0.985, remaining: 900)   // 15 min left
        #expect(bar.severity == .ahead)
        #expect(PacingModel.standBySecondsForGreen(bar) == nil)
    }

    /// A wait that would end inside that same 20-minute band is refused too — the check looks at the
    /// remaining time *on arrival*, not at the present moment.
    @Test func waitLandingInsideTheOverrideIsRefused() {
        // 40 min left, and the lead needs 30 min to clear → arrival has only 10 min left: still orange.
        let d = Double(LimitWindow.sevenDay.durationSeconds)
        let bar = weekly(usage: 0.996 + 1800 / d, elapsed: 0.996, remaining: 2400)
        #expect(bar.severity == .ahead)
        #expect(PacingModel.standBySecondsForGreen(bar) == nil)
    }
}

// MARK: - displayableStandBySecondsForGreen

@Suite("PacingModel.displayableStandBySecondsForGreen")
struct DisplayableStandByTests {

    /// A wait comfortably above the floor and far from the reset is shown as-is.
    @Test func comfortableWaitIsShown() {
        let bar = weekly(usage: 0.45, elapsed: 0.30)
        let shown = try! #require(PacingModel.displayableStandBySecondsForGreen(bar))
        #expect(abs(shown - 604_800 * 0.15) < 1e-6)
    }

    /// Under 20 minutes it is noise on a seven-day window — the bar greens on its own while the user
    /// is still reading. The raw arithmetic still returns it; only the display policy drops it.
    @Test func waitBelowTheFloorIsHidden() {
        let d = Double(LimitWindow.sevenDay.durationSeconds)
        // Late in the window (t = 99.5 %) `aheadThreshold` is only ~8 min of window time, so a 15-min
        // lead is genuinely orange — the one region where a sub-20-minute wait can exist at all.
        let bar = weekly(usage: 0.995 + 900 / d, elapsed: 0.995)
        #expect(bar.severity == .ahead)
        #expect(PacingModel.standBySecondsForGreen(bar) != nil)   // the arithmetic still answers
        #expect(PacingModel.displayableStandBySecondsForGreen(bar) == nil)   // policy drops it
    }

    /// Exactly at the floor it is shown (the comparison is `>=`).
    @Test func waitExactlyAtTheFloorIsShown() {
        let d = Double(LimitWindow.sevenDay.durationSeconds)
        // t = 99 % → `aheadThreshold` is ~16 min of window time, so a 20-min lead is orange and the
        // wait lands just on the floor. Comparison is `>=`, so it is shown.
        //
        // The lead is nudged a second past the floor rather than set exactly on it: `usage` can only
        // be expressed as a fraction, and `floor / d` does not round-trip back to exactly `floor`
        // seconds. Testing the boundary to sub-second precision would be testing `Double`, not the
        // policy — `waitBelowTheFloorIsHidden` already covers the reject side.
        let bar = weekly(usage: 0.99 + (PacingModel.standByFloorSeconds + 1) / d, elapsed: 0.99)
        #expect(bar.severity == .ahead)
        let shown = try! #require(PacingModel.displayableStandBySecondsForGreen(bar))
        #expect(abs(shown - PacingModel.standByFloorSeconds) < 2.0)
    }

    /// "Green arrives about when the window resets anyway" is never shown — but that is enforced by
    /// the 20-minute end-of-window check inside `standBySecondsForGreen`, not by a second rule here.
    ///
    /// This pins the reasoning: every wait that survives is already more than 20 min clear of the
    /// reset, so it is necessarily more than 10 min clear too. A separate proximity threshold could
    /// not reject anything — it would be dead code.
    @Test func survivingWaitsAreAlwaysWellClearOfTheReset() {
        let d = Double(LimitWindow.sevenDay.durationSeconds)
        for elapsed in [0.30, 0.60, 0.90, 0.99] {
            for leadPoints in [0.02, 0.05, 0.15, 0.40] {
                let bar = weekly(usage: min(0.999, elapsed + leadPoints), elapsed: elapsed)
                guard let standBy = PacingModel.displayableStandBySecondsForGreen(bar) else { continue }
                // Green lands with the whole override band still to spare — hence also the 10 min.
                #expect(bar.remainingSeconds - standBy > PacingModel.pacingOrangeOverrideSeconds)
                #expect(bar.remainingSeconds - standBy > 600)
                _ = d
            }
        }
    }

    /// A lead so large that the window resets first: the reset, not the pause, is what fixes it.
    @Test func waitOutlastingTheWindowIsHidden() {
        let d = Double(LimitWindow.sevenDay.durationSeconds)
        let bar = weekly(usage: 0.60, elapsed: 0.10, remaining: d * 0.20)   // needs 0.50·d, has 0.20·d
        #expect(PacingModel.displayableStandBySecondsForGreen(bar) == nil)
    }

    /// The noise floor is the shipped one — a silent change fails here, not in the popup.
    @Test func policyConstantsArePinned() {
        #expect(PacingModel.standByFloorSeconds == 1200)            // 20 min
    }
}
