import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - rollForward (ADR-0107)

/// The reconstruction that replaces the drifting `now + 7d` estimate during a weekly API blackout.
///
/// Every case is built from absolute instants, so no clock, locale or time zone is involved — the
/// same discipline the rest of the `ResetClock` suite follows.
@Suite("ResetClock.rollForward")
struct RollForwardTests {

    /// `2026-08-18T07:00:00.306761Z` — a real anchor lifted verbatim from the journal, microseconds
    /// and all, so the fixtures exercise the precision the server actually sends.
    private static let liveAnchor = Date(timeIntervalSince1970: 1_787_036_400.306761)

    private static let week: TimeInterval = 604_800

    @Test func rollsOneWeekWhenTheAnchorHasJustPassed() {
        let anchor = Self.liveAnchor
        let now = anchor.addingTimeInterval(3 * 3600)      // three hours into the blackout
        #expect(ResetClock.rollForward(anchor: anchor, by: .sevenDay, until: now)
                == anchor.addingTimeInterval(Self.week))
    }

    /// The vacation case: the app was closed for a month, so the anchor is many windows stale and a
    /// single `+7d` would still be in the past. The closed form must jump straight to the right
    /// multiple rather than stepping.
    @Test func rollsWholeWeeksAcrossALongAbsence() {
        let anchor = Self.liveAnchor
        // 30 days on: four weeks have fully elapsed, so the fifth lands in the future.
        #expect(ResetClock.rollForward(anchor: anchor, by: .sevenDay,
                                       until: anchor.addingTimeInterval(30 * 86_400))
                == anchor.addingTimeInterval(5 * Self.week))
        // And a far longer absence — the same single computation, no iteration.
        #expect(ResetClock.rollForward(anchor: anchor, by: .sevenDay,
                                       until: anchor.addingTimeInterval(400 * 86_400))
                == anchor.addingTimeInterval(58 * Self.week))
    }

    /// A reset **at** `now` has already happened, so the answer is the next one — never the anchor
    /// itself, which would render as a countdown of zero.
    @Test func anExactBoundaryRollsRatherThanReturningTheAnchor() {
        let anchor = Self.liveAnchor
        #expect(ResetClock.rollForward(anchor: anchor, by: .sevenDay,
                                       until: anchor.addingTimeInterval(Self.week))
                == anchor.addingTimeInterval(2 * Self.week))
    }

    /// **The regression this tolerance exists for.** The first poll of a blackout lands in the same
    /// second as the reset, leaving the anchor a fraction of a second in the *future*. Without the
    /// grace it is returned unchanged and the bar claims a reset 0.3 s away — pinning the marker to
    /// 100 %. Measured on two independent journals, the naive form was wrong by exactly one week.
    @Test func anAnchorAFractionOfASecondAheadStillRolls() {
        let anchor = Self.liveAnchor
        let now = anchor.addingTimeInterval(-0.306761)   // the poll fired 0.31 s before the reset
        let rolled = ResetClock.rollForward(anchor: anchor, by: .sevenDay, until: now)
        #expect(rolled == anchor.addingTimeInterval(Self.week))
        #expect(rolled != anchor)                        // what a grace-less version returns
    }

    /// The grace is one-sided. An anchor comfortably ahead of `now` is a healthy week, and rolling
    /// it would skip a whole cycle.
    @Test func anAnchorWellAheadIsReturnedUntouched() {
        let anchor = Self.liveAnchor
        let now = anchor.addingTimeInterval(-2 * 86_400)   // two days still to go
        #expect(ResetClock.rollForward(anchor: anchor, by: .sevenDay, until: now) == anchor)
    }

    /// The boundary of the tolerance itself: exactly `resetGrace` ahead counts as elapsed.
    @Test func theGraceBoundaryCountsAsElapsed() {
        let anchor = Self.liveAnchor
        let now = anchor.addingTimeInterval(-ResetClock.resetGrace)
        #expect(ResetClock.rollForward(anchor: anchor, by: .sevenDay, until: now)
                == anchor.addingTimeInterval(Self.week))
    }

    /// A corrupted anchor (epoch zero) must not produce a confident-looking date.
    @Test func anAbsurdlyStaleAnchorRefusesRatherThanGuessing() {
        #expect(ResetClock.rollForward(anchor: Date(timeIntervalSince1970: 0),
                                       by: .sevenDay, until: Self.liveAnchor) == nil)
    }

    /// **DST regression guard.** `rollForward` is pure `TimeInterval` arithmetic, so a transition
    /// cannot move it; this fails if someone later reimplements it with `Calendar`, whose day-of-DST
    /// is 23 or 25 hours long. Rolls across Europe/Kyiv's 2026-10-25 EEST→EET boundary and asserts
    /// both the exact instant and that the UTC wall clock and weekday are unchanged.
    @Test func wholeWeeksAreUnaffectedByADaylightSavingTransition() throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let anchor = try #require(iso.date(from: "2026-10-20T07:00:00Z"))   // before the transition
        // Ten days on is past Kyiv's 25 Oct switch, so the second week is the one that lands ahead.
        let now = anchor.addingTimeInterval(10 * 86_400)
        let rolled = try #require(ResetClock.rollForward(anchor: anchor, by: .sevenDay, until: now))
        #expect(rolled == anchor.addingTimeInterval(2 * Self.week))

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.hour, .minute, .second, .weekday], from: rolled)
        #expect(parts.hour == 7 && parts.minute == 0 && parts.second == 0)
        #expect(parts.weekday == utc.dateComponents([.weekday], from: anchor).weekday)
    }

    /// The function is not weekly-specific — it steps by whatever period the window declares.
    @Test func stepsByTheWindowsOwnPeriod() {
        let anchor = Self.liveAnchor
        #expect(ResetClock.rollForward(anchor: anchor, by: .fiveHour,
                                       until: anchor.addingTimeInterval(60))
                == anchor.addingTimeInterval(TimeInterval(LimitWindow.fiveHour.durationSeconds)))
    }

    /// Replays the three real blackouts from the maintainer's journal: each anchor is the last
    /// server-supplied reset before the blackout, and the expectation is the first one the server
    /// sent after it. Reconstruction has to land within a second of the truth — measured ±0.25 s.
    /// (anchor, truth) as epoch seconds, verbatim from `usage-journal-2026-08.jsonl`: the last
    /// server-supplied reset before each blackout, and the first one after it.
    private static let recordedBlackouts: [(anchor: Double, truth: Double)] = [
        (1_785_826_800.191579, 1_786_431_600.430315),   // 08-04 → 08-11
        (1_786_431_600.326750, 1_787_036_400.457361),   // 08-11 → 08-18
        (1_787_036_400.306761, 1_787_641_200.058036),   // 08-18 → 08-25
    ]

    @Test(arguments: RollForwardTests.recordedBlackouts)
    func matchesTheServerOnEveryRecordedBlackout(blackout: (anchor: Double, truth: Double)) throws {
        let anchor = Date(timeIntervalSince1970: blackout.anchor)
        let truth = Date(timeIntervalSince1970: blackout.truth)
        // Sample the blackout at its start, middle and end — the reconstruction must not drift.
        for offset: TimeInterval in [0, 3 * 3600, 5 * 3600] {
            let rolled = try #require(ResetClock.rollForward(
                anchor: anchor, by: .sevenDay, until: anchor.addingTimeInterval(offset)))
            #expect(abs(rolled.timeIntervalSince(truth)) < 1)
        }
    }
}

