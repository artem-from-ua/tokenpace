import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Shared fixtures

/// A fixed "current time" so the reset countdown is deterministic.
private let now = Date(timeIntervalSince1970: 1_000_000)

/// An ISO-8601 `resets_at` string `seconds` in the future relative to ``now`` — the same shape the
/// API emits (the microsecond fraction is irrelevant to `ResetClock.parse`, which strips it).
private func resetsAt(inSeconds seconds: TimeInterval) -> String {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    return iso.string(from: now.addingTimeInterval(seconds))
}

/// A snapshot with explicit utilisations and resets, defaulting both windows to a far-off reset
/// (well over 90 min) so the countdown is the absolute branch unless a test overrides it.
private func snapshot(
    fiveHourUtil: Double,
    sevenDayUtil: Double,
    fiveHourResetsIn: TimeInterval = 4 * 3600,
    sevenDayResetsIn: TimeInterval = 3 * 24 * 3600
) -> UsageSnapshot {
    UsageSnapshot(
        fiveHour: UsageWindow(utilization: fiveHourUtil, resetsAt: resetsAt(inSeconds: fiveHourResetsIn)),
        sevenDay: UsageWindow(utilization: sevenDayUtil, resetsAt: resetsAt(inSeconds: sevenDayResetsIn))
    )
}

/// A **session-idle** snapshot (#100): the 5h window does not exist (`utilization: 0`, `resetsAt: ""`,
/// `sessionIdle: true`); the 7-day window is normal, `sevenDayResetsIn` seconds out.
private func idleSnapshot(
    sevenDayUtil: Double = 31,
    sevenDayResetsIn: TimeInterval = 4 * 24 * 3600
) -> UsageSnapshot {
    UsageSnapshot(
        fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
        sevenDay: UsageWindow(utilization: sevenDayUtil, resetsAt: resetsAt(inSeconds: sevenDayResetsIn)),
        sessionIdle: true
    )
}

// MARK: - always expanded (no idle/compact mode — ADR-0014)

@Suite("MenuBarLayout.make")
struct MenuBarLayoutMakeTests {

    @Test func bothWindowsLowStillExpands() {
        // Even with both windows near zero the widget shows the full bars — there is no idle
        // collapse to a glyph (the bug: a just-reset state showed a `*` while Claude was in use).
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 2, sevenDayUtil: 1), now: now)
        guard case .expanded = layout.mode else {
            Issue.record("expected .expanded for low utilisation, got \(layout.mode)")
            return
        }
    }

    @Test func zeroUtilizationStillExpands() {
        // 0 % with a VALID resets_at is an active-but-empty window, NOT session-idle — both bars are
        // normal (the idle state is API-driven by a missing reset, not by a low utilisation; ADR-0027).
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 0, sevenDayUtil: 0), now: now)
        guard case let .expanded(five, _, _, _) = layout.mode else {
            Issue.record("expected .expanded at 0%, got \(layout.mode)")
            return
        }
        #expect(!five.idle)
    }

    @Test func highUtilizationExpands() {
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 12, sevenDayUtil: 40), now: now)
        guard case .expanded = layout.mode else {
            Issue.record("expected .expanded, got \(layout.mode)")
            return
        }
    }
}

// MARK: - expanded content

@Suite("MenuBarLayout expanded content")
struct MenuBarLayoutExpandedTests {

    /// Pull the associated values out of an expanded mode, or fail the test.
    private func expanded(
        _ layout: MenuBarLayout
    ) -> (five: BarView, seven: BarView, reset: TimeToReset, which: LimitWindow)? {
        guard case let .expanded(five, seven, reset, which) = layout.mode else {
            Issue.record("expected .expanded, got \(layout.mode)")
            return nil
        }
        return (five, seven, reset, which)
    }

