import Testing
import Foundation
@testable import TokenPaceKit

private let now = Date(timeIntervalSince1970: 2_000_000)

@Suite("UpdateCheckCadence.isDue")
struct UpdateCheckCadenceTests {

    @Test func coldStartIsAlwaysDue() {
        #expect(UpdateCheckCadence.isDue(lastCheck: nil, now: now))
    }

    @Test func notDueBeforeADay() {
        let twelveHoursAgo = now.addingTimeInterval(-12 * 60 * 60)
        #expect(!UpdateCheckCadence.isDue(lastCheck: twelveHoursAgo, now: now))
    }

    @Test func dueExactlyAtBoundary() {
        // The 24 h boundary counts as due (>=), matching StatusCadence.
        let exactlyADayAgo = now.addingTimeInterval(-UpdateCheckCadence.interval)
        #expect(UpdateCheckCadence.isDue(lastCheck: exactlyADayAgo, now: now))
    }

    @Test func dueAfterADay() {
        let overADayAgo = now.addingTimeInterval(-(UpdateCheckCadence.interval + 1))
        #expect(UpdateCheckCadence.isDue(lastCheck: overADayAgo, now: now))
    }

    @Test func intervalIsTwentyFourHours() {
        #expect(UpdateCheckCadence.interval == 24 * 60 * 60)
    }
}
