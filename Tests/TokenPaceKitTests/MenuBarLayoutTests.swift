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
        guard case let .expanded(five, _) = layout.mode else {
            Issue.record("expected .expanded at 0%, got \(layout.mode)")
            return
        }
        #expect(five?.idle == false)
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

    /// Pull the associated values out of an expanded mode, or fail the test. Both bars are optional in
    /// the mode (either can be hidden while calm — ``TopBarHiding``), but these tests all call `make`
    /// without `hideTopBar:`, which defaults to `.never`, so the 5h bar is unwrapped here and a `nil`
    /// is reported as a failure rather than pushed onto every call site. `seven` stays optional.
    private func expanded(_ layout: MenuBarLayout) -> (five: BarView, seven: BarView?)? {
        expanded(layout.mode)
    }

    /// The same unwrap against a bare mode, for the exhausted states that `make` answers without bars
    /// (ADR-0090/0091). Their **bars** are still built — by `expandedBars` — and that is what these
    /// tests pin.
    private func expanded(_ mode: MenuBarMode) -> (five: BarView, seven: BarView?)? {
        guard case let .expanded(five, seven) = mode else {
            Issue.record("expected .expanded, got \(mode)")
            return nil
        }
        guard let five else {
            Issue.record("expected a 5h bar (no hideCalmBar was requested), got nil")
            return nil
        }
        return (five, seven)
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

    @Test func criticalUtilizationSurfacesIndicator() {
        // utilisation == 100 → .critical on that bar (PacingModel). Built through `expandedBars`: an
        // exhausted 5h window is "cannot work" for `make`, which answers it without bars (ADR-0090).
        let built = MenuBarLayout.expandedBars(for: snapshot(fiveHourUtil: 100, sevenDayUtil: 30), now: now)
        guard let e = expanded(built) else { return }
        #expect(e.five.indicator == .critical)
    }

    @Test func bothActiveResetsUnparseableIsError() {
        // Both windows report real usage (50/30) but both `resets_at` are malformed → an API data error
        // on active windows → the ⚠️ error state, not a silently-dropped countdown (#167, ADR-0041).
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 50, resetsAt: "garbage"),
            sevenDay: UsageWindow(utilization: 30, resetsAt: "null")
        )
        if case .error = MenuBarLayout.make(from: snap, now: now).mode {} else {
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
        //
        // The 5h window sits at **99**, not 100, on purpose: an *exhausted* window with a broken date is
        // a different answer since ADR-0091 (`.exhaustedUnknownReset`, covered below), and it would
        // never reach this bars-keeping branch. 99 is the nearest state that still exercises the
        // original rule — a window that is genuinely active, and genuinely still drawable as a bar.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 99, resetsAt: "garbage"),
            sevenDay: UsageWindow(utilization: 30, resetsAt: resetsAt(inSeconds: 3 * 24 * 3600))
        )
        let layout = MenuBarLayout.make(from: snap, now: now)
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

    /// As in the expanded-content suite: these all call `make` without `hideTopBar:` (→ `.never`), so
    /// the idle 5h bar is always present and is unwrapped here. The case where `.fiveHour` *does* elide
    /// an idle 5h bar is covered by the hide-calm-bar suite below.
    private func expanded(_ layout: MenuBarLayout) -> (five: BarView, seven: BarView?)? {
        expanded(layout.mode)
    }

    /// The same unwrap against a bare mode, for the exhausted states that `make` answers without bars
    /// (ADR-0090/0091). Their **bars** are still built — by `expandedBars` — and that is what these
    /// tests pin.
    private func expanded(_ mode: MenuBarMode) -> (five: BarView, seven: BarView?)? {
        guard case let .expanded(five, seven) = mode else {
            Issue.record("expected .expanded, got \(mode)")
            return nil
        }
        guard let five else {
            Issue.record("expected a 5h bar (no hideCalmBar was requested), got nil")
            return nil
        }
        return (five, seven)
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

    @Test func idleCalmDrawsBarsAndNoCountdown() {
        // The two "which reset does idle pick, and in what unit" tests that used to live here are gone
        // with the countdown itself (ADR-0091): a calm idle state has no reset to show, because it is
        // not blocking anything. What replaces them is the invariant — `.expanded` is bars only, and the
        // idle state is no exception. The unit formatting they pinned survives on the *blocked* idle
        // path (`idleBlockedHidesBars`, "4d"), which is where a countdown is now the whole widget.
        let layout = MenuBarLayout.make(from: idleSnapshot(sevenDayResetsIn: 4 * 24 * 3600), now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.five.idle)
        #expect(e.seven?.window == .sevenDay)
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
        if case .error = MenuBarLayout.make(from: snap, now: now).mode {} else {
            Issue.record("expected .error when the idle-state 7-day window's reset is broken")
        }
    }

    @Test func idleWithBlankSevenDayDateStaysExpanded() {
        // Idle 5h + a 7-day window with usage but a **blank** (empty/null) date: that is a
        // boundary/synthesis state, NOT a malformed value — so it is not a data error. Stays `.expanded`
        // (the countdown is simply absent). Only a non-empty unparseable date qualifies as an error.
        //
        // The `utilization: 31` here is what separates this from the cold start below: real usage is
        // worth drawing even without a clock to pace it against, so ADR-0107's unknown-reset state
        // deliberately does not claim this case.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 31, resetsAt: ""),
            sessionIdle: true)
        #expect(expanded(MenuBarLayout.make(from: snap, now: now)) != nil)
    }

    /// Idle 5h + a 7-day window with **no** usage and a blank date — the cold start, before any token
    /// has been spent. Since ADR-0107 this is its own state rather than a bar: with no weekly clock
    /// there is nothing to position a marker against, and the two zero bars it used to draw said
    /// "everything is fine" when the truthful answer is "there is nothing to report yet".
    ///
    /// Still not a data error: `.weeklyResetUnknown` draws the no-data symbol, not the ⚠️.
    @Test func idleWithNoUsageAndBlankSevenDayDateReportsUnknownReset() {
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 0, resetsAt: ""),
            sessionIdle: true)
        #expect(MenuBarLayout.make(from: snap, now: now).mode == .weeklyResetUnknown)
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
        // 7d at 100 with no credits → blocked; the grey-bar flag is set. `make` answers this state
        // without bars (ADR-0090); the **bar** it would draw is still built by `expandedBars`, and its
        // grey-vs-blue flag is what this test pins. The countdown half moved to
        // `MenuBarLayoutCanWeWorkTests.idleBlockedHidesBars`, which is where a countdown now lives.
        let mode = MenuBarLayout.expandedBars(for: idleSnapshot(sevenDayUtil: 100), now: now)
        guard let e = expanded(mode) else { return }
        #expect(e.five.blocked)
    }

    @Test func idleNotBlockedWhenCreditsCover() {
        // 7d at 100 but credits enabled and not capped → work continues on the paid tier, not blocked.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 100, resetsAt: resetsAt(inSeconds: 4 * 24 * 3600)),
            sessionIdle: true, spend: SpendInfo(enabled: true, spendLimitReached: false))
        guard let e = expanded(MenuBarLayout.expandedBars(for: snap, now: now)) else { return }
        #expect(!e.five.blocked)
    }

    @Test func idleBlockedWhenCreditsCapped() {
        // 7d at 100 and credits capped → blocked; both windows are exhausted. The 7-day reset (4d) is
        // sooner than the monthly credits reset, so the token reset wins (last-stand rule).
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 100, resetsAt: resetsAt(inSeconds: 4 * 24 * 3600)),
            sessionIdle: true, spend: SpendInfo(enabled: false, spendLimitReached: true))
        guard let e = expanded(MenuBarLayout.expandedBars(for: snap, now: now)) else { return }
        #expect(e.five.blocked)
    }

    @Test func idleSnapshotWithinGraceCarriesIdleBar() {
        // Within the ⚠️ threshold the idle 5h bar rides through a failing poll unchanged — the widget
        // gives no error signal at all while the data is merely a few minutes stale (issue #12 reuse,
        // narrowed by ADR-0091: the "⚠️ beside stale bars" phase this used to assert is gone).
        let health = UsageHealth(
            lastSuccess: now.addingTimeInterval(-10 * 60),
            failingSince: now.addingTimeInterval(-10 * 60),
            reason: .notSignedIn)
        let layout = MenuBarLayout.make(from: idleSnapshot(), health: health, now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.five.idle)
        #expect(e.seven != nil)
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

    @Test func exactlyAtTheThresholdStillShowsBars() {
        // Boundary: at exactly the threshold the glyph has NOT appeared yet (`age <= glyphAfter`).
        // Read the threshold off the health value rather than a literal, since it now scales with the
        // cadence — a hard-coded 15 min would silently stop testing the boundary at any other interval.
        let health = failing(for: UsageHealth.glyphAfter(for: failing(for: 0)))
        #expect(!isError(MenuBarLayout.make(from: snap, health: health, now: now)))
    }

    @Test func pastTheThresholdIsBareGlyphWithNoBars() {
        // One second past the threshold → ⚠️ **alone**. The old middle phase (⚠️ *beside* the stale
        // bars) is gone with ADR-0091: bars a quarter of an hour old invite exactly the reading they
        // cannot support, and the popup already explains the failure in words.
        let age = UsageHealth.glyphAfter(for: failing(for: 0)) + 1
        let layout = MenuBarLayout.make(from: snap, health: failing(for: age), now: now)
        #expect(layout.mode == .error(fiveHour: nil, sevenDay: nil, reset: nil, which: nil))
    }

    @Test func slowCadenceDelaysTheGlyph() {
        // The same wall-clock age reads differently at the idle cadence: 20 min is past the 15-min floor
        // (→ ⚠️) at the session cadence, but only 1.3 attempts at the 900 s idle one (→ still bars).
        // This is the whole point of scaling the threshold — an idle machine must not be told it is
        // broken after a single missed poll.
        func failingAt(interval: TimeInterval) -> UsageHealth {
            UsageHealth(lastSuccess: now.addingTimeInterval(-20 * 60),
                        failingSince: now.addingTimeInterval(-20 * 60),
                        reason: .notSignedIn, pollInterval: interval)
        }
        #expect(isError(MenuBarLayout.make(from: snap, health: failingAt(interval: 180), now: now)))
        #expect(!isError(MenuBarLayout.make(from: snap, health: failingAt(interval: 900), now: now)))
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

// MARK: - the countdown/bars invariant (ADR-0091)

/// Since ADR-0091 a countdown and bars are **mutually exclusive by construction**: `.expanded` carries
/// no reset field at all, so "bars *and* a number" is not representable. This suite sweeps the same
/// severity fixtures the retired `showReset`/`selectReset` suites used — the ones that used to decide
/// *whether* a countdown accompanied the bars — and now asserts the one thing left to assert about
/// them: every combination that produces bars produces **only** bars, and every combination that
/// produces a countdown produces **no** bars.
///
/// Fixture arithmetic (unchanged from those suites): in the 5h window (18 000 s) a
/// `fiveHourResetsIn: 4*3600` reset → timeFraction 0.2; in the 7d window a `3*24*3600` reset →
/// timeFraction ≈ 0.571. Utilisations below those are green (calm). The yellow→orange split is the
/// dynamic threshold `0.16·(1−timeFraction)`: 0.128 at t = 0.20 (5h), ≈ 0.0686 at t = 0.571 (7d).
@Suite("MenuBarLayout countdown/bars exclusivity")
struct MenuBarLayoutCountdownExclusivityTests {

    /// Every severity pairing the pacing model can produce, named by the colours it lands on — swept so
    /// the invariant is checked against the real `PacingModel` output rather than a hand-built mode.
    private static let severityGrid: [(name: String, snapshot: UsageSnapshot)] = [
        ("both green",        snapshot(fiveHourUtil: 10, sevenDayUtil: 30)),
        ("green + yellow",    snapshot(fiveHourUtil: 10, sevenDayUtil: 62)),
        ("both yellow",       snapshot(fiveHourUtil: 30, sevenDayUtil: 62)),
        ("orange + green",    snapshot(fiveHourUtil: 50, sevenDayUtil: 30)),
        ("green + red",       snapshot(fiveHourUtil: 10, sevenDayUtil: 100)),
        ("red + green",       snapshot(fiveHourUtil: 100, sevenDayUtil: 30)),
        ("both red",          snapshot(fiveHourUtil: 100, sevenDayUtil: 100)),
        // The ≤20-min override: a 1-point lead 10 min from the reset is orange despite being far below
        // any dynamic threshold — historically the case most likely to surface a countdown.
        ("near-reset orange", snapshot(fiveHourUtil: 98, sevenDayUtil: 30, fiveHourResetsIn: 10 * 60)),
        ("idle + calm 7d",    idleSnapshot(sevenDayUtil: 31)),
        ("idle + orange 7d",  idleSnapshot(sevenDayUtil: 95)),
        ("idle + red 7d",     idleSnapshot(sevenDayUtil: 100)),
    ]

    @Test func barsAndCountdownNeverCoexist() {
        // The type makes "bars + countdown" unrepresentable; this pins the complement — that no state
        // which *should* show a countdown quietly keeps its bars either. `.expanded` and the two
        // bars-less answers partition the healthy path between them.
        for (name, snap) in Self.severityGrid {
            switch MenuBarLayout.make(from: snap, now: now).mode {
            case .expanded:
                break   // bars, and — by the case's shape — no countdown
            case let .iconOnlyReset(reset, _):
                #expect(!reset.isEmpty, "\(name): a bars-less mode must carry a countdown")
            case .exhaustedUnknownReset:
                break   // bars-less too; the ⚠️ stands in for the number
            case let .error(five, seven, reset, which):
                // The bars-keeping error path (a broken date on a non-exhausted window) draws no
                // countdown either — `make` never fabricates one.
                #expect(five != nil || seven != nil, "\(name): error with no bars on the healthy path")
                #expect(reset == nil && which == nil, "\(name): error must not fabricate a countdown")
            case .usagePollingOff, .nothingMonitored:
                Issue.record("\(name): unexpected user-choice mode on the healthy path")
            case .weeklyResetUnknown:
                // Every fixture in the grid carries a real weekly reset, so this state cannot arise
                // here — reaching it would mean `make` lost a date it was given.
                Issue.record("\(name): weekly reset went missing from a snapshot that had one")
            }
        }
    }

    @Test func onlyExhaustedWindowsGetACountdown() {
        // The rule that replaced the severity table: a countdown appears exactly when a **main window is
        // exhausted** — not when a bar merely turns orange. Orange used to force the label; it no longer
        // does, and that is the behaviour change ADR-0091 is about.
        for (name, snap) in Self.severityGrid {
            let exhausted = CreditsPacing.mainWindowExhausted(in: snap)
            let barsLess: Bool = {
                switch MenuBarLayout.make(from: snap, now: now).mode {
                case .iconOnlyReset, .exhaustedUnknownReset: return true
                default: return false
                }
            }()
            #expect(barsLess == exhausted, "\(name): countdown presence must track exhaustion, nothing else")
        }
    }

    @Test func farBehindNeverForcesACountdown() {
        // `.farBehind` (blue — a large *surplus*) is calmer than green, so it must never be treated as
        // noisy. The retired `selectReset` suite was the only place this was pinned against the menu-bar
        // layout; the property survives here, and at the severity level in `PacingModelTests`
        // (`farBehindIsCalm`) and `PopupSectionVisibilityTests` (`onlyAheadAndExhaustedAreNonCalm`).
        //
        // The blue band is a **fixed span of real time**, not a fraction, so both windows need a surplus
        // wide enough in absolute terms: 5h threshold 2 h / 5 h = 0.40, 7d threshold 2 d / 7 d ≈ 0.2857.
        // 5h reset 1 h out → elapsed 0.80, usage 0.10 → surplus 0.70 > 0.40. 7d reset 3 d out → elapsed
        // ≈ 0.571, usage 0.05 → surplus ≈ 0.52 > 0.2857. The weekly gate is open at 5 % (`blueAllowed`),
        // which is what lets the 5h bar go blue at all.
        let snap = snapshot(fiveHourUtil: 10, sevenDayUtil: 5, fiveHourResetsIn: 3600)
        guard case let .expanded(five, seven) = MenuBarLayout.make(from: snap, now: now).mode else {
            Issue.record("expected .expanded for two far-behind bars")
            return
        }
        #expect(five?.severity == .farBehind)
        #expect(seven?.severity == .farBehind)
        #expect(five?.isCalm == true)
        #expect(seven?.isCalm == true)
    }
}


// MARK: - hide the calm bar (ADR-0086, supersedes #94)

/// The `hideCalmBar` choice: the bar the user picked is dropped from `.expanded` while it is **calm**,
/// leaving the other one alone; an **orange/red** bar is always kept, and the **error** state is never
/// affected. `.sevenDay` is the pre-ADR-0086 behaviour of #94; `.fiveHour` is its mirror image.
///
/// Fixture arithmetic (against the 7d window = 604 800 s, `snapshot()`'s reset defaults):
/// - 7d **green**: `sevenDayUtil: 30`, default reset 3 d out → elapsed ≈ 0.571 → usage < time → calm.
/// - 7d **orange**: `sevenDayUtil: 55, sevenDayResetsIn: 6 d` → elapsed ≈ 0.143 → ahead ≈ 0.41,
///   past the dynamic threshold `0.16·(1−0.143) ≈ 0.137` → noisy.
/// - 7d **red**: `sevenDayUtil: 100` → usageFraction ≥ 1 → exhausted.
/// The 5h side uses `fiveHourUtil: 50` (default 4 h reset → elapsed 0.2 → ahead 0.30, past threshold
/// 0.128 → noisy) for a **noisy** 5h bar, and `fiveHourUtil: 10` (usage 0.10 < time 0.20, and the gap
/// stays inside the far-behind band) for a **calm** one.
@Suite("MenuBarLayout hide the calm bar")
struct MenuBarLayoutHideCalmBarTests {

    /// Both bars stay optional here — this suite is precisely about one of them going away.
    ///
    /// Built through `expandedBars` rather than `make`: several cases below are deliberately exhausted
    /// (a red bar must never be elided as "calm"), and since ADR-0090 `make` answers an exhausted
    /// snapshot with the bars-less ``MenuBarMode/iconOnlyReset``. The calm-hiding rule itself lives in
    /// the bar-building half, which is exactly what this suite exercises.
    private func expanded(_ mode: MenuBarMode) -> (five: BarView?, seven: BarView?)? {
        guard case let .expanded(five, seven) = mode else {
            Issue.record("expected .expanded, got \(mode)")
            return nil
        }
        return (five, seven)
    }

    // MARK: .never

    @Test func defaultNeverKeepsBothBars() {
        // Regression: the default `.never` never elides either bar, however calm both are.
        let layout = MenuBarLayout.expandedBars(for: snapshot(fiveHourUtil: 10, sevenDayUtil: 30), now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.five != nil)
        #expect(e.seven != nil)
        #expect(e.five?.isCalm == true)    // confirm the fixture really is calm on both sides
        #expect(e.seven?.isCalm == true)
    }

    // MARK: .fiveHour (the mirror image)

    @Test func calmFiveHourIsHidden() {
        // Calm 5h + `.fiveHour` → 5h dropped, the 7-day bar stands alone.
        let layout = MenuBarLayout.expandedBars(
            for: snapshot(fiveHourUtil: 10, sevenDayUtil: 30), now: now, hideTopBar: .untilItNeedsAttention)
        guard let e = expanded(layout) else { return }
        #expect(e.five == nil)
        #expect(e.seven?.window == .sevenDay)
    }

    @Test func orangeFiveHourStaysVisible() {
        // Ahead-of-pace (orange) 5h is noisy → kept under `.fiveHour`.
        let layout = MenuBarLayout.expandedBars(
            for: snapshot(fiveHourUtil: 50, sevenDayUtil: 30), now: now, hideTopBar: .untilItNeedsAttention)
        guard let e = expanded(layout) else { return }
        #expect(e.five != nil)
        #expect(e.five?.severity == .ahead)
    }

    @Test func redFiveHourStaysVisible() {
        // Exhausted (red) 5h is noisy → kept under `.fiveHour`.
        let layout = MenuBarLayout.expandedBars(
            for: snapshot(fiveHourUtil: 100, sevenDayUtil: 30), now: now, hideTopBar: .untilItNeedsAttention)
        guard let e = expanded(layout) else { return }
        #expect(e.five != nil)
        #expect(e.five?.severity == .exhausted)
    }

    // MARK: session-idle

    @Test func idleFiveHourIsHiddenToo() {
        // The deliberate no-exemption case (ADR-0086): an idle 5h bar reports `.calm`, so `.fiveHour`
        // hides it as well — between sessions the widget shows the 7-day bar alone. This is the most
        // visible consequence of the default, so it is pinned here rather than left implicit.
        let layout = MenuBarLayout.expandedBars(
            for: idleSnapshot(sevenDayUtil: 20), now: now, hideTopBar: .untilItNeedsAttention)
        guard let e = expanded(layout) else { return }
        #expect(e.five == nil)
        #expect(e.seven != nil)
    }

    // MARK: the invariant

    @Test func atLeastOneBarSurvivesEveryCombination() {
        // The widget can never render empty: `TopBarHiding` names one window, so even when *both* bars
        // are calm only the chosen one goes. Swept over the modes × a calm/noisy grid on both windows,
        // plus the idle path, since that is where "everything is calm" is easiest to hit.
        let snapshots = [
            snapshot(fiveHourUtil: 10, sevenDayUtil: 30),    // both calm — the case that matters most
            snapshot(fiveHourUtil: 50, sevenDayUtil: 30),    // 5h noisy, 7d calm
            snapshot(fiveHourUtil: 10, sevenDayUtil: 100),   // 5h calm, 7d red
            snapshot(fiveHourUtil: 50, sevenDayUtil: 100),   // both noisy
            idleSnapshot(sevenDayUtil: 20),                  // idle 5h (always calm) + calm 7d
            idleSnapshot(sevenDayUtil: 100),                 // idle 5h + red 7d
        ]
        for mode in TopBarHiding.allCases {
            for snap in snapshots {
                let built = MenuBarLayout.expandedBars(for: snap, now: now, hideTopBar: mode)
                guard case let .expanded(five, seven) = built else { continue }
                #expect(five != nil || seven != nil, "both bars elided under \(mode)")
            }
        }
    }

    @Test func bothCalmUnderFiveHourLeavesTheSevenDayBar() {
        // The sharpest instance of the invariant: both bars calm and the calm 5h is the chosen one, so
        // exactly one bar is drawn — the 7-day one, calm as it is.
        let layout = MenuBarLayout.expandedBars(
            for: snapshot(fiveHourUtil: 10, sevenDayUtil: 30), now: now, hideTopBar: .untilItNeedsAttention)
        guard let e = expanded(layout) else { return }
        #expect(e.five == nil)
        #expect(e.seven != nil)
        #expect(e.seven?.isCalm == true)
    }

    // MARK: error state

    @Test func hidingStillAppliesOnTheBarsCarryingErrorPath() {
        // The **stale**-bars error phase this used to exercise is gone (ADR-0091 — past the threshold the
        // widget shows the bare glyph, so there is nothing left to hide). The one error state that still
        // carries bars is the broken-date data error on a non-exhausted window, and there the choice is
        // honoured like anywhere else: the bars come from `expandedBars`, which applied it before the
        // error was raised. Pinned so the two paths cannot drift into disagreeing about the same bar.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 10, resetsAt: resetsAt(inSeconds: 4 * 3600)),
            sevenDay: UsageWindow(utilization: 30, resetsAt: "not-a-date"))
        for mode in TopBarHiding.allCases {
            let layout = MenuBarLayout.make(from: snap, now: now, hideTopBar: mode)
            guard case let .error(five, seven, _, _) = layout.mode else {
                Issue.record("expected .error with bars under \(mode), got \(layout.mode)")
                continue
            }
            // Both bars are calm here, so `.untilItNeedsAttention` elides the 5h one; at least one always survives.
            #expect(five != nil || seven != nil, "both bars elided from the error state under \(mode)")
            #expect((five == nil) == (mode == .untilItNeedsAttention), "hideTopBar ignored on the error path: \(mode)")
        }
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

    @Test func limitReachedForcesRed() {
        // `spend_limit_reached` forces usage to 1 → an exhausted bar (red rung), regardless of the raw
        // used/limit fraction. Read off `creditsMarker` directly: with a **main** window exhausted this
        // state is also `isBlocked`, where the layout suppresses the icon entirely (see
        // `limitReachedIsSuppressedWhileBlocked`), so the colour rule has to be pinned at its source.
        let marker = MenuBarLayout.creditsMarker(
            for: creditsSnapshot(
                sevenDayUtil: 100, spend: spend(limit: 500, enabled: false, spendLimitReached: true)),
            now: now)
        #expect(marker?.bar?.usageFraction == 1)
        #expect(marker?.bar?.severity == .exhausted)
        #expect(marker?.isCalm == false)
    }

    @Test func limitReachedIsSuppressedWhileBlocked() {
        // ADR-0090: hitting the money cap satisfies the icon's trigger (`isActive` is
        // `enabled || spend_limit_reached`) **and** blocks the user (`creditsCanCover` is
        // `enabled && !spend_limit_reached`), so the two icons used to draw side by side — a pair
        // `ui-state-truth.md` already listed as impossible. The pause wins.
        let snap = creditsSnapshot(
            sevenDayUtil: 100, spend: spend(limit: 500, enabled: false, spendLimitReached: true))
        let layout = MenuBarLayout.make(
            from: snap, health: .healthy(lastSuccess: now), now: now, showCredits: true)
        #expect(layout.blockedPause == true)
        #expect(layout.credits == nil)
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

// MARK: - "Can we work?" — the bars-less answers (#194, #227, ADR-0090)

/// The menu bar answers one question, and the two answers that are not "yes, on the subscription"
/// both drop the bars for a single icon + countdown (``MenuBarMode/iconOnlyReset``). Which icon is
/// drawn is decided by the orthogonal `blockedPause`/`credits` fields, tested in the suites below —
/// here we pin the **mode** and the countdown each answer selects.
@Suite("MenuBarLayout can-we-work")
struct MenuBarLayoutCanWeWorkTests {

    /// Pull the associated values out of an `.iconOnlyReset` mode, or fail the test.
    private func iconOnly(_ layout: MenuBarLayout) -> (reset: String, which: LimitWindow)? {
        guard case let .iconOnlyReset(reset, which) = layout.mode else {
            Issue.record("expected .iconOnlyReset, got \(layout.mode)")
            return nil
        }
        return (reset, which)
    }

    @Test func activeBlockedHidesBars() {
        // Both main windows exhausted (no credits → fully blocked) → no bars, just the blocking-reset
        // countdown. With both exhausted the later token reset wins (last-stand): the 7d (3d out) over
        // the 5h (4h out). Unconditional since ADR-0090 — there is no toggle to switch it off.
        let snap = snapshot(fiveHourUtil: 100, sevenDayUtil: 100)
        let layout = MenuBarLayout.make(from: snap, now: now)
        guard let b = iconOnly(layout) else { return }
        #expect(b.which == .sevenDay)
        #expect(b.reset == "3d")   // 7d reset 3 days out, compact-days
    }

    @Test func fiveHourExhaustedAloneUsesFiveHourReset() {
        // Only the 5h window is exhausted (7d has quota) → the 5h reset drives the countdown, so the
        // label counts the 2 hours to *that* reset rather than the days to the 7-day one.
        let snap = snapshot(fiveHourUtil: 100, sevenDayUtil: 40, fiveHourResetsIn: 2 * 3600)
        let layout = MenuBarLayout.make(from: snap, now: now)
        guard let b = iconOnly(layout) else { return }
        #expect(b.which == .fiveHour)
        #expect(b.reset == "2h")
    }

    @Test func sevenDayExhaustedAloneUsesSevenDayReset() {
        // Only the 7d window is exhausted (5h has quota) → the 7d reset drives the countdown.
        let snap = snapshot(fiveHourUtil: 30, sevenDayUtil: 100, sevenDayResetsIn: 2 * 24 * 3600)
        let layout = MenuBarLayout.make(from: snap, now: now)
        guard let b = iconOnly(layout) else { return }
        #expect(b.which == .sevenDay)
        #expect(b.reset == "2d")
    }

    @Test func notExhaustedStaysExpanded() {
        // Neither window exhausted (both < 100) → we can work on the subscription: full bars.
        let snap = snapshot(fiveHourUtil: 80, sevenDayUtil: 90)
        let layout = MenuBarLayout.make(from: snap, now: now)
        guard case .expanded = layout.mode else {
            Issue.record("expected .expanded when not exhausted, got \(layout.mode)")
            return
        }
    }

    @Test func theCountdownIsUnconditional() {
        // There is no setting left that can suppress it (ADR-0091 retired `ResetCountdownMode`, whose
        // `.never` this test used to fight): a bars-less widget showing nothing beside the icon would
        // answer "can we work?" with silence. The countdown *is* the widget in this state.
        let snap = snapshot(fiveHourUtil: 100, sevenDayUtil: 100)
        guard let b = iconOnly(MenuBarLayout.make(from: snap, now: now)) else { return }
        #expect(b.reset == "3d")
    }

    // MARK: Paying — subscription spent, credits covering (ADR-0090)

    @Test func creditsCoveringAlsoHidesBars() {
        // A 7d at 100 % with active, uncapped credits is `subscriptionExhaustedWhileCovered`: work
        // continues, but on money. **Inverts the pre-ADR-0090 behaviour**, where this state kept its
        // bars — a red 100 % bar carries no pacing information, and the 5h bar refilling underneath a
        // blocking 7d changes nothing (you keep paying until the *blocking* window resets).
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 20, resetsAt: resetsAt(inSeconds: 4 * 3600)),
            sevenDay: UsageWindow(utilization: 100, resetsAt: resetsAt(inSeconds: 3 * 24 * 3600)),
            spend: SpendInfo(enabled: true, spendLimitReached: false))
        let layout = MenuBarLayout.make(from: snap, now: now)
        guard let b = iconOnly(layout) else { return }
        // The countdown is the moment the plan quota returns and credits stop being spent — the 7d
        // reset, never the credits' own month-end (`forSubscriptionExhausted` passes `creditsReset: nil`).
        #expect(b.which == .sevenDay)
        #expect(b.reset == "3d")
    }

    @Test func payingIsNotBlocked() {
        // The two answers are complements on an exhausted main window, so the paying state must never
        // carry the pause icon — that is what keeps the two icons mutually exclusive.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 20, resetsAt: resetsAt(inSeconds: 4 * 3600)),
            sevenDay: UsageWindow(utilization: 100, resetsAt: resetsAt(inSeconds: 3 * 24 * 3600)),
            spend: SpendInfo(enabled: true, spendLimitReached: false))
        let layout = MenuBarLayout.make(
            from: snap, health: .healthy(lastSuccess: now), now: now, showCredits: true)
        #expect(layout.blockedPause == false)
        // …and it must carry the currency icon, or the widget would be a bare countdown. The link is a
        // three-step implication across two types (`subscriptionExhaustedWhileCovered` ⇒
        // `mainWindowExhausted` ⇒ `anyBaseLimitExhausted`, plus `spend != nil`); pin it so the two
        // predicates cannot drift apart unnoticed.
        #expect(layout.credits != nil)
    }

    @Test func perModelExhaustionKeepsBars() {
        // A per-model window at 100 % triggers the credits *icon* (`anyBaseLimitExhausted`) but does
        // **not** gate work, so the bars must stay. This is why the paying branch keys on
        // `subscriptionExhaustedWhileCovered` rather than on the icon's own predicate.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 10, resetsAt: resetsAt(inSeconds: 4 * 3600)),
            sevenDay: UsageWindow(utilization: 36, resetsAt: resetsAt(inSeconds: 3 * 24 * 3600)),
            sevenDayOpus: UsageWindow(utilization: 100, resetsAt: resetsAt(inSeconds: 3 * 24 * 3600)),
            spend: SpendInfo(enabled: true, spendLimitReached: false))
        let layout = MenuBarLayout.make(
            from: snap, health: .healthy(lastSuccess: now), now: now, showCredits: true)
        guard case .expanded = layout.mode else {
            Issue.record("expected .expanded (per-model does not gate work), got \(layout.mode)")
            return
        }
        #expect(layout.credits != nil)   // the icon still shows — it just no longer hides the bars
    }

    // MARK: Idle and fallbacks

    @Test func idleBlockedHidesBars() {
        // The idle-blocked state (7d exhausted, no credits, no active 5h) also drops its grey idle bar
        // for the countdown-only widget.
        let snap = idleSnapshot(sevenDayUtil: 100)
        let layout = MenuBarLayout.make(from: snap, now: now)
        guard let b = iconOnly(layout) else { return }
        #expect(b.which == .sevenDay)
        #expect(b.reset == "4d")   // idle 7d reset 4 days out
    }

    // MARK: Exhausted with an unusable reset (ADR-0091)

    @Test func blockedWithBrokenResetIsExhaustedUnknownReset() {
        // Exhausted and blocked, but the only exhausted window's `resets_at` is unparseable → `forBlocked`
        // yields nil. The answer is the ⚠️-where-the-number-goes case, **not** a fall-through to the bars:
        // an exhausted window is never drawn as a bar, so the old fallback contradicted the rule it was
        // meant to serve. `which` names the one stuck window so the state is diagnosable.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 30, resetsAt: resetsAt(inSeconds: 4 * 3600)),
            sevenDay: UsageWindow(utilization: 100, resetsAt: "not-a-date"))
        let layout = MenuBarLayout.make(from: snap, health: .healthy(lastSuccess: now), now: now)
        #expect(layout.mode == .exhaustedUnknownReset(which: .sevenDay))
        // **No pause glyph**, even though `isBlocked` is true and we could justify one from the model's
        // side. On screen a pause asserting "you are blocked" beside a ⚠️ asserting "don't trust me"
        // reads as a broken widget — nothing there says the distrust covers only the *time*. So the
        // warning stands alone (ADR-0091); this is the one state where `isBlocked` does not draw it.
        #expect(layout.blockedPause == false)
    }

    @Test func fiveHourExhaustedWithBrokenResetNamesTheFiveHourWindow() {
        // The mirror case — the 5h window is the stuck one. Both windows exhausted with both dates broken
        // would name neither (there is no single window to point at), which is why `which` is optional.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 100, resetsAt: "garbage"),
            sevenDay: UsageWindow(utilization: 40, resetsAt: resetsAt(inSeconds: 3 * 24 * 3600)))
        #expect(MenuBarLayout.make(from: snap, now: now).mode
                == .exhaustedUnknownReset(which: .fiveHour))
    }

    @Test func bothExhaustedWithBrokenResetsNamesNeitherWindow() {
        // Both stuck → `which` is nil: naming one would imply the other is fine. Informational only —
        // the view draws no label for it either way.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 100, resetsAt: "garbage"),
            sevenDay: UsageWindow(utilization: 100, resetsAt: "not-a-date"))
        #expect(MenuBarLayout.make(from: snap, now: now).mode
                == .exhaustedUnknownReset(which: nil))
    }

    @Test func payingWithBrokenResetDrawsNeitherGlyph() {
        // The paying side reaches the same mode — and, like the blocked side, sheds its glyph. The
        // currency icon would state "work continues, on money" next to a ⚠️ disowning the payload;
        // suppressing it is the same call as suppressing the pause, for the same reason (ADR-0091).
        //
        // So this mode is the one place where neither icon appears despite `mainWindowExhausted`, and
        // the pair stays mutually exclusive trivially: both are off.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 30, resetsAt: resetsAt(inSeconds: 4 * 3600)),
            sevenDay: UsageWindow(utilization: 100, resetsAt: "not-a-date"),
            spend: SpendInfo(enabled: true, spendLimitReached: false))
        let layout = MenuBarLayout.make(
            from: snap, health: .healthy(lastSuccess: now), now: now, showCredits: true)
        #expect(layout.mode == .exhaustedUnknownReset(which: .sevenDay))
        #expect(layout.blockedPause == false)
        #expect(layout.credits == nil)
    }

    @Test func exhaustedUnknownResetNeverCarriesBars() {
        // The invariant that made this case necessary, stated directly: whatever else is true of a
        // broken-date exhausted window, it must not reach a mode with a bar in it.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 100, resetsAt: "garbage"),
            sevenDay: UsageWindow(utilization: 100, resetsAt: "not-a-date"))
        if case .expanded = MenuBarLayout.make(from: snap, now: now).mode {
            Issue.record("an exhausted window must never be drawn as a bar")
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

    @Test func pauseWhenBlocked() {
        // Fully blocked (both windows 100 %, no credits) → the bars-less mode AND the pause glyph.
        // Since ADR-0090 there is no "bars kept" variant to test: hiding is the only behaviour.
        let snap = snapshot(fiveHourUtil: 100, sevenDayUtil: 100)
        let layout = MenuBarLayout.make(from: snap, health: healthy, now: now)
        guard case .iconOnlyReset = layout.mode else {
            Issue.record("expected .iconOnlyReset when blocked, got \(layout.mode)")
            return
        }
        #expect(layout.blockedPause == true)
    }

    @Test func noPauseWhenNotBlocked() {
        // Neither window exhausted → not blocked, so the glyph stays off.
        let snap = snapshot(fiveHourUtil: 80, sevenDayUtil: 90)
        let layout = MenuBarLayout.make(from: snap, health: healthy, now: now)
        #expect(layout.blockedPause == false)
    }

    @Test func noPauseWhenCreditsCover() {
        // A 7d at 100 % with active, uncapped credits is `mainWindowExhausted` but NOT `isBlocked` (work
        // continues on the paid tier), so the pause glyph — which keys off `isBlocked` — stays off. The
        // bars go, but that is the *paying* answer, wearing the currency icon instead.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 20, resetsAt: resetsAt(inSeconds: 4 * 3600)),
            sevenDay: UsageWindow(utilization: 100, resetsAt: resetsAt(inSeconds: 3 * 24 * 3600)),
            spend: SpendInfo(enabled: true, spendLimitReached: false))
        let layout = MenuBarLayout.make(from: snap, health: healthy, now: now)
        #expect(layout.blockedPause == false)
    }

    @Test func creditsSuppressedWhileBlocked() {
        // ADR-0090: the money cap being hit satisfies both `isActive` (`enabled || spend_limit_reached`
        // → the icon showed) and `!creditsCanCover` (`enabled && !spend_limit_reached` → blocked), so the
        // pause glyph and the currency icon used to draw side by side. `ui-state-truth.md` already listed
        // that pair as impossible; the pause wins, because "no path to work" is the answer and a red ¤ is
        // a detail of *why*.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 100, resetsAt: resetsAt(inSeconds: 4 * 3600)),
            sevenDay: UsageWindow(utilization: 100, resetsAt: resetsAt(inSeconds: 3 * 24 * 3600)),
            spend: SpendInfo(enabled: false, spendLimitReached: true))
        let layout = MenuBarLayout.make(
            from: snap, health: healthy, now: now, showCredits: true)
        #expect(layout.blockedPause == true)
        #expect(layout.credits == nil)   // the icon is suppressed, not merely undrawn by the view
    }

    @Test func noPauseInErrorState() {
        // Polling failing past the glyph threshold → the bare `.error`, so no pause glyph even though the
        // last snapshot was blocked. This is the freshness split that keeps `.exhaustedUnknownReset`
        // separate from `.error`: the former rests on a provably-exhausted *fresh* snapshot, the latter on
        // data nothing is confirming — and a "blocked right now" must never be asserted from the latter.
        let snap = snapshot(fiveHourUtil: 100, sevenDayUtil: 100)
        let age = UsageHealth.glyphAfter(for: failing(for: 0)) + 1
        let layout = MenuBarLayout.make(from: snap, health: failing(for: age), now: now)
        #expect(layout.mode == .error(fiveHour: nil, sevenDay: nil, reset: nil, which: nil))
        #expect(layout.blockedPause == false)
    }

    @Test func staleExhaustedWithinGraceStaysBarsLessAndPaused() {
        // Inside the grace window the snapshot is still trusted, so an exhausted one routes through the
        // "can we work?" branches exactly as a fresh one does — bars-less, with the pause. The
        // pre-ADR-0091 behaviour was the opposite (rebuild stale bars through `expandedBars`), which drew
        // a red 100 % bar for precisely the users who are blocked.
        let snap = snapshot(fiveHourUtil: 100, sevenDayUtil: 100)
        let layout = MenuBarLayout.make(from: snap, health: failing(for: 60), now: now)
        guard case .iconOnlyReset = layout.mode else {
            Issue.record("expected .iconOnlyReset inside the grace window, got \(layout.mode)")
            return
        }
        #expect(layout.blockedPause == true)
    }

    @Test func idleBlockedHidesBarsAndKeepsPause() {
        // The idle-blocked state (7d exhausted, no credits, no active 5h) is also `isBlocked`, so it too
        // drops its grey idle bar for the countdown-only widget, with the glyph leading.
        let snap = idleSnapshot(sevenDayUtil: 100)
        let layout = MenuBarLayout.make(from: snap, health: healthy, now: now)
        guard case .iconOnlyReset = layout.mode else {
            Issue.record("expected .iconOnlyReset when idle-blocked, got \(layout.mode)")
            return
        }
        #expect(layout.blockedPause == true)
    }
}