    @Test func barsCarryTheirWindows() {
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30), now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.five.window == .fiveHour)
        #expect(e.seven.window == .sevenDay)
        #expect(!e.five.idle && !e.seven.idle)   // normal path — neither bar is idle
    }

    @Test func barLayoutMatchesPacingModel() {
        // The view's geometry must be exactly what PacingModel produces — no re-derivation.
        let snap = snapshot(fiveHourUtil: 50, sevenDayUtil: 30, fiveHourResetsIn: 4 * 3600)
        let layout = MenuBarLayout.make(from: snap, now: now)
        guard let e = expanded(layout) else { return }

        let expectedFive = PacingModel.barLayout(
            utilization: 50,
            resetsAt: ResetClock.parse(snap.fiveHour.resetsAt)!,
            now: now,
            window: .fiveHour
        )
        #expect(e.five.layout == expectedFive)
    }

    @Test func resetMatchesResetClock() {
        // `which`/`reset` must equal a direct ResetClock.resetDisplay call on the same inputs.
        let snap = snapshot(
            fiveHourUtil: 50, sevenDayUtil: 30,
            fiveHourResetsIn: 30 * 60,        // 30 min → nearest, relative branch
            sevenDayResetsIn: 3 * 24 * 3600
        )
        let layout = MenuBarLayout.make(from: snap, now: now)
        guard let e = expanded(layout) else { return }

        let expected = ResetClock.resetDisplay(
            fiveHourResetsAt: snap.fiveHour.resetsAt,
            sevenDayResetsAt: snap.sevenDay.resetsAt,
            now: now
        )!
        #expect(e.which == expected.which)
        #expect(e.reset == expected.display)
        #expect(e.which == .fiveHour)                 // 5h resets first here
    }

    @Test func criticalUtilizationSurfacesIndicator() {
        // utilisation == 100 → .critical on that bar (PacingModel), and the widget is expanded.
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 100, sevenDayUtil: 30), now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.five.indicator == .critical)
    }

    @Test func unparseableResetsFallBackToResetNow() {
        // Both resets_at malformed → resetDisplay returns nil → fallback (.fiveHour, .resetNow).
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 50, resetsAt: "garbage"),
            sevenDay: UsageWindow(utilization: 30, resetsAt: "null")
        )
        let layout = MenuBarLayout.make(from: snap, now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.reset == .resetNow)
        #expect(e.which == .fiveHour)
    }

    @Test func missingPerModelWindowsDoNotBreakLayout() {
        // seven_day_opus / _sonnet absent (the common case) — layout still builds.
        let snap = snapshot(fiveHourUtil: 50, sevenDayUtil: 30)
        #expect(snap.sevenDayOpus == nil && snap.sevenDaySonnet == nil)
        let layout = MenuBarLayout.make(from: snap, now: now)
        #expect(expanded(layout) != nil)
    }
}

// MARK: - session-idle (#100, ADR-0027)

@Suite("MenuBarLayout session-idle")
struct MenuBarLayoutIdleTests {

    private func expanded(
        _ layout: MenuBarLayout
    ) -> (five: BarView, seven: BarView, reset: TimeToReset, which: LimitWindow)? {
        guard case let .expanded(five, seven, reset, which) = layout.mode else {
            Issue.record("expected .expanded, got \(layout.mode)")
            return nil
        }
        return (five, seven, reset, which)
    }

    @Test func idleKeepsBothBarsExpanded() {
        // The bars never collapse (ADR-0015 stands): idle is still `.expanded`, only the 5h bar is idle.
        let layout = MenuBarLayout.make(from: idleSnapshot(), now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.five.idle)
        #expect(!e.seven.idle)
        #expect(e.five.window == .fiveHour)
        #expect(e.seven.window == .sevenDay)
    }

    @Test func idleFiveHourLayoutIsInertZeroed() {
        // The idle bar's geometry is an explicit zero — never derived from the empty resets_at (which
        // would pin elapsed to 1.0). Usage 0, time 0, on-pace, neutral.
        let layout = MenuBarLayout.make(from: idleSnapshot(), now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.five.layout.usageFraction == 0)
        #expect(e.five.layout.timeFraction == 0)
        #expect(e.five.indicator == .neutral)
    }

