import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Shared fixtures

/// A fixed "current time" so every window's elapsed fraction is deterministic.
private let now = Date(timeIntervalSince1970: 1_000_000)

private func resetsAt(inSeconds seconds: TimeInterval) -> String {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    return iso.string(from: now.addingTimeInterval(seconds))
}

/// A snapshot whose 5-hour window is **deep behind pace** (util 5 % with 2 h left of the 5 h window,
/// i.e. `t ≈ 0.60`, surplus ≈ 0.55 — comfortably past the 0.40 threshold), so the 5-hour bar would be
/// blue on its own. The 7-day window is whatever the test needs, which is the only thing that varies.
private func snapshot(
    sevenDayUtil: Double,
    sevenDayResetsIn: TimeInterval = 5 * 24 * 3600,   // t ≈ 0.286 → any util above that is "ahead"
    sevenDayResetRaw: String? = nil,
    fiveHourUtil: Double = 5,
    sessionIdle: Bool = false,
    limits: [UsageLimit] = [],
    spend: SpendInfo? = nil
) -> UsageSnapshot {
    UsageSnapshot(
        fiveHour: UsageWindow(utilization: fiveHourUtil,
                              resetsAt: sessionIdle ? "" : resetsAt(inSeconds: 2 * 3600)),
        sevenDay: UsageWindow(utilization: sevenDayUtil,
                              resetsAt: sevenDayResetRaw ?? resetsAt(inSeconds: sevenDayResetsIn)),
        limits: limits,
        sessionIdle: sessionIdle,
        spend: spend)
}

/// The 5-hour bar's severity as the popup would build it for this snapshot.
private func fiveHourSeverity(_ snap: UsageSnapshot) -> PacingSeverity? {
    PopupLayout.make(from: snap, now: now, lastUpdate: now, interval: 60)
        .rows.first { $0.title == "5-hour" }?.bar.severity
}

// MARK: - PacingModel.weeklyHasHeadroom

@Suite("PacingModel.weeklyHasHeadroom")
struct WeeklyHasHeadroomTests {

    /// The gate is open exactly while the 7-day window is itself calm — its bucket is blue or green.
    /// `t ≈ 0.286` here, so a util below that is behind pace and anything above is ahead.
    @Test func openOnlyWhileWeekIsNotAheadOfPace() {
        #expect(PacingModel.weeklyHasHeadroom(in: snapshot(sevenDayUtil: 2), now: now))    // deep behind
        #expect(PacingModel.weeklyHasHeadroom(in: snapshot(sevenDayUtil: 25), now: now))   // green
        #expect(!PacingModel.weeklyHasHeadroom(in: snapshot(sevenDayUtil: 33), now: now))  // yellow
        #expect(!PacingModel.weeklyHasHeadroom(in: snapshot(sevenDayUtil: 70), now: now))  // orange
        #expect(!PacingModel.weeklyHasHeadroom(in: snapshot(sevenDayUtil: 100), now: now)) // red
    }

    /// Exhaustion closes the gate through the `usageFraction < 1` term even when the window still reads
    /// as on-pace — a just-reset 100 % week is spent, whatever its elapsed fraction says.
    @Test func exhaustedWeekClosesTheGateEvenWhenOnPace() {
        // 7d at 100 % with almost the whole window elapsed → `t` ≈ 1, so pacing is `.onPaceOrBehind`.
        let justReset = snapshot(sevenDayUtil: 100, sevenDayResetsIn: 60)
        #expect(!PacingModel.weeklyHasHeadroom(in: justReset, now: now))
    }

    /// The boundary is strict: `usageFraction < 1`, so 99.9 % still has headroom and 100 % does not.
    @Test func exhaustionBoundaryIsStrict() {
        #expect(PacingModel.weeklyHasHeadroom(in: snapshot(sevenDayUtil: 99.9, sevenDayResetsIn: 60), now: now))
        #expect(!PacingModel.weeklyHasHeadroom(in: snapshot(sevenDayUtil: 100, sevenDayResetsIn: 60), now: now))
    }

