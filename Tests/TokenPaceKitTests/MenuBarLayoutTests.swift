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
        guard case let .expanded(five, _, _) = layout.mode else {
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

    /// Pull the associated values out of an expanded mode, or fail the test. `seven` is optional —
    /// `nil` when the calm 7-day bar was hidden (#94); the default `hideCalmSevenDay: false` keeps it.
    private func expanded(
        _ layout: MenuBarLayout
    ) -> (five: BarView, seven: BarView?, resetToShow: ResetToShow?)? {
        guard case let .expanded(five, seven, resetToShow) = layout.mode else {
            Issue.record("expected .expanded, got \(layout.mode)")
            return nil
        }
        return (five, seven, resetToShow)
    }

    @Test func barsCarryTheirWindows() {
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30), now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.five.window == .fiveHour)
        #expect(e.seven?.window == .sevenDay)
        #expect(!e.five.idle && !(e.seven?.idle ?? true))   // normal path — neither bar is idle
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

    @Test func alwaysModeShowsNearestReset() {
        // In `.always` both bars are calm here (50%/30% behind pace), so the countdown is the nearest
        // reset — it must equal a direct ResetClock.resetDisplay call on the same inputs.
        let snap = snapshot(
            fiveHourUtil: 50, sevenDayUtil: 30,
            fiveHourResetsIn: 30 * 60,        // 30 min → nearest, relative branch
            sevenDayResetsIn: 3 * 24 * 3600
        )
        let layout = MenuBarLayout.make(from: snap, now: now, resetMode: .always)
        guard let e = expanded(layout), let r = e.resetToShow else {
            Issue.record("expected a countdown in .always mode"); return
        }
        let expected = ResetClock.resetDisplay(
            fiveHourResetsAt: snap.fiveHour.resetsAt,
            sevenDayResetsAt: snap.sevenDay.resetsAt,
            now: now
        )!
        #expect(r.which == expected.which)
        #expect(r.display == expected.display)
        #expect(r.which == .fiveHour)                 // 5h resets first here
    }

    @Test func bothCalmHidesResetByDefault() {
        // Default mode (.smart): 50%/30% both behind pace → both calm → no countdown.
        let snap = snapshot(fiveHourUtil: 50, sevenDayUtil: 30,
                            fiveHourResetsIn: 30 * 60, sevenDayResetsIn: 3 * 24 * 3600)
        let layout = MenuBarLayout.make(from: snap, now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.resetToShow == nil)
    }

    @Test func criticalUtilizationSurfacesIndicator() {
        // utilisation == 100 → .critical on that bar (PacingModel), and the widget is expanded.
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 100, sevenDayUtil: 30), now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.five.indicator == .critical)
    }

    @Test func bothActiveResetsUnparseableIsError() {
        // Both windows report real usage (50/30) but both `resets_at` are malformed → an API data error
        // on active windows → the ⚠️ error state, not a silently-dropped countdown (#167, ADR-0041).
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 50, resetsAt: "garbage"),
            sevenDay: UsageWindow(utilization: 30, resetsAt: "null")
        )
        if case .error = MenuBarLayout.make(from: snap, now: now, resetMode: .always).mode {} else {
            Issue.record("expected .error when both active windows have broken resets")
        }
    }

    @Test func missingPerModelWindowsDoNotBreakLayout() {
        // seven_day_opus / _sonnet absent (the common case) — layout still builds.
        let snap = snapshot(fiveHourUtil: 50, sevenDayUtil: 30)
        #expect(snap.sevenDayOpus == nil && snap.sevenDaySonnet == nil)
        let layout = MenuBarLayout.make(from: snap, now: now)
        #expect(expanded(layout) != nil)
    }

    @Test func activeWindowWithBrokenResetIsError() {
        // #167/ADR-0041 (case B): an **active** window (real usage) whose `resets_at` is unparseable is
        // a malformed payload → the menu bar shows the ⚠️ error state (glyph + last bars), NOT a
        // fabricated countdown. `make` checks the raw parse result (`hasBrokenReset`) *before*
        // `bar(for:)` masks the nil date as `elapsedFraction == 1.0` / `.calm`.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 100, resetsAt: "garbage"),
            sevenDay: UsageWindow(utilization: 30, resetsAt: resetsAt(inSeconds: 3 * 24 * 3600))
        )
        let layout = MenuBarLayout.make(from: snap, now: now, resetMode: .always)
        guard case let .error(five, _, reset, _) = layout.mode else {
            Issue.record("expected .error for an active window with a broken reset, got \(layout.mode)")
            return
        }
        #expect(five != nil)     // the last bars are kept beside the ⚠️
        #expect(reset == nil)    // no fabricated countdown
    }

    @Test func brokenResetOn7dActiveWindowIsError() {
        // The 7-day window is the one with the broken date (5h is fine) → still promoted to ⚠️.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 40, resetsAt: resetsAt(inSeconds: 2 * 3600)),
            sevenDay: UsageWindow(utilization: 55, resetsAt: "null")
        )
        if case .error = MenuBarLayout.make(from: snap, now: now).mode {} else {
            Issue.record("expected .error when the 7-day window's reset is broken")
        }
    }

    @Test func zeroUsageWindowWithNoResetIsNotError() {
        // A **zero-usage** window with an unparseable/absent reset is NOT an error (nothing to reset
        // yet) — only real usage + a broken date is. Stays `.expanded`.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: "null"),
            sevenDay: UsageWindow(utilization: 30, resetsAt: resetsAt(inSeconds: 3 * 24 * 3600))
        )
        #expect(expanded(MenuBarLayout.make(from: snap, now: now)) != nil)
    }

    @Test func idlePathValidSevenStaysExpanded() {
        // Idle 5h + a valid 7-day reset stays `.expanded` (no false error).
        let layout = MenuBarLayout.make(from: idleSnapshot(sevenDayUtil: 31), now: now)
        #expect(expanded(layout) != nil)
    }
}

