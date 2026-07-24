import Testing
import Foundation
@testable import TokenPaceKit

private let now = Date(timeIntervalSince1970: 2_000_000)

@Suite("ArchiveCadence.isDue")
struct ArchiveCadenceTests {

    @Test func firstRunIsAlwaysDue() {
        #expect(ArchiveCadence.isDue(lastSync: nil, now: now))
    }

    @Test func notDueBeforeADay() {
        let twelveHoursAgo = now.addingTimeInterval(-12 * 60 * 60)
        #expect(!ArchiveCadence.isDue(lastSync: twelveHoursAgo, now: now))
    }

    @Test func dueExactlyAtBoundary() {
        // The 24 h boundary counts as due (>=), matching UpdateCheckCadence.
        let exactlyADayAgo = now.addingTimeInterval(-ArchiveCadence.interval)
        #expect(ArchiveCadence.isDue(lastSync: exactlyADayAgo, now: now))
    }

    @Test func dueAfterADay() {
        let overADayAgo = now.addingTimeInterval(-(ArchiveCadence.interval + 1))
        #expect(ArchiveCadence.isDue(lastSync: overADayAgo, now: now))
    }

    @Test func intervalIsTwentyFourHours() {
        #expect(ArchiveCadence.interval == 24 * 60 * 60)
    }
}
