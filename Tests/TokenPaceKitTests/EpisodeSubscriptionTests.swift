import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Shared fixtures

private let t0 = ResetClock.parse("2026-08-05T14:00:00Z")!
private func later(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func incident(
    id: String = "inc1",
    name: String = "Degraded performance of multiple models",
    stage: IncidentStage = .identified,
    severity: ServiceStatus = .degraded,
    updateIDs: [String] = ["u1"],
    body: String? = "We are continuing to work on a fix."
) -> VisibleIncident {
    VisibleIncident(
        id: id, name: name, stage: stage, severity: severity,
        shortlink: URL(string: "https://stspg.io/x"), startedAt: t0.addingTimeInterval(-7200),
        updateIDs: updateIDs, latestUpdateBody: body)
}

/// Run a sequence of polls through the evaluator, threading state, and collect every event.
private func run(
    _ polls: [(incidents: [VisibleIncident], at: Date)],
    from state: EpisodeSubscription,
    debounce: TimeInterval = EpisodeEvaluator.defaultDebounce
) -> (events: [EpisodeEvent], state: EpisodeSubscription) {
    var state = state
    var all: [EpisodeEvent] = []
    for poll in polls {
        let (events, next) = EpisodeEvaluator.evaluate(
            subscription: state, incidents: poll.incidents, now: poll.at, debounce: debounce)
        all += events
        state = next
    }
    return (all, state)
}

// MARK: - The row

@Suite("EpisodeEvaluator.rowState")
struct EpisodeRowStateTests {

    @Test func noIncidentsMeansNoRow() {
        #expect(EpisodeEvaluator.rowState(incidents: [], subscription: .none) == nil)
        #expect(EpisodeEvaluator.rowState(incidents: [], subscription: .init(isFollowing: true)) == nil)
    }

    @Test func offersToSubscribeWhenSomethingIsWrong() {
        #expect(EpisodeEvaluator.rowState(incidents: [incident()], subscription: .none) == .notSubscribed)
    }

    @Test func reportsFollowingOnceSubscribed() {
        let following = EpisodeSubscription(isFollowing: true)
        #expect(EpisodeEvaluator.rowState(incidents: [incident()], subscription: following) == .subscribed)
    }

    /// Every active incident in `monitoring` → the question "tell me when it's fixed" is already
    /// answered, so the row reports that instead of offering to answer it.
    @Test func reportsFixDeployedWhenAllAreMonitoring() {
        let monitoring = [incident(stage: .monitoring), incident(id: "inc2", stage: .monitoring)]
        #expect(EpisodeEvaluator.rowState(incidents: monitoring, subscription: .none) == .fixDeployed)
        #expect(EpisodeEvaluator.rowState(
            incidents: monitoring, subscription: .init(isFollowing: true)) == .fixDeployed)
    }

    @Test func oneStillBrokenKeepsTheOfferOpen() {
        let mixed = [incident(stage: .monitoring), incident(id: "inc2", stage: .identified)]
        #expect(EpisodeEvaluator.rowState(incidents: mixed, subscription: .none) == .notSubscribed)
    }
}

// MARK: - Subscribing

@Suite("EpisodeEvaluator.follow")
struct EpisodeFollowTests {

    /// Subscribing must never immediately notify about updates the user just read in the popup.
    @Test func seedsEverythingAlreadyOnScreen() {
        let state = EpisodeEvaluator.follow(incidents: [
            incident(updateIDs: ["u1", "u2"]),
            incident(id: "inc2", updateIDs: ["u3"]),
        ])
        #expect(state.isFollowing)
        #expect(state.seenUpdateIDs == ["u1", "u2", "u3"])

        let (events, _) = run([(incidents: [
            incident(updateIDs: ["u1", "u2"]),
            incident(id: "inc2", updateIDs: ["u3"]),
        ], at: t0)], from: state)
        #expect(events.isEmpty)
    }

    @Test func unfollowClearsEverything() {
        #expect(EpisodeEvaluator.unfollow() == .none)
    }

