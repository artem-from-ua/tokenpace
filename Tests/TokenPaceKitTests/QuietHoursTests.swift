import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - NotificationSchedule (quiet hours)

/// A gregorian calendar pinned to a fixed zone so weekday/minute arithmetic is deterministic.
private func calendar(_ tzIdentifier: String = "UTC") -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: tzIdentifier)!
    return cal
}

/// Build an instant at a specific wall-clock day + time in `cal`'s zone.
private func date(_ cal: Calendar, y: Int, mo: Int, d: Int, h: Int, mi: Int) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func hm(_ h: Int, _ m: Int) -> Int { h * 60 + m }

@Suite("NotificationSchedule.isAllowed — hours window")
struct QuietHoursWindowTests {

    // Anchor calendar dates to a known week. 2024-06 layout (verified via weekday assertions below):
    //   Fri 2024-06-07, Sat 2024-06-08, Sun 2024-06-09, Mon 2024-06-10.
    // A non-suppressing choice isolates the hours guard.

    @Test func nonWrapBoundariesInclusiveStartExclusiveEnd() {
        let cal = calendar()
        let win = (hm(8, 0), hm(17, 0))   // 08:00–17:00
        // 07:59 blocked, 08:00 allowed, 16:59 allowed, 17:00 blocked.
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 5, h: 7, mi: 59), window: win, suppress: .never, calendar: cal) == false)
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 5, h: 8, mi: 0), window: win, suppress: .never, calendar: cal) == true)
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 5, h: 16, mi: 59), window: win, suppress: .never, calendar: cal) == true)
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 5, h: 17, mi: 0), window: win, suppress: .never, calendar: cal) == false)
    }

    @Test func wrapWindowAcrossMidnight() {
        let cal = calendar()
        let win = (hm(17, 0), hm(8, 0))   // 17:00–08:00
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 5, h: 17, mi: 0), window: win, suppress: .never, calendar: cal) == true)
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 5, h: 23, mi: 59), window: win, suppress: .never, calendar: cal) == true)
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 5, h: 0, mi: 0), window: win, suppress: .never, calendar: cal) == true)
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 5, h: 7, mi: 59), window: win, suppress: .never, calendar: cal) == true)
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 5, h: 8, mi: 0), window: win, suppress: .never, calendar: cal) == false)
    }

    @Test func startEqualsEndIsWholeDay() {
        let cal = calendar()
        let win = (hm(9, 0), hm(9, 0))
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 5, h: 9, mi: 0), window: win, suppress: .never, calendar: cal) == true)
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 5, h: 0, mi: 0), window: win, suppress: .never, calendar: cal) == true)
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 5, h: 23, mi: 30), window: win, suppress: .never, calendar: cal) == true)
    }

    @Test func midnightInsideAndOutside() {
        let cal = calendar()
        // Non-wrap window that does not include midnight.
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 5, h: 0, mi: 0), window: (hm(8, 0), hm(17, 0)), suppress: .never, calendar: cal) == false)
        // Wrap window that includes midnight.
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 5, h: 0, mi: 0), window: (hm(22, 0), hm(6, 0)), suppress: .never, calendar: cal) == true)
    }
}

@Suite("NotificationSchedule.isAllowed — weekday suppression (Rule A)")
struct QuietHoursSuppressionTests {

    /// Sanity-check the anchor week so the suppression tests below rest on verified weekdays,
    /// not on a remembered calendar. Calendar weekday: 1=Sun … 6=Fri … 7=Sat.
    @Test func anchorWeekLayoutIsAsAssumed() {
        let cal = calendar()
        #expect(cal.component(.weekday, from: date(cal, y: 2024, mo: 6, d: 7, h: 12, mi: 0)) == 6) // Fri
        #expect(cal.component(.weekday, from: date(cal, y: 2024, mo: 6, d: 8, h: 12, mi: 0)) == 7) // Sat
        #expect(cal.component(.weekday, from: date(cal, y: 2024, mo: 6, d: 9, h: 12, mi: 0)) == 1) // Sun
        #expect(cal.component(.weekday, from: date(cal, y: 2024, mo: 6, d: 10, h: 12, mi: 0)) == 2) // Mon
    }