    /// **Closed by default.** An unparseable 7-day reset makes the bar builders fall back to
    /// `resetsAt = now` → `timeFraction == 1.0`, a maximally-"behind" week that would falsely *open*
    /// the gate. Without a trustworthy weekly clock the advice is withheld instead.
    @Test func brokenWeeklyResetClosesTheGate() {
        #expect(!PacingModel.weeklyHasHeadroom(in: snapshot(sevenDayUtil: 10, sevenDayResetRaw: "not-a-date"), now: now))
        #expect(!PacingModel.weeklyHasHeadroom(in: snapshot(sevenDayUtil: 10, sevenDayResetRaw: ""), now: now))
        #expect(!PacingModel.weeklyHasHeadroom(in: snapshot(sevenDayUtil: 10, sevenDayResetRaw: "null"), now: now))
    }

    /// A session-idle snapshot still has a live 7-day window, so the gate is decided by the week alone.
    @Test func sessionIdleDoesNotChangeTheWeeklyVerdict() {
        #expect(PacingModel.weeklyHasHeadroom(in: snapshot(sevenDayUtil: 25, sessionIdle: true), now: now))
        #expect(!PacingModel.weeklyHasHeadroom(in: snapshot(sevenDayUtil: 70, sessionIdle: true), now: now))
    }
}

// MARK: - The gate applied to the bars

@Suite("Weekly gate — 5-hour bar")
struct WeeklyGateFiveHourTests {

    /// The whole point: the same deep-behind 5-hour window is blue while the week has headroom and
    /// plain green once the week runs ahead of pace. Green, not yellow — the 5-hour window's own pace
    /// really is calm; only the "there is room to push" advice is withdrawn.
    @Test func fiveHourBlueFollowsTheWeek() {
        #expect(fiveHourSeverity(snapshot(sevenDayUtil: 2)) == .farBehind)    // week deep behind → blue
        #expect(fiveHourSeverity(snapshot(sevenDayUtil: 25)) == .farBehind)   // week green → blue
        #expect(fiveHourSeverity(snapshot(sevenDayUtil: 33)) == .calm)        // week yellow → green
        #expect(fiveHourSeverity(snapshot(sevenDayUtil: 70)) == .calm)        // week orange → green
        #expect(fiveHourSeverity(snapshot(sevenDayUtil: 100)) == .calm)       // week red    → green
    }

    /// The 7-day bar never gates on itself — a deep-behind week stays blue.
    /// Needs a well-elapsed week: at `t = 0.286` the surplus cannot clear the 0.2857 threshold at all
    /// (`surplus ≤ t`), so this uses 2 days left of 7 → `t ≈ 0.714`, surplus ≈ 0.694.
    @Test func sevenDayNeverGatesOnItself() {
        let deepBehindWeek = snapshot(sevenDayUtil: 2, sevenDayResetsIn: 2 * 24 * 3600)
        let sevenDay = PopupLayout.make(from: deepBehindWeek, now: now, lastUpdate: now, interval: 60)
            .rows.first { $0.title == "7-day" }
        #expect(sevenDay?.bar.blueAllowed == true)
        #expect(sevenDay?.bar.severity == .farBehind)
    }

    /// A broken weekly reset closes the gate for the 5-hour bar too (the `false` default flows through).
    @Test func brokenWeeklyResetKeepsFiveHourGreen() {
        #expect(fiveHourSeverity(snapshot(sevenDayUtil: 10, sevenDayResetRaw: "not-a-date")) == .calm)
    }

    /// The menu bar applies the identical gate, so the two surfaces cannot disagree.
    @Test func menuBarAppliesTheSameGate() {
        guard let (openFive, _) = claudeBars(
            MenuBarLayout.make(from: snapshot(sevenDayUtil: 25), now: now).mode),
              let (closedFive, _) = claudeBars(
            MenuBarLayout.make(from: snapshot(sevenDayUtil: 70), now: now).mode) else { return }
        // Both bars are optional in `.expanded` since ADR-0086, but neither `make` call above asks for
        // any hiding (`hideCalmBar` defaults to `.never`), so the 5h bar is always there.
        #expect(openFive?.layout.severity == .farBehind)
        #expect(closedFive?.layout.severity == .calm)
    }
}