// MARK: - session-idle (#100, ADR-0027)

@Suite("MenuBarLayout session-idle")
struct MenuBarLayoutIdleTests {

    private func expanded(
        _ layout: MenuBarLayout
    ) -> (five: BarView, seven: BarView?, resetToShow: ResetToShow?)? {
        guard case let .expanded(five, seven, resetToShow) = layout.mode else {
            Issue.record("expected .expanded, got \(layout.mode)")
            return nil
        }
        return (five, seven, resetToShow)
    }

    @Test func idleKeepsBothBarsExpanded() {
        // The bars never collapse (ADR-0015 stands): idle is still `.expanded`, only the 5h bar is idle.
        let layout = MenuBarLayout.make(from: idleSnapshot(), now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.five.idle)
        #expect(!(e.seven?.idle ?? true))
        #expect(e.five.window == .fiveHour)
        #expect(e.seven?.window == .sevenDay)
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

    @Test func idleResetIsSevenDayInCompactDaysInAlwaysMode() {
        // Idle 5h calm + a calm 7-day → default mode hides the countdown; `.always` shows the 7-day
        // one (5h has no reset), rendered compact as "4d".
        let layout = MenuBarLayout.make(
            from: idleSnapshot(sevenDayResetsIn: 4 * 24 * 3600), now: now, resetMode: .always)
        guard let e = expanded(layout), let r = e.resetToShow else {
            Issue.record("expected a countdown in .always mode"); return
        }
        #expect(r.which == .sevenDay)
        #expect(r.display == "4d")
    }

    @Test func idleResetWithin24hIsHours() {
        // 7-day reset < 24 h out → an hours count, not a day count. Formerly asserted the absolute
        // wall-clock branch; since #284 (ADR-0074) the menu bar has one format, so this now pins the
        // **unit** (and that the idle path still routes to the 7-day window). Both bars calm, so
        // `.always` is needed to surface the countdown.
        let layout = MenuBarLayout.make(
            from: idleSnapshot(sevenDayResetsIn: 5 * 3600), now: now, resetMode: .always)
        guard let e = expanded(layout), let r = e.resetToShow else {
            Issue.record("expected a countdown in .always mode"); return
        }
        #expect(r.which == .sevenDay)
        #expect(r.display == "5h")
    }

    @Test func idleWithActiveSevenDayBrokenResetIsError() {
        // Idle 5h (legitimately date-less, ADR-0027) but the **7-day** window reports usage (31 %) with a
        // **non-empty, unparseable** `resets_at` — a malformed payload on a real window → the ⚠️ error
        // state (#167, ADR-0043), not a silently-dropped countdown. The idle 5h's own missing date is
        // never treated as an error.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 31, resetsAt: "not-a-date"),
            sessionIdle: true)
        if case .error = MenuBarLayout.make(from: snap, now: now, resetMode: .always).mode {} else {
            Issue.record("expected .error when the idle-state 7-day window's reset is broken")
        }
    }

    @Test func idleWithBlankSevenDayDateStaysExpanded() {
        // Idle 5h + a 7-day window with usage but a **blank** (empty/null) date: that is a
        // boundary/synthesis state, NOT a malformed value — so it is not a data error. Stays `.expanded`
        // (the countdown is simply absent). Only a non-empty unparseable date qualifies as an error.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 31, resetsAt: ""),
            sessionIdle: true)
        #expect(expanded(MenuBarLayout.make(from: snap, now: now, resetMode: .always)) != nil)
    }

    @Test func idleWithCalmSevenDayNoUsageStaysExpanded() {
        // Idle 5h + a 7-day window with **no** usage and a blank date: nothing to reset yet, so it is
        // NOT a data error — the widget stays `.expanded` (the countdown is simply absent).
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 0, resetsAt: ""),
            sessionIdle: true)
        let layout = MenuBarLayout.make(from: snap, now: now, resetMode: .always)
        guard let e = expanded(layout) else { return }
        #expect(e.resetToShow == nil)
    }

    // MARK: idle-blocked (#158)

    @Test func idleNotBlockedWhenSevenDayHasQuota() {
        // A normal idle state (7d below 100) is "ready to start", never blocked.
        let layout = MenuBarLayout.make(from: idleSnapshot(sevenDayUtil: 31), now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.five.idle)
        #expect(!e.five.blocked)
    }

    @Test func idleBlockedWhenSevenDayExhaustedNoCredits() {
        // 7d at 100 with no credits → blocked; the grey-bar flag is set and the countdown surfaces the
        // 7-day reset even in the default mode (blocked overrides the calm-hides-countdown table).
        let layout = MenuBarLayout.make(from: idleSnapshot(sevenDayUtil: 100), now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.five.blocked)
        guard let r = e.resetToShow else { Issue.record("blocked idle must show a countdown"); return }
        #expect(r.display == "4d")   // 7d reset 4 days out, compact-days
    }

    @Test func idleNotBlockedWhenCreditsCover() {
        // 7d at 100 but credits enabled and not capped → work continues on the paid tier, not blocked.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 100, resetsAt: resetsAt(inSeconds: 4 * 24 * 3600)),
            sessionIdle: true, spend: SpendInfo(enabled: true, spendLimitReached: false))
        let layout = MenuBarLayout.make(from: snap, now: now)
        guard let e = expanded(layout) else { return }
        #expect(!e.five.blocked)
    }

    @Test func idleBlockedWhenCreditsCapped() {
        // 7d at 100 and credits capped → blocked; both windows are exhausted. The 7-day reset (4d) is
        // sooner than the monthly credits reset, so the token reset wins (last-stand rule).
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 100, resetsAt: resetsAt(inSeconds: 4 * 24 * 3600)),
            sessionIdle: true, spend: SpendInfo(enabled: false, spendLimitReached: true))
        let layout = MenuBarLayout.make(from: snap, now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.five.blocked)
        guard let r = e.resetToShow else { Issue.record("blocked idle must show a countdown"); return }
        // 7-day reset is 4 days out; the credits month-end is weeks away, so 7d is the blocking reset.
        #expect(r.display == "4d")
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