// MARK: - ResetSource

@Suite("ResetSource")
struct ResetSourceTests {

    /// Only an untouched server fact may become the anchor future reconstructions roll from — the
    /// invariant that stops the reconstruction feeding on its own output.
    @Test func onlyUnrolledServerFactsAreAnchorWorthy() {
        #expect(ResetSource.server.isUnrolledServerFact)
        #expect(ResetSource.limits.isUnrolledServerFact)          // still the server, other field
        #expect(!ResetSource.reconstructed.isUnrolledServerFact)
        #expect(!ResetSource.unknown.isUnrolledServerFact)
        #expect(!ResetSource.serverRolled.isUnrolledServerFact)   // ours the moment we roll it
        #expect(!ResetSource.limitsRolled.isUnrolledServerFact)
        #expect(!ResetSource.reconstructedRolled.isUnrolledServerFact)
    }

    @Test func rollingAppendsTheSuffixAndIsIdempotent() {
        #expect(ResetSource.server.rolled() == .serverRolled)
        #expect(ResetSource.limits.rolled() == .limitsRolled)
        #expect(ResetSource.reconstructed.rolled() == .reconstructedRolled)
        // Already rolled: the suffix records *that* a roll happened, not how many times.
        #expect(ResetSource.serverRolled.rolled() == .serverRolled)
        // Nothing to roll when there is no date at all.
        #expect(ResetSource.unknown.rolled() == .unknown)
    }

