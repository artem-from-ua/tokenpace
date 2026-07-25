import Testing
import Foundation
@testable import TokenPaceKit

private let now = Date(timeIntervalSince1970: 2_000_000)

@Suite("UpdateCheckCadence.isDue")
struct UpdateCheckCadenceTests {

    @Test func coldStartIsAlwaysDue() {
        #expect(UpdateCheckCadence.isDue(lastCheck: nil, now: now))
    }

    @Test func notDueBeforeInterval() {
        let sixHoursAgo = now.addingTimeInterval(-6 * 60 * 60)   // < the 12 h interval
        #expect(!UpdateCheckCadence.isDue(lastCheck: sixHoursAgo, now: now))
    }

    @Test func dueExactlyAtBoundary() {
        // The 12 h boundary counts as due (>=), matching StatusCadence.
        let exactlyIntervalAgo = now.addingTimeInterval(-UpdateCheckCadence.interval)
        #expect(UpdateCheckCadence.isDue(lastCheck: exactlyIntervalAgo, now: now))
    }

    @Test func dueAfterInterval() {
        let overIntervalAgo = now.addingTimeInterval(-(UpdateCheckCadence.interval + 1))
        #expect(UpdateCheckCadence.isDue(lastCheck: overIntervalAgo, now: now))
    }

    @Test func intervalIsTwelveHours() {
        #expect(UpdateCheckCadence.interval == 12 * 60 * 60)
    }
}
