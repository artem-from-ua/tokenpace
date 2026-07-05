import Testing
import Foundation
@testable import TokenPaceKit

private let now = Date(timeIntervalSince1970: 1_000_000)

@Suite("StatusCadence.interval")
struct StatusCadenceIntervalTests {

    @Test func clampsFastUsageToFloor() {
        // Usage polling at 60 s must not drag status polling below the 5-min floor.
        #expect(StatusCadence.interval(usageInterval: 60) == StatusCadence.floor)
    }

    @Test func followsSlowUsage() {
        // Idle/inactive usage interval (30 min) → status follows it (above the floor).
        let thirtyMin: TimeInterval = 30 * 60
        #expect(StatusCadence.interval(usageInterval: thirtyMin) == thirtyMin)
    }

    @Test func floorIsFiveMinutes() {
        #expect(StatusCadence.floor == 5 * 60)
    }

    @Test func problemFloorIsOneMinute() {
        #expect(StatusCadence.problemFloor == 60)
    }

    @Test func problemDropsTheFloor() {
        // With a problem, a fast usage interval is honoured down to the 60-s problem floor.
        #expect(StatusCadence.interval(usageInterval: 90, hasProblem: true) == 90)
        #expect(StatusCadence.interval(usageInterval: 30, hasProblem: true) == StatusCadence.problemFloor)
        // Without a problem the same fast usage interval is clamped to the 5-min polite floor.
        #expect(StatusCadence.interval(usageInterval: 90, hasProblem: false) == StatusCadence.floor)
    }
}

@Suite("StatusCadence.isDue")
struct StatusCadenceIsDueTests {

    @Test func coldStartIsAlwaysDue() {
        #expect(StatusCadence.isDue(lastSuccess: nil, usageInterval: 180, now: now))
    }

    @Test func notDueBeforeFloorElapses() {
        // Last success 2 min ago, fast usage → still gated by the 5-min floor.
        let last = now.addingTimeInterval(-2 * 60)
        #expect(!StatusCadence.isDue(lastSuccess: last, usageInterval: 60, now: now))
    }

    @Test func dueAfterFloorElapses() {
        let last = now.addingTimeInterval(-(5 * 60 + 1))
        #expect(StatusCadence.isDue(lastSuccess: last, usageInterval: 60, now: now))
    }

    @Test func slowUsageStretchesTheGate() {
        // 30-min usage interval: a poll 10 min old is not yet due (must wait the full 30 min).
        let last = now.addingTimeInterval(-10 * 60)
        #expect(!StatusCadence.isDue(lastSuccess: last, usageInterval: 30 * 60, now: now))
        let older = now.addingTimeInterval(-(30 * 60 + 1))
        #expect(StatusCadence.isDue(lastSuccess: older, usageInterval: 30 * 60, now: now))
    }

    @Test func problemMakesItDueSooner() {
        // 90 s since last success, fast usage. Without a problem → gated by 5-min floor (not due);
        // with a problem → 60-s problem floor already elapsed (due).
        let last = now.addingTimeInterval(-90)
        #expect(!StatusCadence.isDue(lastSuccess: last, usageInterval: 60, hasProblem: false, now: now))
        #expect(StatusCadence.isDue(lastSuccess: last, usageInterval: 60, hasProblem: true, now: now))
    }
}