    /// The journal stores `rawValue`, so these strings are a data format — changing one silently
    /// reinterprets every archived line.
    @Test func rawValuesAreTheJournalFormat() {
        #expect(ResetSource.server.rawValue == "server")
        #expect(ResetSource.limits.rawValue == "limits")
        #expect(ResetSource.reconstructed.rawValue == "reconstructed")
        #expect(ResetSource.unknown.rawValue == "unknown")
        #expect(ResetSource.serverRolled.rawValue == "server-rolled")
        #expect(ResetSource.limitsRolled.rawValue == "limits-rolled")
        #expect(ResetSource.reconstructedRolled.rawValue == "reconstructed-rolled")
        #expect(ResetSource.allCases.count == 7)
    }

    @Test func isRolledMatchesTheSuffix() {
        for source in ResetSource.allCases {
            #expect(source.isRolled == source.rawValue.hasSuffix("-rolled"))
        }
    }
}

// MARK: - Provenance survives the render pipeline

/// `UsageSnapshot`'s memberwise init defaults `sevenDayResetSource` so ~90 synthetic fixtures stay
/// unchanged — which means a production site that rebuilds a snapshot and *forgets* the field
/// compiles silently and relabels a reconstruction as a server fact. Nothing but a test catches it,
/// so here it is: every transform between decode and render must carry provenance through.
@Suite("Snapshot rebuilders preserve the reset source")
struct ResetSourcePreservationTests {

    private static let now = Date(timeIntervalSince1970: 1_000_000)

    private static func iso(_ offset: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: now.addingTimeInterval(offset))
    }

    /// `WeeklyUtilization.applied(to:)` is the **first** transform in `App.render`, and it rewrites
    /// the weekly window — so it is the likeliest place to drop the field, and the most damaging:
    /// it runs on the majority of polls.
    @Test func weeklyUtilizationOverlayKeepsIt() {
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 10, resetsAt: Self.iso(3600)),
            sevenDay: UsageWindow(utilization: 50, resetsAt: Self.iso(7200)),
            sevenDayResetSource: .reconstructed)
        let weekly = WeeklyUtilization(
            raw: 50, effective: 50.4, source: .interpolated, ratio: 9.8, sampleCount: 15)
        #expect(weekly.applied(to: snapshot).sevenDayResetSource == .reconstructed)
    }

    /// `optimisticReset` leaves a future window alone — including its provenance.
    @Test func optimisticResetKeepsItWhenNothingRolls() {
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 10, resetsAt: Self.iso(3600)),
            sevenDay: UsageWindow(utilization: 50, resetsAt: Self.iso(7200)),
            sevenDayResetSource: .reconstructed)
        #expect(ResetClock.optimisticReset(snapshot, now: Self.now).sevenDayResetSource
                == .reconstructed)
    }

    /// And when it *does* roll, the provenance gains the suffix rather than being replaced — a
    /// reconstruction that has since elapsed is two steps from the last server fact, and says so.
    @Test func optimisticResetAppendsTheRolledSuffix() {
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 10, resetsAt: Self.iso(3600)),
            sevenDay: UsageWindow(utilization: 50, resetsAt: Self.iso(-1)),
            sevenDayResetSource: .reconstructed)
        #expect(ResetClock.optimisticReset(snapshot, now: Self.now).sevenDayResetSource
                == .reconstructedRolled)
    }

    /// Only an untouched server fact may become the next anchor. This is the invariant that stops a
    /// blackout's reconstruction being fed back in as if the server had confirmed it.
    @Test func onlyServerFactsWouldBeAnchored() {
        // The exact predicate `PollingEngine.advance` gates the anchor write on.
        #expect(ResetSource.server.isUnrolledServerFact)
        #expect(!ResetSource.reconstructed.isUnrolledServerFact)
        #expect(!ResetSource.serverRolled.isUnrolledServerFact)
    }
}