// MARK: - Per-model rows

@Suite("Weekly gate — per-model rows")
struct WeeklyGatePerModelTests {

    /// Per-model windows never render blue, **whatever the week is doing** — they are slices of the
    /// very seven-day limit blue talks about, so "the week has room to push" would be advice addressed
    /// to itself (reason 2 on `BarLayout.blueAllowed`).
    ///
    /// This replaces a test that pinned the opposite arrangement: per-model rows used to carry the
    /// weekly gate, and its docblock claimed that "the journal has no such gate — this is what keeps
    /// the recorded bucket equal to the pixel the user saw". Both halves were wrong. The popup did have
    /// a second gate (`PopupBarView.isBaseLimit`, view-side and invisible to the model), so an *open*
    /// week produced exactly the disagreement the comment promised was impossible — 2 211 blue scoped
    /// samples in a journal whose popup was painting them green. The open-week case below is the one
    /// that used to fail; the closed-week case passed for the wrong reason.
    @Test func perModelRowsNeverAllowBlue() {
        func opusRow(weeklyUtil: Double) -> LimitRow? {
            let snap = UsageSnapshot(
                fiveHour: UsageWindow(utilization: 5, resetsAt: resetsAt(inSeconds: 2 * 3600)),
                sevenDay: UsageWindow(utilization: weeklyUtil, resetsAt: resetsAt(inSeconds: 5 * 24 * 3600)),
                sevenDayOpus: UsageWindow(utilization: 2, resetsAt: resetsAt(inSeconds: 5 * 24 * 3600)),
                limits: [],
                spend: nil)
            return PopupLayout.make(from: snap, now: now, lastUpdate: now, interval: 60)
                .rows.first { $0.title == "Opus" }
        }
        // Week ahead of pace (gate would be closed anyway) and week calm with room to spare (gate
        // open) — a barely-used Opus window is deep behind pace in both, and stays green in both.
        for weeklyUtil in [70.0, 10.0] {
            let opus = opusRow(weeklyUtil: weeklyUtil)
            #expect(opus?.bar.blueAllowed == false)
            #expect(opus?.bar.severity == .calm)
        }
    }

    /// The scoped rows go the same way, and they are where it actually bit: `Fable` sat far behind pace
    /// for 38 % of the maintainer's August journal.
    @Test func scopedRowsNeverAllowBlue() {
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 5, resetsAt: resetsAt(inSeconds: 2 * 3600)),
            sevenDay: UsageWindow(utilization: 10, resetsAt: resetsAt(inSeconds: 5 * 24 * 3600)),
            limits: [UsageLimit(
                kind: "weekly_scoped", group: "weekly", percent: 1, severity: "normal",
                resetsAt: resetsAt(inSeconds: 5 * 24 * 3600), isActive: false,
                modelDisplayName: "Fable")],
            spend: nil)
        let fable = PopupLayout.make(from: snap, now: now, lastUpdate: now, interval: 60)
            .rows.first { $0.title == "Fable" }
        #expect(fable?.bar.blueAllowed == false)
        #expect(fable?.bar.severity == .calm)
    }
}

// MARK: - Idle pill

@Suite("Weekly gate — idle pill")
struct WeeklyGateIdleTests {

    private func idleRow(_ snap: UsageSnapshot) -> LimitRow? {
        PopupLayout.make(from: snap, now: now, lastUpdate: now, interval: 60)
            .rows.first { $0.sessionIdle }
    }