// MARK: - default-mode hide/show: drop the countdown when both bars are calm (ADR-0028/0029)

@Suite("MenuBarLayout showReset")
struct MenuBarLayoutShowResetTests {

    /// Whether the default-mode layout draws a countdown (`resetToShow != nil`), or `nil` (recording a
    /// failure) if not expanded. All tests here use the default `.smart` mode.
    private func showReset(_ layout: MenuBarLayout) -> Bool? {
        guard case let .expanded(_, _, resetToShow) = layout.mode else {
            Issue.record("expected .expanded, got \(layout.mode)")
            return nil
        }
        return resetToShow != nil
    }

    // In the 5h window (18000 s) a `fiveHourResetsIn: 4*3600` reset → timeFraction 0.2; in the 7d
    // window a `3*24*3600` reset → timeFraction ≈ 0.571. Utilisations below those are green (calm).
    // The yellow→orange split is now the dynamic threshold `0.16·(1−timeFraction)`: 0.128 at t=0.20
    // (5h), ≈0.0686 at t=0.571 (7d). Both resets are days/hours away, so the 20-min override is off.

    @Test func bothGreenHidesReset() {
        // 5h usage 0.10 < time 0.20 (green); 7d usage 0.30 < time 0.571 (green) → both calm → hidden.
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 10, sevenDayUtil: 30), now: now)
        #expect(showReset(layout) == false)
    }

    @Test func greenPlusYellowHidesReset() {
        // 5h green (usage 0.10); 7d yellow — usage 0.62 vs time 0.571, ahead ≈0.049 (< thr 0.0686) → calm.
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 10, sevenDayUtil: 62), now: now)
        #expect(showReset(layout) == false)
    }

    @Test func bothYellowHidesReset() {
        // 5h yellow — usage 0.30 vs time 0.20, ahead 0.10 (< thr 0.128); 7d yellow — usage 0.62 vs 0.571
        // ahead ≈0.049 (< thr 0.0686) → both calm → hidden.
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 30, sevenDayUtil: 62), now: now)
        #expect(showReset(layout) == false)
    }

    @Test func oneOrangeShowsReset() {
        // 5h orange — usage 0.50 vs time 0.20, ahead 0.30 (>= thr 0.128) → noisy; 7d green → label returns.
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30), now: now)
        #expect(showReset(layout) == true)
    }

    @Test func oneExhaustedShowsReset() {
        // 7d usage == 100 → red → noisy, even though 5h is green.
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 10, sevenDayUtil: 100), now: now)
        #expect(showReset(layout) == true)
    }

    @Test func nearResetOverrideShowsReset() {
        // 5h reset in 10 min (t ≈ 0.967) with only a 1-point lead (usage 0.98): far below any dynamic
        // threshold, yet the ≤20-min override makes it orange → the countdown returns. 7d green.
        let snap = snapshot(fiveHourUtil: 98, sevenDayUtil: 30, fiveHourResetsIn: 10 * 60)
        let layout = MenuBarLayout.make(from: snap, now: now)
        #expect(showReset(layout) == true)
    }

    @Test func idleWithCalmSevenDayHidesReset() {
        // Idle 5h is always calm; a calm 7-day (usage 0.31 vs time ≈ 0.571 green) → both calm → hidden.
        let layout = MenuBarLayout.make(from: idleSnapshot(sevenDayUtil: 31), now: now)
        guard case let .expanded(five, _, resetToShow) = layout.mode else {
            Issue.record("expected .expanded, got \(layout.mode)")
            return
        }
        #expect(five.idle)
        #expect(resetToShow == nil)
    }

    @Test func idleWithNoisySevenDayShowsReset() {
        // Idle 5h calm, but a noisy 7-day decides: usage 0.95 vs time ≈ 0.571, ahead ~0.38 → orange.
        let layout = MenuBarLayout.make(from: idleSnapshot(sevenDayUtil: 95), now: now)
        #expect(showReset(layout) == true)
    }
}

// MARK: - MenuBarLayout.selectReset (ADR-0029)

@Suite("MenuBarLayout.selectReset")
struct MenuBarLayoutSelectResetTests {

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// 5h reset 2 h out; 7d reset either near (< 24 h) or far (days) per each test.
    private static func at(hours: Double) -> Date { now.addingTimeInterval(hours * 3_600) }
    private static let fiveAt = at(hours: 2)          // 5h always near
    private static let sevenFar = at(hours: 5 * 24)   // 7d days away (≥ 24 h)
    private static let sevenNear = at(hours: 10)      // 7d < 24 h