// MARK: - The anchor the polling loop keeps

/// `PollState.lastKnownSevenDayReset` is what makes a reconstruction possible across polls and
/// across relaunches. What it must *never* do is absorb a value this app derived: a blackout lasts
/// hours, so an anchor that drifted by one poll would keep drifting by every poll after it.
@Suite("PollingEngine — reconstruction anchor")
struct ReconstructionAnchorTests {

    private static let t0 = Date(timeIntervalSince1970: 1_000_000)
    private static let serverReset = "2026-06-28T00:00:00+00:00"

    private static func snapshot(source: ResetSource, resetsAt: String = serverReset) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageWindow(utilization: 10, resetsAt: "2026-06-21T05:30:00+00:00"),
            sevenDay: UsageWindow(utilization: 20, resetsAt: resetsAt),
            sevenDayResetSource: source)
    }

    @Test func aServerSuppliedResetBecomesTheAnchor() {
        let next = PollingEngine.advance(
            previous: PollState(), outcome: .success(Self.snapshot(source: .server)),
            claudeActive: true, now: Self.t0)
        #expect(next.lastKnownSevenDayReset == ResetClock.parse(Self.serverReset))
    }

    /// A `limits[]` fill is still the server talking, just through a different field.
    @Test func aLimitsFillAlsoAnchors() {
        let next = PollingEngine.advance(
            previous: PollState(), outcome: .success(Self.snapshot(source: .limits)),
            claudeActive: true, now: Self.t0)
        #expect(next.lastKnownSevenDayReset == ResetClock.parse(Self.serverReset))
    }

    /// **The self-feeding guard.** A reconstructed date must not overwrite the anchor it was itself
    /// derived from — otherwise each blackout poll would build on the previous poll's estimate.
    @Test func aReconstructedResetDoesNotAnchor() {
        var previous = PollState()
        previous.lastKnownSevenDayReset = Self.t0
        let next = PollingEngine.advance(
            previous: previous,
            outcome: .success(Self.snapshot(source: .reconstructed, resetsAt: "2026-07-05T00:00:00+00:00")),
            claudeActive: true, now: Self.t0)
        #expect(next.lastKnownSevenDayReset == Self.t0)   // untouched
    }

    /// Nor does a locally-rolled one, for the same reason: the roll was ours, not the server's.
    @Test func aRolledResetDoesNotAnchor() {
        var previous = PollState()
        previous.lastKnownSevenDayReset = Self.t0
        for source in [ResetSource.serverRolled, .limitsRolled, .reconstructedRolled, .unknown] {
            let next = PollingEngine.advance(
                previous: previous,
                outcome: .success(Self.snapshot(source: source, resetsAt: "2026-07-05T00:00:00+00:00")),
                claudeActive: true, now: Self.t0)
            #expect(next.lastKnownSevenDayReset == Self.t0)
        }
    }

    /// A blackout keeps rolling from the same real anchor however long it lasts — the property that
    /// makes the reconstruction stable instead of creeping the way the old estimate did.
    @Test func anAnchorSurvivesAWholeBlackoutUnchanged() throws {
        let anchor = try #require(ResetClock.parse(Self.serverReset))
        var state = PollState()
        state.lastKnownSevenDayReset = anchor
        // Twelve polls of blackout, each decoding to a reconstruction.
        for i in 1...12 {
            state = PollingEngine.advance(
                previous: state,
                outcome: .success(Self.snapshot(source: .reconstructed,
                                                resetsAt: "2026-07-05T00:00:00+00:00")),
                claudeActive: true, now: Self.t0.addingTimeInterval(Double(i) * 180))
        }
        #expect(state.lastKnownSevenDayReset == anchor)
    }
}

