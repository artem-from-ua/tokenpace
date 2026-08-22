import Testing
import Foundation
@testable import TokenPaceKit

/// The status source's 429 hold (ADR-0119 §2).
///
/// `PollingBackoff` itself is reused **verbatim** from the usage side — these tests do not re-verify
/// its arithmetic, they pin the two properties the ticket's acceptance criteria turn on: that the
/// semantics the status loop inherits are the right ones (hold exactly, never escalate, clear on the
/// first success), and that two sources holding backoffs are genuinely independent.
@Suite("Status 429 backoff")
struct StatusBackoffTests {

    // MARK: hold and clear

    @Test func holdsForExactlyTheRetryAfter() {
        let held = PollingBackoff().honoring(retryAfter: 120)
        #expect(held.isHolding)
        #expect(held.interval == 120)
    }

    @Test func holdsForTheDefaultWithoutAHint() {
        // A 429 with no usable `Retry-After` (absent, HTTP-date, or malformed → `nil` at the client).
        let held = PollingBackoff().honoring(retryAfter: nil)
        #expect(held.isHolding)
        #expect(held.interval == 180)
        #expect(held.interval == PollingBackoff.defaultInterval)
    }

    @Test func aNonPositiveHintFallsBackToTheDefault() {
        #expect(PollingBackoff().honoring(retryAfter: 0).interval == 180)
        #expect(PollingBackoff().honoring(retryAfter: -5).interval == 180)
    }

    @Test func theFirstSuccessClearsTheHold() {
        let cleared = PollingBackoff().honoring(retryAfter: 120).reset()
        #expect(!cleared.isHolding)
        #expect(cleared.interval == 180)
    }

    // MARK: no escalation

    @Test func consecutive429sDoNotEscalate() {
        // Four 429s in a row, each naming the same number. The hold must stay at that number — the
        // app trusts the server's hint instead of inventing a back-pressure curve of its own.
        var backoff = PollingBackoff()
        for _ in 0..<4 {
            backoff = backoff.honoring(retryAfter: 120)
            #expect(backoff.interval == 120)
        }
    }

    @Test func aLaterHintReplacesTheEarlierOne() {
        // Re-setting, not accumulating: a smaller second hint means a *shorter* hold, not a longer one.
        var backoff = PollingBackoff().honoring(retryAfter: 300)
        #expect(backoff.interval == 300)
        backoff = backoff.honoring(retryAfter: 30)
        #expect(backoff.interval == 30)
    }

    // MARK: independence between sources

    /// The acceptance criterion behind the per-source design: a 429 from one status page must leave
    /// every other source's cadence untouched. Two instances today stand in for the two real sources
    /// #454 will create.
    @Test func twoSourcesHoldIndependently() {
        var first = PollingBackoff()
        let second = PollingBackoff()

        first = first.honoring(retryAfter: 120)

        #expect(first.isHolding)
        #expect(!second.isHolding, "one source's 429 must not slow another source")
        #expect(second.interval == 180)
    }

    @Test func clearingOneSourceDoesNotClearTheOther() {
        var first = PollingBackoff().honoring(retryAfter: 120)
        let second = PollingBackoff().honoring(retryAfter: 60)

        first = first.reset()

        #expect(!first.isHolding)
        #expect(second.isHolding)
        #expect(second.interval == 60)
    }

    /// Value semantics are what make "one backoff per source" cheap and safe: a copy taken before a
    /// 429 is unaffected by it, so there is no way for two sources to alias one hold by accident.
    @Test func theBackoffIsAValueNotAReference() {
        let before = PollingBackoff()
        let after = before.honoring(retryAfter: 120)
        #expect(!before.isHolding)
        #expect(after.isHolding)
        #expect(before != after)
    }
}

// MARK: - Cadence with a hold on top

@Suite("StatusCadence.nextInterval — hold above the floors")
struct StatusCadenceHoldTests {

    @Test func noHoldFallsBackToTheFloor() {
        #expect(StatusCadence.nextInterval(backoff: PollingBackoff()) == StatusCadence.floor)
    }

    @Test func anActiveHoldOutranksTheFloor() {
        // 600 s > the 5-min floor: the hold is what the loop waits.
        let backoff = PollingBackoff().honoring(retryAfter: 600)
        #expect(StatusCadence.nextInterval(backoff: backoff) == 600)
    }