    private static func select(
        five: PacingSeverity, seven: PacingSeverity,
        fiveAt: Date? = fiveAt, sevenAt: Date? = sevenFar,
        mode: ResetCountdownMode
    ) -> ResetSelection {
        MenuBarLayout.selectReset(
            fiveSeverity: five, fiveResetsAt: fiveAt,
            sevenSeverity: seven, sevenResetsAt: sevenAt,
            now: now, mode: mode)
    }

    /// The `ResetToShow` from a `.show(_:)` outcome, else `nil` — so `.which`/`.display` assertions
    /// read the same as before the `ResetSelection` split.
    private static func shown(
        five: PacingSeverity, seven: PacingSeverity,
        fiveAt: Date? = fiveAt, sevenAt: Date? = sevenFar,
        mode: ResetCountdownMode
    ) -> ResetToShow? {
        if case let .show(r) = select(five: five, seven: seven, fiveAt: fiveAt, sevenAt: sevenAt, mode: mode) {
            return r
        }
        return nil
    }

    // ── Never ────────────────────────────────────────────────────────────────────────────────
    @Test func neverHidesEverything() {
        for (f, s): (PacingSeverity, PacingSeverity) in
            [(.calm, .calm), (.ahead, .calm), (.exhausted, .exhausted)] {
            #expect(Self.select(five: f, seven: s, mode: .never) == .hide)
        }
    }

    // ── Both calm ────────────────────────────────────────────────────────────────────────────
    @Test func bothCalmHiddenExceptAlways() {
        #expect(Self.select(five: .calm, seven: .calm, mode: .smart) == .hide)
        // Always → nearest (5h at 2 h is nearer than 7d).
        #expect(Self.shown(five: .calm, seven: .calm, mode: .always)?.which == .fiveHour)
    }

    // ── farBehind (blue) is calm, never noisy — must not force a countdown ─────────────────────
    @Test func farBehindIsNotNoisy() {
        // Both far-behind → hidden in smart (identical to both-calm), shown only in always.
        #expect(Self.select(five: .farBehind, seven: .farBehind, mode: .smart) == .hide)
        #expect(Self.shown(five: .farBehind, seven: .farBehind, mode: .always)?.which == .fiveHour)
        // A far-behind 7d beside a calm 5h stays hidden in smart (blue never surfaces a countdown).
        #expect(Self.select(five: .calm, seven: .farBehind, mode: .smart) == .hide)
        #expect(Self.select(five: .farBehind, seven: .calm, mode: .smart) == .hide)
        // But a genuinely noisy window beside a far-behind one still shows that noisy window.
        #expect(Self.shown(five: .ahead, seven: .farBehind, mode: .smart)?.which == .fiveHour)
    }

    // ── One noisy: 5h ────────────────────────────────────────────────────────────────────────
    @Test func onlyFiveNoisyShowsFive() {
        for m: ResetCountdownMode in [.always, .smart] {
            #expect(Self.shown(five: .ahead, seven: .calm, mode: m)?.which == .fiveHour)
            #expect(Self.shown(five: .exhausted, seven: .calm, mode: m)?.which == .fiveHour)
        }
    }

    // ── One noisy: 7d orange, days away (now always shown, #168) ─────────────────────────────
    @Test func onlySevenOrangeFarShownForAllShowingModes() {
        // Far (≥24 h): both `always` and `smart` show it (the "hide the days-away 7d" option was removed).
        #expect(Self.shown(five: .calm, seven: .ahead, sevenAt: Self.sevenFar, mode: .always)?.which == .sevenDay)
        #expect(Self.shown(five: .calm, seven: .ahead, sevenAt: Self.sevenFar, mode: .smart)?.which == .sevenDay)
    }

    @Test func onlySevenOrangeNearAlwaysShown() {
        // Near (< 24 h): shown for the smart mode.
        #expect(Self.shown(five: .calm, seven: .ahead, sevenAt: Self.sevenNear, mode: .smart)?.which == .sevenDay)
    }

    // ── One noisy: 7d red (always) ───────────────────────────────────────────────────────────
    @Test func onlySevenRedAlwaysShownEvenFar() {
        #expect(Self.shown(five: .calm, seven: .exhausted, sevenAt: Self.sevenFar, mode: .smart)?.which == .sevenDay)
    }

    // ── Both noisy: next unblock ─────────────────────────────────────────────────────────────
    @Test func bothExhaustedShowsLater() {
        // 5h at 2 h, 7d at 5 d → later is 7d.
        #expect(Self.shown(five: .exhausted, seven: .exhausted, mode: .smart)?.which == .sevenDay)
    }

    @Test func bothOrangeShowsEarlier() {
        // 5h at 2 h, 7d at 5 d → earlier is 5h.
        #expect(Self.shown(five: .ahead, seven: .ahead, mode: .smart)?.which == .fiveHour)
    }

    @Test func redPlusOrangeShowsRed() {
        // 5h red + 7d orange → red bar (5h).
        #expect(Self.shown(five: .exhausted, seven: .ahead, mode: .smart)?.which == .fiveHour)
        // 5h orange + 7d red → red bar (7d).
        #expect(Self.shown(five: .ahead, seven: .exhausted, mode: .smart)?.which == .sevenDay)
    }