    /// Not following: no banners, and nothing accumulates that could replay later.
    @Test func notFollowingIsSilent() {
        let (events, state) = run([(incidents: [incident(updateIDs: ["u1", "u2"])], at: t0)], from: .none)
        #expect(events.isEmpty)
        #expect(!state.isFollowing)
        #expect(state.seenUpdateIDs.isEmpty)
    }
}

// MARK: - Update banners

@Suite("EpisodeEvaluator — update events")
struct EpisodeUpdateTests {

    @Test func aNewUpdateFiresOnce() {
        let start = EpisodeEvaluator.follow(incidents: [incident(updateIDs: ["u1"])])
        let (events, state) = run([
            (incidents: [incident(updateIDs: ["u1", "u2"], body: "A fix has been deployed.")], at: later(60)),
            // The same poll again — the id is now seen, so nothing more fires.
            (incidents: [incident(updateIDs: ["u1", "u2"], body: "A fix has been deployed.")], at: later(120)),
        ], from: start)

        #expect(events.count == 1)
        if case let .update(incidentID, _, body, severity) = events.first {
            #expect(incidentID == "inc1")
            #expect(body == "A fix has been deployed.")
            #expect(severity == .degraded)
        } else {
            Issue.record("expected an update event, got \(String(describing: events.first))")
        }
        #expect(state.seenUpdateIDs == ["u1", "u2"])
    }

    /// Updates are edited retroactively, so an unchanged id with new text is not a new event
    /// (ADR-0071 §7) — otherwise every edit would replay as fresh news.
    @Test func anEditedUpdateDoesNotFireAgain() {
        let start = EpisodeEvaluator.follow(incidents: [incident(updateIDs: ["u1"], body: "Original.")])
        let (events, _) = run(
            [(incidents: [incident(updateIDs: ["u1"], body: "Reworded hours later.")], at: later(3600))],
            from: start)
        #expect(events.isEmpty)
    }

    /// Several unseen ids at once (a missed poll window) fold in quietly rather than firing a burst
    /// of stale banners — only the newest carries text worth reading.
    @Test func aBacklogFiresOnlyTheNewest() {
        var start = EpisodeEvaluator.follow(incidents: [incident(updateIDs: [])])
        start.seenUpdateIDs = []
        let (events, state) = run(
            [(incidents: [incident(updateIDs: ["u1", "u2", "u3"], body: "Latest note.")], at: later(60))],
            from: start)
        #expect(events.count == 1)
        #expect(state.seenUpdateIDs == ["u1", "u2", "u3"])
    }

    @Test func eachIncidentReportsItsOwnUpdates() {
        let start = EpisodeEvaluator.follow(incidents: [incident(updateIDs: []), incident(id: "inc2", updateIDs: [])])
        let (events, _) = run([(incidents: [
            incident(updateIDs: ["a1"], body: "First incident update."),
            incident(id: "inc2", name: "Elevated errors", updateIDs: ["b1"], body: "Second incident update."),
        ], at: later(60))], from: start)
        #expect(events.count == 2)
    }
}

// MARK: - Ending the episode

@Suite("EpisodeEvaluator — the episode ends")
struct EpisodeEndTests {

    /// Components going green is the strong signal, and it works even when the incident never said a
    /// word — the silent recovery an updates-driven listener would have missed for 43 minutes.
    @Test func silentRecoveryEndsTheEpisode() {
        let start = EpisodeEvaluator.follow(incidents: [incident()])
        let (events, state) = run([
            (incidents: [], at: later(60)),    // first green poll — starts the debounce
            (incidents: [], at: later(200)),   // held past 90 s — announce
        ], from: start)

        #expect(events == [.ended(reason: .componentsGreen)])
        #expect(state == .none)
    }