    /// The ordering that matters most: a hold **shorter** than the floor still wins, because it is
    /// still the server's answer and the loop must not poll before it — nor may the problem floor
    /// override it in the other direction.
    @Test func aShortHoldStillOutranksTheProblemFloor() {
        let backoff = PollingBackoff().honoring(retryAfter: 30)
        #expect(StatusCadence.nextInterval(backoff: backoff, hasProblem: true) == 30)
        #expect(StatusCadence.nextInterval(
            backoff: backoff, usageInterval: 30 * 60, hasProblem: true) == 30)
    }

    @Test func aHoldOutranksASlowUsageCadenceToo() {
        let backoff = PollingBackoff().honoring(retryAfter: 120)
        #expect(StatusCadence.nextInterval(backoff: backoff, usageInterval: 30 * 60) == 120)
    }

    @Test func clearingTheHoldReturnsToTheFloor() {
        let backoff = PollingBackoff().honoring(retryAfter: 600).reset()
        #expect(StatusCadence.nextInterval(backoff: backoff) == StatusCadence.floor)
        #expect(StatusCadence.nextInterval(backoff: backoff, hasProblem: true) == StatusCadence.problemFloor)
    }

    // MARK: isDue with a hold

    @Test func isDueRespectsAnActiveHold() {
        let now = Date(timeIntervalSince1970: 10_000)
        let last = now.addingTimeInterval(-400)   // 400 s ago: past the 5-min floor…
        #expect(StatusCadence.isDue(lastSuccess: last, now: now))
        // …but not past a 600 s hold.
        let backoff = PollingBackoff().honoring(retryAfter: 600)
        #expect(!StatusCadence.isDue(lastSuccess: last, backoff: backoff, now: now))
    }

    @Test func isDueOnceTheHoldElapses() {
        let now = Date(timeIntervalSince1970: 10_000)
        let backoff = PollingBackoff().honoring(retryAfter: 600)
        #expect(StatusCadence.isDue(
            lastSuccess: now.addingTimeInterval(-600), backoff: backoff, now: now))
    }

    /// A cold start is due no matter what — there is nothing to hold *since*.
    @Test func coldStartIsDueEvenWhileHolding() {
        let backoff = PollingBackoff().honoring(retryAfter: 600)
        #expect(StatusCadence.isDue(
            lastSuccess: nil, backoff: backoff, now: Date(timeIntervalSince1970: 10_000)))
    }
}

// MARK: - Standing alone, with no usage tick

/// The other half of ADR-0119: the cadence must be answerable with **no** usage interval at all, so a
/// source with no usage poll (or with the usage API switched off, #341) still has a heartbeat.
@Suite("StatusCadence — standalone, no usage tick")
struct StatusCadenceStandaloneTests {

    @Test func withNoUsageIntervalTheIntervalIsTheFloor() {
        #expect(StatusCadence.interval() == StatusCadence.floor)
        #expect(StatusCadence.interval(usageInterval: nil) == StatusCadence.floor)
    }

    @Test func withNoUsageIntervalAProblemUsesTheProblemFloor() {
        // The debt ADR-0085 recorded: in usage-off mode the problem floor now applies, because the
        // floor no longer has to be `max`-ed against a heartbeat that is not accelerating.
        #expect(StatusCadence.interval(hasProblem: true) == StatusCadence.problemFloor)
        #expect(StatusCadence.interval(usageInterval: nil, hasProblem: true) == StatusCadence.problemFloor)
    }

    @Test func aSlowUsageCadenceStillStretchesTheInterval() {
        // The one direction the usage interval is still allowed to move things: slower, never faster.
        let thirtyMin: TimeInterval = 30 * 60
        #expect(StatusCadence.interval(usageInterval: thirtyMin) == thirtyMin)
        #expect(StatusCadence.interval(usageInterval: 60) == StatusCadence.floor)
    }

    @Test func isDueWorksWithoutAUsageInterval() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(!StatusCadence.isDue(lastSuccess: now.addingTimeInterval(-60), now: now))
        #expect(StatusCadence.isDue(lastSuccess: now.addingTimeInterval(-StatusCadence.floor), now: now))
    }

    @Test func isDueHonoursTheProblemFloorWithoutAUsageInterval() {
        let now = Date(timeIntervalSince1970: 10_000)
        let last = now.addingTimeInterval(-90)   // 90 s: past the problem floor, short of the 5-min one
        #expect(!StatusCadence.isDue(lastSuccess: last, hasProblem: false, now: now))
        #expect(StatusCadence.isDue(lastSuccess: last, hasProblem: true, now: now))
    }
}