    // ── Broken resets_at → data error (not a fabricated countdown — #167, ADR-0041) ────────────
    @Test func brokenResetOfChosenBarIsDataError() {
        // 5h noisy but its resets_at is nil → the chosen 5h has no valid instant → .dataError(.fiveHour).
        #expect(Self.select(five: .exhausted, seven: .calm, fiveAt: nil, mode: .smart)
                == .dataError(.fiveHour))
    }

    @Test func brokenResetOfUnchosenBarIsNotError() {
        // 5h calm (unchosen) with a nil date, 7d noisy with a valid date → the 7d is shown; the broken
        // 5h date is irrelevant because it was never chosen. Not an error.
        #expect(Self.shown(five: .calm, seven: .exhausted, fiveAt: nil, sevenAt: Self.sevenFar,
                           mode: .smart)?.which == .sevenDay)
    }
}

// MARK: - hide calm 7-day bar (#94)

/// The `hideCalmSevenDay` opt-out: a **calm** 7-day bar (green/mild-yellow) is dropped from
/// `.expanded` (leaving the 5h bar alone), while an **orange/red** 7-day bar is always kept and the
/// **error** state is never affected. The reset-countdown selection is unchanged (`selectReset` runs
/// on the true severities regardless).
///
/// Fixture arithmetic (against the 7d window = 604 800 s, `snapshot()`'s reset defaults):
/// - 7d **green**: `sevenDayUtil: 30`, default reset 3 d out → elapsed ≈ 0.571 → usage < time → calm.
/// - 7d **orange**: `sevenDayUtil: 55, sevenDayResetsIn: 6 d` → elapsed ≈ 0.143 → ahead ≈ 0.41,
///   past the dynamic threshold `0.16·(1−0.143) ≈ 0.137` → noisy.
/// - 7d **red**: `sevenDayUtil: 100` → usageFraction ≥ 1 → exhausted.
/// The 5h side uses `fiveHourUtil: 50` (default 4 h reset → elapsed 0.2 → ahead 0.30, past threshold
/// 0.128 → noisy) so the 5h bar is present and drives the countdown in the mixed cases.
@Suite("MenuBarLayout hide calm 7d (#94)")
struct MenuBarLayoutHideCalmSevenDayTests {

    private func expanded(
        _ layout: MenuBarLayout
    ) -> (five: BarView, seven: BarView?, resetToShow: ResetToShow?)? {
        guard case let .expanded(five, seven, resetToShow) = layout.mode else {
            Issue.record("expected .expanded, got \(layout.mode)")
            return nil
        }
        return (five, seven, resetToShow)
    }

    @Test func defaultOffKeepsCalmSevenDay() {
        // Regression: the default `hideCalmSevenDay: false` never elides the 7-day bar, even calm.
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30), now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.seven != nil)
        #expect(e.seven?.isCalm == true)   // confirm the fixture really is calm
    }

    @Test func calmSevenDayIsHidden() {
        // Calm 7-day + opt-in → 7-day dropped, 5h bar alone.
        let layout = MenuBarLayout.make(
            from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30), now: now, hideCalmSevenDay: true)
        guard let e = expanded(layout) else { return }
        #expect(e.seven == nil)
        #expect(e.five.window == .fiveHour)
        #expect(!e.five.idle)
    }

    @Test func orangeSevenDayStaysVisible() {
        // Ahead-of-pace (orange) 7-day is noisy → kept even with the opt-in.
        let layout = MenuBarLayout.make(
            from: snapshot(fiveHourUtil: 50, sevenDayUtil: 55, sevenDayResetsIn: 6 * 24 * 3600),
            now: now, hideCalmSevenDay: true)
        guard let e = expanded(layout) else { return }
        #expect(e.seven != nil)
        #expect(e.seven?.severity == .ahead)
    }

    @Test func redSevenDayStaysVisible() {
        // Exhausted (red) 7-day is noisy → kept even with the opt-in.
        let layout = MenuBarLayout.make(
            from: snapshot(fiveHourUtil: 50, sevenDayUtil: 100), now: now, hideCalmSevenDay: true)
        guard let e = expanded(layout) else { return }
        #expect(e.seven != nil)
        #expect(e.seven?.severity == .exhausted)
    }

    @Test func sessionIdleWithCalmSevenDayLeavesOnlyIdleFive() {
        // Session-idle 5h + calm 7-day + opt-in → only the idle 5h bar, centred (7-day dropped).
        let layout = MenuBarLayout.make(
            from: idleSnapshot(sevenDayUtil: 20), now: now, hideCalmSevenDay: true)
        guard let e = expanded(layout) else { return }
        #expect(e.seven == nil)
        #expect(e.five.idle)
    }

    @Test func sessionIdleWithNoisySevenDayKeepsIt() {
        // Session-idle 5h + a noisy (red) 7-day + opt-in → the 7-day bar stays; 5h idle rides above it.
        let layout = MenuBarLayout.make(
            from: idleSnapshot(sevenDayUtil: 100), now: now, hideCalmSevenDay: true)
        guard let e = expanded(layout) else { return }
        #expect(e.seven != nil)
        #expect(e.five.idle)
    }

    @Test func errorPhaseKeepsCalmSevenDayForDiagnostics() {
        // The error state (⚠️ + stale bars, 30–60 min) ignores the opt-in — the calm 7-day is kept
        // for diagnostics, so both stale bars sit beside the glyph.
        let health = UsageHealth(
            lastSuccess: now.addingTimeInterval(-31 * 60),
            failingSince: now.addingTimeInterval(-31 * 60),
            reason: .notSignedIn)
        let layout = MenuBarLayout.make(
            from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30), health: health, now: now,
            hideCalmSevenDay: true)
        guard case let .error(five, seven, _, _) = layout.mode else {
            Issue.record("expected .error with bars, got \(layout.mode)")
            return
        }
        #expect(five != nil)
        #expect(seven != nil)   // calm 7-day kept in the diagnostic error state
    }

    @Test func resetSelectionUnaffectedByHidingSevenDay() {
        // Hiding the calm 7-day bar does not change the reset countdown: 5h noisy + 7d calm → 5h reset,
        // identical whether or not the bar is elided.
        let snap = snapshot(fiveHourUtil: 50, sevenDayUtil: 30)
        let hidden = MenuBarLayout.make(from: snap, now: now, hideCalmSevenDay: true)
        let shown = MenuBarLayout.make(from: snap, now: now, hideCalmSevenDay: false)
        guard let eh = expanded(hidden), let es = expanded(shown) else { return }
        #expect(eh.resetToShow?.which == .fiveHour)
        #expect(eh.resetToShow == es.resetToShow)   // same countdown, bar presence aside
    }
}