// MARK: - What the two surfaces show when there is no weekly clock

/// The cold start: the API has never reported a weekly reset, and there is no anchor to reconstruct
/// one from. Both surfaces withhold everything and say so, rather than drawing bars whose position
/// would be invented.
@Suite("Unknown weekly reset — menu bar and popup")
struct UnknownWeeklyResetTests {

    private static let now = Date(timeIntervalSince1970: 1_000_000)

    /// The cold-start snapshot: no 5h session, no weekly date, nothing spent.
    private static let coldStart = UsageSnapshot(
        fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
        sevenDay: UsageWindow(utilization: 0, resetsAt: ""),
        sessionIdle: true,
        sevenDayResetSource: .unknown)

    @Test func theMenuBarShowsTheUnknownResetState() {
        #expect(MenuBarLayout.make(from: Self.coldStart, now: Self.now).mode == .weeklyResetUnknown(provider: .claude))
    }

    /// Specifically **not** the ⚠️ path: nothing contradicts itself here, so the state must not be
    /// mistaken for the malformed-payload one that glyph is reserved for (ADR-0091).
    @Test func itIsNotADataError() {
        #expect(!Self.coldStart.hasBrokenActiveReset)
        let mode = MenuBarLayout.make(from: Self.coldStart, now: Self.now).mode
        if case .error = mode { Issue.record("cold start must not read as a data error") }
        if case .exhaustedUnknownReset = mode { Issue.record("cold start is not an exhausted window") }
    }

    @Test func thePopupWithholdsEveryRowAndExplains() {
        let layout = PopupLayout.make(
            from: Self.coldStart, health: .healthy(lastSuccess: Self.now), now: Self.now,
            interval: 180, serviceStatus: nil, monitoringAnything: true)
        #expect(layout.weeklyResetUnknown)
        // Every row is withheld — including the per-model ones, which inherit the empty weekly date
        // and would otherwise each draw a marker pinned to the far edge.
        #expect(layout.rows.isEmpty)
        #expect(layout.credits == nil)
        #expect(layout.blockingReset == nil)
        // And it is not dressed as a polling failure: the request succeeded.
        #expect(layout.warning == nil)
    }

