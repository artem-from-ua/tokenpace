import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - rollForward (ADR-0106)

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
    @Test func anAnchorSurvivesAWholeBlackout() throws {
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