// MARK: - money-credits icon (#144)

/// A `SpendInfo` builder for the credits-icon tests — mirrors the observed API shapes (EUR money
/// objects, the `spend_limit_reached`/`enabled` pairing) from `CreditsModelTests`.
private func spend(
    used: Int? = 1077, limit: Int?, enabled: Bool, spendLimitReached: Bool = false
) -> SpendInfo {
    SpendInfo(
        used: used.map { Money(amountMinor: $0, currency: "EUR", exponent: 2) },
        limit: limit.map { Money(amountMinor: $0, currency: "EUR", exponent: 2) },
        enabled: enabled,
        spendLimitReached: spendLimitReached,
        usedCredits: used.map(Double.init),
        currency: "EUR",
        decimalPlaces: 2)
}

/// A snapshot carrying a `spend` block; the 7-day utilisation drives whether a base limit is
/// exhausted (the second half of the icon show-trigger).
private func creditsSnapshot(sevenDayUtil: Double, spend: SpendInfo?) -> UsageSnapshot {
    UsageSnapshot(
        fiveHour: UsageWindow(utilization: 20, resetsAt: resetsAt(inSeconds: 3 * 3600)),
        sevenDay: UsageWindow(utilization: sevenDayUtil, resetsAt: resetsAt(inSeconds: 5 * 24 * 3600)),
        spend: spend)
}

@Suite("MenuBarLayout credits icon (#144)")
struct MenuBarLayoutCreditsTests {

    @Test func hiddenWhenGateOff() {
        // `showCredits: false` (the default, and the "Show extra usage" opt-out) → never a marker,
        // even with an active spend and an exhausted base limit.
        let snap = creditsSnapshot(sevenDayUtil: 100, spend: spend(limit: 1500, enabled: true))
        let layout = MenuBarLayout.make(from: snap, health: .healthy(lastSuccess: now), now: now)
        #expect(layout.credits == nil)
    }

    @Test func hiddenWhenNoBaseLimitExhausted() {
        // Credits active but no base limit is spent yet (7-day at 50 %) → the icon does not kick in.
        let snap = creditsSnapshot(sevenDayUtil: 50, spend: spend(limit: 1500, enabled: true))
        let layout = MenuBarLayout.make(
            from: snap, health: .healthy(lastSuccess: now), now: now, showCredits: true)
        #expect(layout.credits == nil)
    }

    @Test func hiddenWhenNoSpendBlock() {
        // A pre-credits snapshot (no `spend`) → no marker regardless of the gate/limits.
        let snap = creditsSnapshot(sevenDayUtil: 100, spend: nil)
        let layout = MenuBarLayout.make(
            from: snap, health: .healthy(lastSuccess: now), now: now, showCredits: true)
        #expect(layout.credits == nil)
    }

    @Test func shownWhenActiveAndBaseExhausted() {
        // Enabled €15 limit, €10.77 spent + a 100 % base limit → the icon shows with a paced bar.
        let snap = creditsSnapshot(sevenDayUtil: 100, spend: spend(limit: 1500, enabled: true))
        let layout = MenuBarLayout.make(
            from: snap, health: .healthy(lastSuccess: now), now: now, showCredits: true)
        let marker = try? #require(layout.credits)
        #expect(marker?.bar != nil)   // a cap to pace against → a coloured bar
    }

    @Test func limitReachedForcesRedAndShows() {
        // `spend_limit_reached` shows the icon (even though `enabled: false`) and forces usage to 1 →
        // an exhausted bar (red rung), regardless of the raw used/limit fraction.
        let snap = creditsSnapshot(
            sevenDayUtil: 100, spend: spend(limit: 500, enabled: false, spendLimitReached: true))
        let layout = MenuBarLayout.make(
            from: snap, health: .healthy(lastSuccess: now), now: now, showCredits: true)
        let marker = try? #require(layout.credits)
        #expect(marker?.bar?.usageFraction == 1)
        #expect(marker?.bar?.severity == .exhausted)
        #expect(marker?.isCalm == false)
    }

    @Test func noLimitYieldsNeutralMarker() {
        // Unlimited monthly limit (`limit: nil`) → the icon still shows (credits active + base
        // exhausted) but carries a nil bar → the view draws it neutrally, and it counts as calm.
        let snap = creditsSnapshot(sevenDayUtil: 100, spend: spend(limit: nil, enabled: true))
        let layout = MenuBarLayout.make(
            from: snap, health: .healthy(lastSuccess: now), now: now, showCredits: true)
        let marker = try? #require(layout.credits)
        #expect(marker?.bar == nil)
        #expect(marker?.isCalm == true)
    }

