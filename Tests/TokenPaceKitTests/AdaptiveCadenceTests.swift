import Testing
import Foundation
@testable import TokenPaceKit

@Suite("AdaptiveCadence")
struct AdaptiveCadenceTests {

    @Test func initialIsFastestFloor() {
        let c = AdaptiveCadence()
        #expect(c.level == 0)
        #expect(c.interval == 180)
    }

    @Test func unchangedDoublesThroughCeiling() {
        var c = AdaptiveCadence()
        let expected: [TimeInterval] = [360, 720, 900]
        for want in expected {
            c = c.unchanged()
            #expect(c.interval == want)
        }
        #expect(c.level == 3)
    }

    @Test func holdsAtFifteenMin() {
        var c = AdaptiveCadence()
        for _ in 0..<6 { c = c.unchanged() }
        #expect(c.interval == 900)
        #expect(c.level == AdaptiveCadence.steps.count - 1)
    }

    @Test func changedSnapsBackToFloor() {
        var c = AdaptiveCadence()
        for _ in 0..<4 { c = c.unchanged() }   // climb to ceiling
        #expect(c.interval == 900)
        c = c.changed()                        // movement → instant reset
        #expect(c.level == 0)
        #expect(c.interval == 180)
    }

    @Test func changedFromFloorStaysAtFloor() {
        // A change observed while already at the floor is idempotent.
        let c = AdaptiveCadence().changed()
        #expect(c.level == 0)
        #expect(c.interval == 180)
    }

    @Test func climbThenChangeThenClimb() {
        var c = AdaptiveCadence()
        for _ in 0..<2 { c = c.unchanged() }   // 180 → 360 → 720
        #expect(c.interval == 720)
        c = c.changed()                        // back to 180
        #expect(c.interval == 180)
        c = c.unchanged()                      // 360 again
        #expect(c.interval == 360)
    }

    @Test func stepsAreInSeconds() {
        // Guards the minutes-vs-seconds trap: 3,6,12,15 min must be stored as seconds.
        #expect(AdaptiveCadence.steps == [180, 360, 720, 900])
    }

    struct ProgressionCase {
        let unchangedCount: Int
        let expected: TimeInterval
    }

    @Test(arguments: [
        ProgressionCase(unchangedCount: 0, expected: 180),  // fresh floor
        ProgressionCase(unchangedCount: 1, expected: 360),
        ProgressionCase(unchangedCount: 2, expected: 720),
        ProgressionCase(unchangedCount: 3, expected: 900),
        ProgressionCase(unchangedCount: 4, expected: 900),  // ceiling hold
        ProgressionCase(unchangedCount: 7, expected: 900),
    ])
    func progression(_ c: ProgressionCase) {
        var cadence = AdaptiveCadence()
        for _ in 0..<c.unchangedCount { cadence = cadence.unchanged() }
        #expect(cadence.interval == c.expected,
            "after \(c.unchangedCount) unchanged polls expected \(c.expected), got \(cadence.interval)")
    }
}