    @Test func idleResetIsSevenDayInCompactDays() {
        // 7-day reset 4 days out → the reset label is the 7-day one, rendered as "4d".
        let layout = MenuBarLayout.make(from: idleSnapshot(sevenDayResetsIn: 4 * 24 * 3600), now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.which == .sevenDay)
        #expect(e.reset == .relative("4d"))
    }

    @Test func idleResetWithin24hIsAbsolute() {
        // 7-day reset < 24 h out → falls through to the absolute wall-clock time (not a day count).
        let layout = MenuBarLayout.make(from: idleSnapshot(sevenDayResetsIn: 5 * 3600), now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.which == .sevenDay)
        let expected = ResetClock.timeToResetCompactDays(
            resetsAt: now.addingTimeInterval(5 * 3600), now: now)
        #expect(e.reset == expected)
        if case .absolute = e.reset {} else { Issue.record("expected .absolute, got \(e.reset)") }
    }

    @Test func idleWithUnparseableSevenDayResetIsResetNow() {
        // A blank/unparseable 7-day resets_at with an idle 5h window → the countdown is .resetNow
        // (the view shows ⏰), never a phantom.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 31, resetsAt: ""),
            sessionIdle: true)
        let layout = MenuBarLayout.make(from: snap, now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.reset == .resetNow)
        #expect(e.which == .sevenDay)
    }

    @Test func idleSnapshotStalePhaseCarriesIdleBar() {
        // The idle 5h bar rides through the 30–60 min stale error phase unchanged (issue #12 reuse).
        let health = UsageHealth(
            lastSuccess: now.addingTimeInterval(-31 * 60),
            failingSince: now.addingTimeInterval(-31 * 60),
            reason: .notSignedIn)
        let layout = MenuBarLayout.make(from: idleSnapshot(), health: health, now: now)
        guard case let .error(five, seven, reset, which) = layout.mode else {
            Issue.record("expected .error with bars, got \(layout.mode)")
            return
        }
        #expect(five?.idle == true)
        #expect(seven != nil && reset != nil && which == .sevenDay)
    }
}

// MARK: - health-aware make (error phases, issue #12)

@Suite("MenuBarLayout.make health-aware")
struct MenuBarLayoutHealthTests {

    /// A representative snapshot (the healthy/stale path is `.expanded`).
    private let snap = UsageSnapshot(
        fiveHour: UsageWindow(utilization: 50, resetsAt: resetsAt(inSeconds: 4 * 3600)),
        sevenDay: UsageWindow(utilization: 30, resetsAt: resetsAt(inSeconds: 3 * 24 * 3600))
    )

    /// A health value failing for `age` seconds (with a matching last success in the past).
    private func failing(for age: TimeInterval) -> UsageHealth {
        UsageHealth(
            lastSuccess: now.addingTimeInterval(-age),
            failingSince: now.addingTimeInterval(-age),
            reason: .notSignedIn
        )
    }

    private func isError(_ layout: MenuBarLayout) -> Bool {
        if case .error = layout.mode { return true }
        return false
    }

    @Test func healthyDelegatesToPlainMake() {
        // Healthy health-aware make must equal the plain make on the same snapshot.
        let viaHealth = MenuBarLayout.make(from: snap, health: .healthy(lastSuccess: now), now: now)
        let plain = MenuBarLayout.make(from: snap, now: now)
        #expect(viaHealth == plain)
    }

    @Test func failingWithinGraceShowsBarsNotError() {
        // 10 min of failure → still the stale bars, no ⚠️ (the popup warns instead).
        let layout = MenuBarLayout.make(from: snap, health: failing(for: 10 * 60), now: now)
        #expect(!isError(layout))
        guard case .expanded = layout.mode else {
            Issue.record("expected .expanded, got \(layout.mode)")
            return
        }
    }

    @Test func exactlyThirtyMinutesStillShowsBars() {
        // Boundary: at exactly 30:00 the glyph has NOT appeared yet (`age <= glyphAfter`).
        let layout = MenuBarLayout.make(from: snap, health: failing(for: UsageHealth.glyphAfter), now: now)
        #expect(!isError(layout))
    }