    /// Every incident reaching `monitoring` is the second ending: Anthropic says the fix is out even
    /// though components may still be yellow. It must be reported as a *different* claim.
    @Test func allMonitoringEndsTheEpisodeAsFixDeployed() {
        let start = EpisodeEvaluator.follow(incidents: [incident()])
        let (events, state) = run([
            (incidents: [incident(stage: .monitoring)], at: later(60)),
            (incidents: [incident(stage: .monitoring)], at: later(200)),
        ], from: start)

        #expect(events == [.ended(reason: .fixDeployed)])
        #expect(state == .none)
    }

    /// The measured flap: green at 13:08, red again at 13:51 through a *different* incident. Without
    /// the debounce this fires a false all-clear.
    @Test func aFlapWithinTheWindowFiresNothing() {
        let start = EpisodeEvaluator.follow(incidents: [incident()])
        let (events, state) = run([
            (incidents: [], at: later(60)),                 // green — anchor set
            (incidents: [incident()], at: later(100)),      // red again before the window elapsed
            (incidents: [incident()], at: later(160)),
        ], from: start)

        #expect(events.isEmpty)
        #expect(state.isFollowing)
        #expect(state.pendingEndSince == nil, "the anchor must clear when it breaks again")
    }

    @Test func theWindowRestartsAfterAFlap() {
        let start = EpisodeEvaluator.follow(incidents: [incident()])
        let (events, _) = run([
            (incidents: [], at: later(0)),
            (incidents: [incident()], at: later(30)),   // flap
            (incidents: [], at: later(60)),             // green again — anchor restarts here
            (incidents: [], at: later(120)),            // only 60 s since the restart: still quiet
        ], from: start)
        #expect(events.isEmpty)
    }

    @Test func announcedExactlyOnceAtTheBoundary() {
        let start = EpisodeEvaluator.follow(incidents: [incident()])
        let (events, _) = run([
            (incidents: [], at: t0),
            (incidents: [], at: later(EpisodeEvaluator.defaultDebounce)),
            (incidents: [], at: later(EpisodeEvaluator.defaultDebounce + 60)),
        ], from: start)
        #expect(events == [.ended(reason: .componentsGreen)])
    }

    /// Not following: the episode may come and go without a single banner. The opt-in is absolute.
    @Test func recoveryIsSilentWhenNotFollowing() {
        let (events, state) = run([
            (incidents: [incident()], at: t0),
            (incidents: [], at: later(200)),
        ], from: .none)
        #expect(events.isEmpty)
        #expect(state == .none)
    }

    @Test func aZeroDebounceAnnouncesOnTheSecondPoll() {
        // With no debounce the anchor is still set on the first green poll, so the announcement lands
        // on the next one — one poll of hysteresis is inherent, and the tests pin it.
        let start = EpisodeEvaluator.follow(incidents: [incident()])
        let (events, _) = run([
            (incidents: [], at: t0),
            (incidents: [], at: later(1)),
        ], from: start, debounce: 0)
        #expect(events == [.ended(reason: .componentsGreen)])
    }
}

// MARK: - Persistence

@Suite("EpisodeSubscription Codable")
struct EpisodeSubscriptionCodableTests {

    @Test func roundTrips() throws {
        let original = EpisodeSubscription(
            isFollowing: true, seenUpdateIDs: ["u1", "u2"], pendingEndSince: t0)
        let decoded = try JSONDecoder().decode(
            EpisodeSubscription.self, from: try JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    /// An older or truncated blob must degrade to "not following" — the worst case is a missed
    /// banner, never a popup that cannot render.
    @Test func partialBlobDecodesToNotFollowing() throws {
        let decoded = try JSONDecoder().decode(
            EpisodeSubscription.self, from: #"{"isFollowing":true}"#.data(using: .utf8)!)
        #expect(decoded.isFollowing)
        #expect(decoded.seenUpdateIDs.isEmpty)
        #expect(decoded.pendingEndSince == nil)

        let empty = try JSONDecoder().decode(EpisodeSubscription.self, from: "{}".data(using: .utf8)!)
        #expect(empty == .none)
    }
}