    @Test func creditsIndependentOfServiceDot() {
        // The credits marker and the service dot are orthogonal — both can ride the same layout.
        let snap = creditsSnapshot(sevenDayUtil: 100, spend: spend(limit: 1500, enabled: true))
        let layout = MenuBarLayout.make(
            from: snap, health: .healthy(lastSuccess: now), now: now,
            serviceProblem: .majorOutage, showCredits: true)
        #expect(layout.credits != nil)
        #expect(layout.serviceProblem == .majorOutage)
    }
}

// MARK: - Pause icon hides bars (#194, #227)

@Suite("MenuBarLayout pauseHidesBars")
struct MenuBarLayoutPauseHidesBarsTests {

    /// Pull the associated values out of a `.blockedReset` mode, or fail the test.
    private func blocked(_ layout: MenuBarLayout) -> (reset: String, which: LimitWindow)? {
        guard case let .blockedReset(reset, which) = layout.mode else {
            Issue.record("expected .blockedReset, got \(layout.mode)")
            return nil
        }
        return (reset, which)
    }

    @Test func activeBlockedHidesBarsWhenOn() {
        // Both main windows exhausted (no credits → fully blocked) + toggle on → no bars, just the
        // blocking-reset countdown. With both exhausted the later token reset wins (last-stand): the
        // 7d (3d out) over the 5h (4h out).
        let snap = snapshot(fiveHourUtil: 100, sevenDayUtil: 100)
        let layout = MenuBarLayout.make(from: snap, now: now, pauseHidesBars: true)
        guard let b = blocked(layout) else { return }
        #expect(b.which == .sevenDay)
        #expect(b.reset == "3d")   // 7d reset 3 days out, compact-days
    }

    @Test func fiveHourExhaustedAloneUsesFiveHourReset() {
        // Only the 5h window is exhausted (7d has quota) → the 5h reset drives the countdown, so the
        // label counts the 2 hours to *that* reset rather than the days to the 7-day one.
        let snap = snapshot(fiveHourUtil: 100, sevenDayUtil: 40, fiveHourResetsIn: 2 * 3600)
        let layout = MenuBarLayout.make(from: snap, now: now, pauseHidesBars: true)
        guard let b = blocked(layout) else { return }
        #expect(b.which == .fiveHour)
        #expect(b.reset == "2h")
    }

    @Test func sevenDayExhaustedAloneUsesSevenDayReset() {
        // Only the 7d window is exhausted (5h has quota) → the 7d reset drives the countdown.
        let snap = snapshot(fiveHourUtil: 30, sevenDayUtil: 100, sevenDayResetsIn: 2 * 24 * 3600)
        let layout = MenuBarLayout.make(from: snap, now: now, pauseHidesBars: true)
        guard let b = blocked(layout) else { return }
        #expect(b.which == .sevenDay)
        #expect(b.reset == "2d")
    }

    @Test func keepsBarsWhenOff() {
        // Same blocked snapshot, toggle off → the normal expanded bars, unchanged (pause icon + bars).
        let snap = snapshot(fiveHourUtil: 100, sevenDayUtil: 100)
        let layout = MenuBarLayout.make(from: snap, now: now, pauseHidesBars: false)
        guard case .expanded = layout.mode else {
            Issue.record("expected .expanded when toggle off, got \(layout.mode)")
            return
        }
    }

    @Test func notBlockedStaysExpandedEvenWhenOn() {
        // Neither window exhausted (both < 100) → not blocked, so the toggle is inert: full bars.
        let snap = snapshot(fiveHourUtil: 80, sevenDayUtil: 90)
        let layout = MenuBarLayout.make(from: snap, now: now, pauseHidesBars: true)
        guard case .expanded = layout.mode else {
            Issue.record("expected .expanded when not blocked, got \(layout.mode)")
            return
        }
    }

    @Test func forcesResetEvenInNeverMode() {
        // `resetMode: .never` normally hides every countdown, but a bars-less blocked widget would then
        // show nothing beside the icon — so the blocking reset is forced regardless of the mode.
        let snap = snapshot(fiveHourUtil: 100, sevenDayUtil: 100)
        let layout = MenuBarLayout.make(
            from: snap, now: now, resetMode: .never, pauseHidesBars: true)
        guard let b = blocked(layout) else { return }
        #expect(b.reset == "3d")
    }

    @Test func keepsBarsWhenCreditsCover() {
        // The strict `isBlocked` predicate (#227): a 7d at 100 % with active, uncapped credits is
        // `mainWindowExhausted` but NOT blocked (work continues on the paid tier), so the bars stay even
        // with the toggle on. This is the deliberate change from the pre-#227 `mainWindowExhausted` gate.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 20, resetsAt: resetsAt(inSeconds: 4 * 3600)),
            sevenDay: UsageWindow(utilization: 100, resetsAt: resetsAt(inSeconds: 3 * 24 * 3600)),
            spend: SpendInfo(enabled: true, spendLimitReached: false))
        let layout = MenuBarLayout.make(from: snap, now: now, pauseHidesBars: true)
        guard case .expanded = layout.mode else {
            Issue.record("expected .expanded (credits cover → not blocked), got \(layout.mode)")
            return
        }
    }

    @Test func idleBlockedHidesBarsWhenOn() {
        // The idle-blocked state (7d exhausted, no credits, no active 5h) also drops its grey idle bar
        // for the countdown-only widget when the toggle is on.
        let snap = idleSnapshot(sevenDayUtil: 100)
        let layout = MenuBarLayout.make(from: snap, now: now, pauseHidesBars: true)
        guard let b = blocked(layout) else { return }
        #expect(b.which == .sevenDay)
        #expect(b.reset == "4d")   // idle 7d reset 4 days out
    }

    @Test func brokenResetFallsBackToNormalPath() {
        // Exhausted but the only exhausted window's `resets_at` is unparseable → `forBlocked` yields nil,
        // so we do NOT enter `.blockedReset`; the normal path surfaces the data error as ⚠️ instead.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 30, resetsAt: resetsAt(inSeconds: 4 * 3600)),
            sevenDay: UsageWindow(utilization: 100, resetsAt: "not-a-date"))
        let layout = MenuBarLayout.make(from: snap, now: now, pauseHidesBars: true)
        if case .blockedReset = layout.mode {
            Issue.record("expected a fallback away from .blockedReset for a broken reset, got \(layout.mode)")
        }
    }
}