    /// Real usage with a blank date is a **different** state, and both surfaces keep drawing it: the
    /// numbers are known even when the clock is not, and hiding them would discard the one thing the
    /// widget does know.
    @Test func usageWithoutAClockStillDraws() {
        let withUsage = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 31, resetsAt: ""),
            sessionIdle: true)
        #expect(MenuBarLayout.make(from: withUsage, now: Self.now).mode != .weeklyResetUnknown(provider: .claude))

        let layout = PopupLayout.make(
            from: withUsage, health: .healthy(lastSuccess: Self.now), now: Self.now,
            interval: 180, serviceStatus: nil, monitoringAnything: true)
        #expect(!layout.weeklyResetUnknown)
        #expect(!layout.rows.isEmpty)
    }

    /// The body the `weekly-reset-blackout` / `weekly-reset-unknown` stubs serve, decoded through the
    /// real client — so the fixtures those stubs are built from are checked here rather than only by
    /// looking at the running app.
    ///
    /// With an anchor it reconstructs; without one it reports the unknown state on both surfaces.
    @Test func theStubBlackoutBodyDrivesBothOutcomes() throws {
        let body = #"""
        {"five_hour":{"utilization":0.0,"resets_at":null},"seven_day":null,\#
        "seven_day_opus":null,"seven_day_sonnet":null,\#
        "limits":[{"kind":"weekly_all","group":"weekly","percent":0,\#
        "severity":"normal","scope":null,"is_active":true}]}
        """#
        let anchor = try #require(ResetClock.parse("2026-08-18T07:00:00.306761+00:00"))
        let during = anchor.addingTimeInterval(2 * 3600)

        // With the anchor the stub seeds on its first two polls: a real date, and ordinary bars.
        let reconstructed = try UsageClient.decode(
            from: Data(body.utf8), now: during, lastKnownSevenDayReset: anchor)
        #expect(reconstructed.sevenDayResetSource == .reconstructed)
        #expect(MenuBarLayout.make(from: reconstructed, now: during).mode != .weeklyResetUnknown(provider: .claude))

        // Without it — the cold-start stub — nothing is invented, and both surfaces say so.
        let cold = try UsageClient.decode(from: Data(body.utf8), now: during)
        #expect(cold.sevenDayResetSource == .unknown)
        #expect(cold.sevenDay.resetsAt.isEmpty)
        #expect(MenuBarLayout.make(from: cold, now: during).mode == .weeklyResetUnknown(provider: .claude))
        let layout = PopupLayout.make(
            from: cold, health: .healthy(lastSuccess: during), now: during,
            interval: 180, serviceStatus: nil, monitoringAnything: true)
        #expect(layout.weeklyResetUnknown)
        #expect(layout.rows.isEmpty)
    }

    /// Troubleshoot names the instant **to the second** and the mode behind it — the only place the
    /// two are visible, and the only resolution at which a held date differs from a creeping one.
    @Test func troubleshootNamesTheInstantAndTheMode() {
        let server = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 10, resetsAt: "2026-06-21T05:30:00+00:00"),
            sevenDay: UsageWindow(utilization: 40, resetsAt: "2026-08-25T07:00:00.058036+00:00"))
        let line = TroubleshootLayout.weeklyResetLine(server)
        #expect(line.contains("2026-08-25 07:00:00 UTC"))   // seconds, not a rounded countdown
        #expect(line.contains("from the API"))

        // A reconstruction is labelled as one, so a blackout is recognisable while it happens.
        let reconstructed = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 0, resetsAt: "2026-08-25T07:00:00+00:00"),
            sevenDayResetSource: .reconstructed)
        #expect(TroubleshootLayout.weeklyResetLine(reconstructed).contains("reconstructed"))

        // And the cold start says the app declined to invent one, rather than reading as a parse
        // failure.
        #expect(TroubleshootLayout.weeklyResetLine(Self.coldStart).contains("none"))
        #expect(TroubleshootLayout.weeklyResetLine(Self.coldStart).contains("nothing to roll from"))
    }

    /// Every source has a distinct phrase — a mode that rendered as another would defeat the point.
    @Test func everyModeReadsDistinctly() {
        let phrases = ResetSource.allCases.map(\.troubleshootDescription)
        #expect(Set(phrases).count == ResetSource.allCases.count)
        // The three rolled forms all say so, since that is the fact that separates them from their
        // un-rolled base.
        for source in ResetSource.allCases where source.isRolled {
            #expect(source.troubleshootDescription.contains("rolled forward locally"))
        }
    }

    /// An ordinary snapshot is untouched by any of this.
    @Test func ahealthySnapshotIsUnaffected() {
        let healthy = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 20, resetsAt: "2026-06-21T05:30:00+00:00"),
            sevenDay: UsageWindow(utilization: 40, resetsAt: "2026-06-28T00:00:00+00:00"))
        #expect(MenuBarLayout.make(from: healthy, now: Self.now).mode != .weeklyResetUnknown(provider: .claude))
        let layout = PopupLayout.make(
            from: healthy, health: .healthy(lastSuccess: Self.now), now: Self.now,
            interval: 180, serviceStatus: nil, monitoringAnything: true)
        #expect(!layout.weeklyResetUnknown)
        #expect(!layout.rows.isEmpty)
    }
}