    /// The idle row carries **no weekly verdict** since #381 — the pill is green whenever ready, on both
    /// surfaces, so neither layout threads the gate through an inert bar any more.
    ///
    /// This replaces three tests that pinned the old three-way pill (blue while the week had headroom,
    /// green once it ran ahead, grey when blocked). What is pinned instead is the *absence*: whatever the
    /// week is doing, an idle row differs only by `sessionBlocked`. A future change that reintroduced a
    /// weekly-dependent idle colour would have to touch this test, which is the point.
    @Test func idleRowDoesNotVaryWithTheWeek() {
        let calmWeek = idleRow(snapshot(sevenDayUtil: 25, sessionIdle: true))
        let hotWeek = idleRow(snapshot(sevenDayUtil: 70, sessionIdle: true))
        #expect(calmWeek?.sessionIdle == true)
        #expect(hotWeek?.sessionIdle == true)
        // Neither is blocked — the only axis idle still has.
        #expect(calmWeek?.sessionBlocked == false)
        #expect(hotWeek?.sessionBlocked == false)
        // And the inert bar is identical, gate or no gate.
        #expect(calmWeek?.bar.blueAllowed == hotWeek?.bar.blueAllowed)
    }

    /// Blocked is a separate axis and still wins — it means "no path to start", which is the one thing
    /// the idle pill still distinguishes (grey rather than green).
    @Test func blockedIdleIsStillItsOwnState() {
        // 7d exhausted with no credits → blocked.
        let blocked = snapshot(sevenDayUtil: 100, sessionIdle: true)
        #expect(idleRow(blocked)?.sessionBlocked == true)
    }

    /// The menu bar's idle bar agrees with the popup's: same two states, no weekly verdict on either.
    /// The surfaces used to carry the flag independently, which is exactly how they could have drifted.
    @Test func menuBarIdleBarMatchesThePopup() {
        func idleBar(_ snap: UsageSnapshot) -> BarView? {
            claudeBars(MenuBarLayout.make(from: snap, now: now).mode)?.five
        }
        for util in [25.0, 70.0] {
            let snap = snapshot(sevenDayUtil: util, sessionIdle: true)
            #expect(idleBar(snap)?.idle == true)
            #expect(idleBar(snap)?.blocked == idleRow(snap)?.sessionBlocked)
        }
    }

    /// An idle bar never renders the pacing blue whatever the week does — it has no pacing at all.
    @Test func idleBarNeverRendersPacingBlue() {
        #expect(idleRow(snapshot(sevenDayUtil: 25, sessionIdle: true))?.bar.blueAllowed == false)
        #expect(idleRow(snapshot(sevenDayUtil: 25, sessionIdle: true))?.bar.severity == .calm)
    }
}

// MARK: - Journal parity

@Suite("Weekly gate — journal matches the UI")
struct WeeklyGateJournalTests {

    private func h5Sample(_ snap: UsageSnapshot) -> WindowSample? {
        guard case let .usage(sample) = JournalRecord.usage(from: snap, now: now) else { return nil }
        return sample.h5
    }

    /// The invariant this change buys: the journal's bucket and the rendered severity agree, because
    /// both read the same `blueAllowed`.
    @Test func journalBucketMatchesRenderedSeverity() {
        let open = snapshot(sevenDayUtil: 25)
        #expect(h5Sample(open)?.sev == .blue)
        #expect(fiveHourSeverity(open) == .farBehind)

        let closed = snapshot(sevenDayUtil: 70)
        #expect(h5Sample(closed)?.sev == .green)
        #expect(fiveHourSeverity(closed) == .calm)
    }

    /// Regression for the ordering trap: `d7` is built at the same expression level as `h5` inside the
    /// `UsageSample` literal, so the gate has to be hoisted into a `let` first. If someone moves it back
    /// inline, the 5-hour sample stops seeing the exhausted week and this flips to `.blue`.
    @Test func exhaustedWeekIsVisibleToTheFiveHourSample() {
        #expect(h5Sample(snapshot(sevenDayUtil: 100))?.sev == .green)
    }