    @Test func pastThirtyMinutesIsErrorWithBars() {
        // 31 min → ⚠️ + stale bars (the error case carries the bars).
        let layout = MenuBarLayout.make(from: snap, health: failing(for: 31 * 60), now: now)
        guard case let .error(five, seven, reset, which) = layout.mode else {
            Issue.record("expected .error, got \(layout.mode)")
            return
        }
        #expect(five != nil && seven != nil && reset != nil && which != nil)
    }

    @Test func exactlySixtyMinutesStillKeepsBars() {
        // Boundary: at exactly 60:00 the bars are still kept (`age <= hideBarsAfter`).
        let layout = MenuBarLayout.make(from: snap, health: failing(for: UsageHealth.hideBarsAfter), now: now)
        guard case let .error(five, _, _, _) = layout.mode else {
            Issue.record("expected .error, got \(layout.mode)")
            return
        }
        #expect(five != nil)
    }

    @Test func pastSixtyMinutesDropsBars() {
        // 61 min → ⚠️ alone (the data is too stale to show).
        let layout = MenuBarLayout.make(from: snap, health: failing(for: 61 * 60), now: now)
        guard case let .error(five, seven, reset, which) = layout.mode else {
            Issue.record("expected .error, got \(layout.mode)")
            return
        }
        #expect(five == nil && seven == nil && reset == nil && which == nil)
    }

    @Test func coldStartFailingIsErrorWithoutBars() {
        // No snapshot ever decoded → ⚠️ alone regardless of how short the failure has been.
        let health = UsageHealth(lastSuccess: nil, failingSince: now.addingTimeInterval(-60), reason: .notSignedIn)
        let layout = MenuBarLayout.make(from: nil, health: health, now: now)
        guard case let .error(five, _, _, _) = layout.mode else {
            Issue.record("expected .error, got \(layout.mode)")
            return
        }
        #expect(five == nil)
    }

    @Test func coldStartHealthyIsBareError() {
        // No snapshot and not failing (the instant before the first poll completes) → the bare ⚠️
        // error glyph (no data to draw), not a compact glyph. No crash.
        let layout = MenuBarLayout.make(from: nil, health: .healthy(lastSuccess: now), now: now)
        #expect(layout.mode == .error(fiveHour: nil, sevenDay: nil, reset: nil, which: nil))
    }
}

// MARK: - Service problem dot (#31)

@Suite("MenuBarLayout serviceProblem")
struct MenuBarLayoutServiceProblemTests {

    private let snap = UsageSnapshot(
        fiveHour: UsageWindow(utilization: 50, resetsAt: resetsAt(inSeconds: 4 * 3600)),
        sevenDay: UsageWindow(utilization: 30, resetsAt: resetsAt(inSeconds: 3 * 24 * 3600)))

    @Test func nilByDefault() {
        let layout = MenuBarLayout.make(from: snap, health: .healthy(lastSuccess: now), now: now)
        #expect(layout.serviceProblem == nil)
    }

    @Test func threadedThroughHealthyPath() {
        let layout = MenuBarLayout.make(
            from: snap, health: .healthy(lastSuccess: now), now: now, serviceProblem: .degraded)
        #expect(layout.serviceProblem == .degraded)
        // The usage mode is unaffected by the service problem.
        if case .expanded = layout.mode {} else { Issue.record("expected expanded mode") }
    }

    @Test func threadedThroughErrorPath() {
        // A long-failing usage poll → error mode; the service dot still rides along.
        let failing = UsageHealth(
            lastSuccess: now.addingTimeInterval(-2 * 3600),
            failingSince: now.addingTimeInterval(-2 * 3600), reason: .timeout)
        let layout = MenuBarLayout.make(
            from: nil, health: failing, now: now, serviceProblem: .majorOutage)
        #expect(layout.serviceProblem == .majorOutage)
        if case .error = layout.mode {} else { Issue.record("expected error mode") }
    }
}
