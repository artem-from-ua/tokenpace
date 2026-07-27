import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - MinuteOfDay round-trip (#168, ADR-0041)

@Suite("MinuteOfDay")
struct MinuteOfDayTests {

    /// A fixed anchor and a fixed zone so the day/zone the picker Date carries is deterministic.
    private static let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    private static let utc = TimeZone(identifier: "UTC")!

    @Test func roundTripsEveryMinuteEdge() {
        for minute in [0, 1, 59, 60, 480, 1020, 1439] {
            let date = MinuteOfDay.date(from: minute, anchor: Self.anchor, timeZone: Self.utc)
            #expect(MinuteOfDay.minute(from: date, timeZone: Self.utc) == minute)
        }
    }

    @Test func clampsOutOfRangeInput() {
        // Negative and >1439 inputs are clamped to the valid day range before conversion.
        let low = MinuteOfDay.date(from: -5, anchor: Self.anchor, timeZone: Self.utc)
        #expect(MinuteOfDay.minute(from: low, timeZone: Self.utc) == 0)
        let high = MinuteOfDay.date(from: 5000, anchor: Self.anchor, timeZone: Self.utc)
        #expect(MinuteOfDay.minute(from: high, timeZone: Self.utc) == 1439)
    }

    @Test func minuteReadsHourAndMinuteOnly() {
        // 08:30 UTC on the anchor day → 8*60 + 30 = 510, regardless of the seconds/day carried.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.utc
        let base = cal.startOfDay(for: Self.anchor)
        let t = cal.date(byAdding: .minute, value: 510, to: base)!
        #expect(MinuteOfDay.minute(from: t, timeZone: Self.utc) == 510)
    }
}