    /// The same invariant on the rows that broke it. It was only ever asserted for `h5` above, which is
    /// exactly how the per-model mismatch survived: the journal factory and the popup were compared on
    /// the one window where they happened to agree.
    @Test func journalBucketMatchesRenderedSeverityForPerModelRows() {
        // A week with plenty of headroom — the state that used to make scoped rows blue in the file
        // while the popup drew them green.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 5, resetsAt: resetsAt(inSeconds: 2 * 3600)),
            sevenDay: UsageWindow(utilization: 10, resetsAt: resetsAt(inSeconds: 5 * 24 * 3600)),
            sevenDayOpus: UsageWindow(utilization: 2, resetsAt: resetsAt(inSeconds: 5 * 24 * 3600)),
            limits: [UsageLimit(
                kind: "weekly_scoped", group: "weekly", percent: 1, severity: "normal",
                resetsAt: resetsAt(inSeconds: 5 * 24 * 3600), isActive: false,
                modelDisplayName: "Fable")],
            spend: nil)
        guard case let .usage(sample) = JournalRecord.usage(from: snap, now: now) else {
            Issue.record("expected a usage record"); return
        }
        let rows = PopupLayout.make(from: snap, now: now, lastUpdate: now, interval: 60).rows
        #expect(sample.opus?.sev == .green)
        #expect(rows.first { $0.title == "Opus" }?.bar.severity == .calm)
        #expect(sample.scoped.first?.sev == .green)
        #expect(rows.first { $0.title == "Fable" }?.bar.severity == .calm)
    }

    /// The 7-day sample itself is ungated — a deep-behind week is still recorded blue.
    @Test func sevenDaySampleStaysBlue() {
        let deepBehindWeek = snapshot(sevenDayUtil: 2, sevenDayResetsIn: 2 * 24 * 3600)
        guard case let .usage(sample) = JournalRecord.usage(from: deepBehindWeek, now: now) else {
            Issue.record("expected a usage record"); return
        }
        #expect(sample.d7?.sev == .blue)
    }
}

// MARK: - Stub-frame parity

/// The two new stub frames must actually produce the states their summaries promise — a stub whose
/// fixture drifts is worse than no stub, because the manual check then "passes" against the wrong thing.
@Suite("Weekly gate — stub frames")
struct WeeklyGateStubFrameTests {

    /// `weekly-gate`: 5h deep behind (u = 5 %, 2 h left of 5 h → t = 60 %, surplus 55 pp) with the week
    /// exhausted. The 5-hour bar must be green, and the frame must NOT read as blocked-with-hidden-bars
    /// (`pauseHidesBars` is off by default, but the row itself must still be a normal 5h row).
    @Test func weeklyGateFrameShowsAGreenFiveHourBar() {
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 5, resetsAt: resetsAt(inSeconds: 2 * 3600)),
            sevenDay: UsageWindow(utilization: 100, resetsAt: resetsAt(inSeconds: 5 * 24 * 3600)),
            limits: [],
            spend: nil)
        let five = PopupLayout.make(from: snap, now: now, lastUpdate: now, interval: 60)
            .rows.first { $0.title == "5-hour" }
        #expect(five?.sessionIdle == false)          // a real bar, not the idle placeholder
        #expect(five?.bar.blueAllowed == false)      // gate shut by the exhausted week
        #expect(five?.bar.severity == .calm)         // …so green, despite the 55 pp surplus
    }

    /// `idle-week-hot`: no 5h session, week at 70 % with ~5 days left (ahead of pace, not exhausted).
    /// The idle pill must be green, not the grey blocked one (which needs an exhausted week credits
    /// cannot cover).
    ///
    /// The frame used to be this suite's *differentiator* — green here against blue in the `idle` frame,
    /// which is what the weekly gate bought on the idle pill. Since #381 the pill is green in both, so
    /// what this pins now is only that a hot week does not reach the **blocked** state; the pair of stub
    /// frames is no longer distinguishable by pill colour.
    @Test func idleWeekHotFrameShowsAGreenPill() {
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 70, resetsAt: resetsAt(inSeconds: 5 * 24 * 3600)),
            limits: [],
            sessionIdle: true,
            spend: nil)
        let idle = PopupLayout.make(from: snap, now: now, lastUpdate: now, interval: 60)
            .rows.first { $0.sessionIdle }
        #expect(idle != nil)
        #expect(idle?.sessionBlocked == false)   // not the grey state → green
    }
}