// MARK: - Blocked pause glyph (#199, #227)

@Suite("MenuBarLayout blockedPause")
struct MenuBarLayoutBlockedPauseTests {

    /// A `UsageHealth` for the healthy path — the only path that carries `blockedPause`.
    private let healthy = UsageHealth.healthy(lastSuccess: now)

    /// A failing health `age` seconds old, for the ⚠️ error state.
    private func failing(for age: TimeInterval) -> UsageHealth {
        UsageHealth(lastSuccess: now.addingTimeInterval(-age),
                    failingSince: now.addingTimeInterval(-age), reason: .timeout)
    }

    @Test func pauseWhenBlockedAndBarsKept() {
        // Fully blocked (both windows 100 %, no credits), toggle off (bars kept) → the mode stays
        // `.expanded` (red bars) AND the pause glyph is set. The icon is always shown when blocked.
        let snap = snapshot(fiveHourUtil: 100, sevenDayUtil: 100)
        let layout = MenuBarLayout.make(
            from: snap, health: healthy, now: now, pauseHidesBars: false)
        guard case .expanded = layout.mode else {
            Issue.record("expected .expanded (bars kept), got \(layout.mode)")
            return
        }
        #expect(layout.blockedPause == true)
    }

    @Test func pauseWhenBlockedAndBarsHidden() {
        // Same blocked snapshot but the toggle hides the bars (#194 countdown-only) → the pause glyph is
        // still set, drawn to the left of the countdown (#199, #227).
        let snap = snapshot(fiveHourUtil: 100, sevenDayUtil: 100)
        let layout = MenuBarLayout.make(
            from: snap, health: healthy, now: now, pauseHidesBars: true)
        guard case .blockedReset = layout.mode else {
            Issue.record("expected .blockedReset when bars hidden, got \(layout.mode)")
            return
        }
        #expect(layout.blockedPause == true)
    }

    @Test func noPauseWhenNotBlocked() {
        // Neither window exhausted → not blocked, so the glyph stays off regardless of the toggle.
        let snap = snapshot(fiveHourUtil: 80, sevenDayUtil: 90)
        let layout = MenuBarLayout.make(
            from: snap, health: healthy, now: now, pauseHidesBars: false)
        #expect(layout.blockedPause == false)
    }

    @Test func noPauseWhenCreditsCover() {
        // A 7d at 100 % with active, uncapped credits is `mainWindowExhausted` but NOT `isBlocked` (work
        // continues on the paid tier), so the pause glyph — which keys off `isBlocked` — stays off, and
        // the bars stay too.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 20, resetsAt: resetsAt(inSeconds: 4 * 3600)),
            sevenDay: UsageWindow(utilization: 100, resetsAt: resetsAt(inSeconds: 3 * 24 * 3600)),
            spend: SpendInfo(enabled: true, spendLimitReached: false))
        let layout = MenuBarLayout.make(
            from: snap, health: healthy, now: now, pauseHidesBars: false)
        #expect(layout.blockedPause == false)
    }

    @Test func pauseIsAlwaysOnWhenBlocked() {
        // #227: the pause icon is no longer user-optional — whenever fully blocked it is drawn, regardless
        // of the `pauseHidesBars` toggle (which only decides whether the bars are hidden beside it).
        let snap = snapshot(fiveHourUtil: 100, sevenDayUtil: 100)
        for hides in [true, false] {
            let layout = MenuBarLayout.make(
                from: snap, health: healthy, now: now, pauseHidesBars: hides)
            #expect(layout.blockedPause == true)
        }
    }

    @Test func noPauseInErrorState() {
        // Polling failing past the bars-drop threshold → `.error`, never `.expanded`, so no glyph even
        // though the last snapshot was blocked.
        let snap = snapshot(fiveHourUtil: 100, sevenDayUtil: 100)
        let layout = MenuBarLayout.make(
            from: snap, health: failing(for: UsageHealth.hideBarsAfter + 1), now: now,
            pauseHidesBars: false)
        guard case .error = layout.mode else {
            Issue.record("expected .error past the stale threshold, got \(layout.mode)")
            return
        }
        #expect(layout.blockedPause == false)
    }

    @Test func idleBlockedPauseWhenBarsKept() {
        // The idle-blocked state (7d exhausted, no credits, no active 5h) is also `isBlocked`; with the
        // toggle off it stays `.expanded` (grey idle bar) and the glyph precedes it.
        let snap = idleSnapshot(sevenDayUtil: 100)
        let layout = MenuBarLayout.make(
            from: snap, health: healthy, now: now, pauseHidesBars: false)
        guard case .expanded = layout.mode else {
            Issue.record("expected .expanded (idle bar kept), got \(layout.mode)")
            return
        }
        #expect(layout.blockedPause == true)
    }
}