    /// The user's worked example: window 13:00–01:00 (wrap), suppress Saturday–Sunday.
    /// Sat 00:30 allowed (Friday's window); Sat 14:00 & Sun 00:30 suppressed (Saturday's window);
    /// Mon 00:30 suppressed (Sunday's window); Fri 23:00 allowed (Friday's window).
    @Test func wrapWindowAnchorsSuppressionToOpeningDay() {
        let cal = calendar()
        let win = (hm(13, 0), hm(1, 0))
        // Fri 23:00 — Friday's window, Friday not suppressed → allowed.
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 7, h: 23, mi: 0), window: win, suppress: .satSun, calendar: cal) == true)
        // Sat 00:30 — still Friday's window → allowed.
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 8, h: 0, mi: 30), window: win, suppress: .satSun, calendar: cal) == true)
        // Sat 14:00 — Saturday's window opened → suppressed.
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 8, h: 14, mi: 0), window: win, suppress: .satSun, calendar: cal) == false)
        // Sun 00:30 — Saturday's window (wrap tail) → suppressed.
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 9, h: 0, mi: 30), window: win, suppress: .satSun, calendar: cal) == false)
        // Mon 00:30 — Sunday's window (wrap tail) → suppressed.
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 10, h: 0, mi: 30), window: win, suppress: .satSun, calendar: cal) == false)
    }

    @Test func friSatSuppressionOnNonWrapWindow() {
        let cal = calendar()
        let win = (hm(8, 0), hm(17, 0))
        // Fri 12:00 suppressed, Sat 12:00 suppressed, Sun 12:00 allowed, Thu 12:00 allowed.
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 7, h: 12, mi: 0), window: win, suppress: .friSat, calendar: cal) == false) // Fri
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 8, h: 12, mi: 0), window: win, suppress: .friSat, calendar: cal) == false) // Sat
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 9, h: 12, mi: 0), window: win, suppress: .friSat, calendar: cal) == true)  // Sun
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 6, h: 12, mi: 0), window: win, suppress: .friSat, calendar: cal) == true)  // Thu
    }

    @Test func neverSuppressesNothing() {
        let cal = calendar()
        let win = (hm(8, 0), hm(17, 0))
        // Every in-hours day is allowed under .never.
        for day in 5...11 {
            #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: day, h: 12, mi: 0), window: win, suppress: .never, calendar: cal) == true)
        }
    }

    @Test func suppressionOnlyAppliesInsideHours() {
        let cal = calendar()
        let win = (hm(8, 0), hm(17, 0))
        // Sat 20:00 is outside hours → blocked by the hours guard regardless of suppression.
        #expect(NotificationSchedule.isAllowed(at: date(cal, y: 2024, mo: 6, d: 8, h: 20, mi: 0), window: win, suppress: .never, calendar: cal) == false)
    }
}

@Suite("NotificationSchedule — timezone & window length")
struct QuietHoursMiscTests {

    @Test func sameInstantDiffersAcrossZones() {
        // 12:00 UTC is inside 08:00–17:00; in UTC+10 the same instant is 22:00 (outside).
        let instant = date(calendar("UTC"), y: 2024, mo: 6, d: 5, h: 12, mi: 0)
        let win = (hm(8, 0), hm(17, 0))
        #expect(NotificationSchedule.isAllowed(at: instant, window: win, suppress: .never, calendar: calendar("UTC")) == true)
        #expect(NotificationSchedule.isAllowed(at: instant, window: win, suppress: .never, calendar: calendar("Australia/Brisbane")) == false)
    }

    @Test func windowLengthNonWrap() {
        #expect(NotificationSchedule.windowLengthMinutes(startMinute: hm(8, 0), endMinute: hm(17, 0)) == 9 * 60)
    }

    @Test func windowLengthWrap() {
        // 17:00–08:00 = 15 hours.
        #expect(NotificationSchedule.windowLengthMinutes(startMinute: hm(17, 0), endMinute: hm(8, 0)) == 15 * 60)
    }

    @Test func windowLengthStartEqualsEndIsWholeDay() {
        #expect(NotificationSchedule.windowLengthMinutes(startMinute: hm(9, 0), endMinute: hm(9, 0)) == 1440)
    }
}

@Suite("SuppressDays decode")
struct SuppressDaysTests {

    @Test func unknownRawDecodesToNever() throws {
        let data = Data("\"friday_only\"".utf8)
        let decoded = try JSONDecoder().decode(SuppressDays.self, from: data)
        #expect(decoded == .never)
    }

    @Test func knownRawsRoundTrip() throws {
        for value in SuppressDays.allCases {
            let data = try JSONEncoder().encode(value)
            let back = try JSONDecoder().decode(SuppressDays.self, from: data)
            #expect(back == value)
        }
    }

    @Test func weekdayMappings() {
        #expect(SuppressDays.never.suppressedWeekdays == [])
        #expect(SuppressDays.friSat.suppressedWeekdays == [6, 7])
        #expect(SuppressDays.satSun.suppressedWeekdays == [7, 1])
    }
}
