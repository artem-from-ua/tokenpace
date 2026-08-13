import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Shared fixture

/// A fixed "current time" so all relative-duration arithmetic is deterministic.
/// `resetsAt` is expressed as `now + k` seconds throughout.
private let now = Date(timeIntervalSince1970: 1_000_000)

// MARK: - parse

@Suite("ResetClock.parse")
struct ParseTests {

    /// The canonical instant `2026-06-21T05:30:00Z` all parse cases should resolve to,
    /// built independently of `ResetClock` so the assertion does not depend on its own code.
    private static let canonical: Date = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: "2026-06-21T05:30:00Z")!
    }()

    @Test func microsecondsAreStrippedNotShifted() {
        // 6-digit fractional seconds (the real API shape) must parse to the whole-second instant.
        let d = ResetClock.parse("2026-06-21T05:30:00.619428+00:00")
        #expect(d == ParseTests.canonical)
    }

    @Test func millisecondsParse() {
        #expect(ResetClock.parse("2026-06-21T05:30:00.619+00:00") == ParseTests.canonical)
    }

    @Test func noFractionParses() {
        #expect(ResetClock.parse("2026-06-21T05:30:00+00:00") == ParseTests.canonical)
    }

    @Test func zuluSuffixParses() {
        #expect(ResetClock.parse("2026-06-21T05:30:00Z") == ParseTests.canonical)
    }

    @Test func nonUTCOffsetResolvesToSameInstant() {
        // 07:30+02:00 is the same absolute instant as 05:30Z — the offset must be honored.
        #expect(ResetClock.parse("2026-06-21T07:30:00.5+02:00") == ParseTests.canonical)
    }

    @Test func nilInputReturnsNil() {
        #expect(ResetClock.parse(nil) == nil)
    }

    @Test func emptyInputReturnsNil() {
        #expect(ResetClock.parse("") == nil)
    }

    @Test func literalNullReturnsNil() {
        // API may send the JSON null materialized as the string "null".
        #expect(ResetClock.parse("null") == nil)
    }

    @Test func garbageReturnsNil() {
        #expect(ResetClock.parse("garbage") == nil)
    }

    @Test func partialDateReturnsNil() {
        // Date-only, no time component → not a valid internet date-time.
        #expect(ResetClock.parse("2026-06-21") == nil)
    }
}

// MARK: - nearestReset

@Suite("ResetClock.nearestReset")
struct NearestResetTests {

    private static let earlier = Date(timeIntervalSince1970: 2_000)
    private static let later   = Date(timeIntervalSince1970: 9_000)

    @Test func fiveHourSoonerWins() {
        let n = ResetClock.nearestReset(fiveHour: Self.earlier, sevenDay: Self.later)
        #expect(n == NearestReset(window: .fiveHour, resetsAt: Self.earlier))
    }

    @Test func sevenDaySoonerWins() {
        let n = ResetClock.nearestReset(fiveHour: Self.later, sevenDay: Self.earlier)
        #expect(n == NearestReset(window: .sevenDay, resetsAt: Self.earlier))
    }

    @Test func onlyFiveHourPresent() {
        let n = ResetClock.nearestReset(fiveHour: Self.earlier, sevenDay: nil)
        #expect(n == NearestReset(window: .fiveHour, resetsAt: Self.earlier))
    }

    @Test func onlySevenDayPresent() {
        let n = ResetClock.nearestReset(fiveHour: nil, sevenDay: Self.later)
        #expect(n == NearestReset(window: .sevenDay, resetsAt: Self.later))
    }

    @Test func bothNilReturnsNil() {
        #expect(ResetClock.nearestReset(fiveHour: nil, sevenDay: nil) == nil)
    }

    @Test func exactTieFavoursFiveHour() {
        // Documented tie-break: equal resets_at → the faster-cycling 5h window.
        let n = ResetClock.nearestReset(fiveHour: Self.earlier, sevenDay: Self.earlier)
        #expect(n == NearestReset(window: .fiveHour, resetsAt: Self.earlier))
    }
}

// MARK: - timeToReset (one format for every distance, #284/ADR-0074)

/// One table row: `offset` seconds from `now` → expected label.
struct RelCase: Sendable {
    let offset: TimeInterval
    let want: String
}

@Suite("ResetClock.timeToReset")
struct RelativeTests {

    private static let cases: [RelCase] = [
        // sub-minute (0, 60) → "<1m", no seconds band (menu bar re-renders on ~30 s, #36 follow-up)
        RelCase(offset: 1,                 want: "<1m"),
        RelCase(offset: 40,                want: "<1m"),
        RelCase(offset: 59,                want: "<1m"),
        // minute boundary at exactly 60 s
        RelCase(offset: 60,                want: "1m"),
        // minutes, rounded to the nearest
        RelCase(offset: 10 * 60,           want: "10m"),
        RelCase(offset: 45 * 60,           want: "45m"),
        RelCase(offset: 20 * 60 + 40,      want: "21m"),   // rounds up
        RelCase(offset: 20 * 60 + 20,      want: "20m"),   // rounds down
        // the minutes band ends at 50 min, so nothing ever prints "60m"
        RelCase(offset: 49 * 60,           want: "49m"),
        RelCase(offset: 55 * 60,           want: "1h"),
        // hours — a single unit, never "1h29m" (the old combined form died with the threshold)
        RelCase(offset: 60 * 60,           want: "1h"),
        RelCase(offset: 89 * 60,           want: "1h"),
        // the old 90-minute threshold is gone: nothing changes shape across it, only the unit
        RelCase(offset: 90 * 60,           want: "2h"),
        RelCase(offset: 91 * 60,           want: "2h"),
        RelCase(offset: 4 * 3600 + 41 * 60, want: "5h"),
        // the hours band ends at 23 h, so nothing ever prints "24h"
        RelCase(offset: 22 * 3600,         want: "22h"),
        RelCase(offset: 23 * 3600 + 59 * 60, want: "1d"),
        // days
        RelCase(offset: 24 * 3600,         want: "1d"),
        RelCase(offset: 4 * 86_400,        want: "4d"),
        RelCase(offset: 3 * 86_400 + 18 * 3600, want: "4d"),
    ]

    @Test(arguments: RelativeTests.cases)
    func label(_ c: RelCase) {
        let got = ResetClock.timeToReset(resetsAt: now + c.offset, now: now)
        #expect(got == c.want, "offset \(c.offset)s expected \(c.want), got \(got)")
    }

    /// The invariant #284 exists for: the bar's label and the popup's numeric core are the same
    /// string for the same instant, across every band. The popup differs only by its qualifier.
    @Test(arguments: [10.0 * 60, 45 * 60, 89 * 60, 91 * 60, 4 * 3600 + 41 * 60,
                      23 * 3600, 4 * 86_400, 15 * 86_400] as [TimeInterval])
    func menuBarAgreesWithPopupNumber(_ offset: TimeInterval) {
        let at = now + offset
        let bar = ResetClock.timeToReset(resetsAt: at, now: now)
        guard let popupNumber = ResetClock.relativeRounded(resetsAt: at, now: now),
              let popupLine = ResetClock.resetLine(resetsAt: at, now: now,
                                                   locale: Locale(identifier: "en_GB"),
                                                   timeZone: TimeZone(identifier: "UTC")!)
        else { Issue.record("expected a popup line at \(offset)s"); return }
        #expect(bar == popupNumber)
        // The popup line leads with that very number (bare, or followed by a qualifier).
        #expect(popupLine == bar || popupLine.hasPrefix("\(bar) "))
    }

    @Test func resetExactlyNowIsAboutToReset() {
        // No `.resetNow` state: a non-positive remaining falls back to "<1m" — the render pipeline
        // rolls a past-boundary window forward before this can surface (#167).
        #expect(ResetClock.timeToReset(resetsAt: now, now: now) == "<1m")
    }

    @Test func resetInPastIsAboutToReset() {
        #expect(ResetClock.timeToReset(resetsAt: now - 1, now: now) == "<1m")
    }
}

// MARK: - Wall-clock formatting (locale + DST), exercised through the popup's `resetLine`

/// The wall-clock formatter (`ResetClock.absoluteString`) is private and, since #284 (ADR-0074), no
/// longer reachable from the menu bar — the popup's ``ResetClock/resetLine(resetsAt:now:locale:timeZone:)``
/// is now its **only** caller, as the trailing `"at <clock>"` qualifier of a `≤ 24 h` reset.
///
/// These cases moved here from the deleted `timeToReset.absolute` suite when the menu bar dropped its
/// absolute band. They are **not** redundant with `ResetLineTests.clockRespectsLocaleHourCycle`, which
/// only asserts "gb differs from us": these pin the actual rendered hour, including both sides of a DST
/// transition — the project's only coverage of that.
@Suite("ResetClock.resetLine.clock")
struct ResetLineClockTests {

    /// Build the expected wall-clock string with an identically-configured `DateFormatter`,
    /// so the assertion pins "matches Foundation under this locale/zone" without hardcoding
    /// CLDR punctuation (which varies across macOS/CLDR versions).
    private static func expected(_ date: Date, _ locale: Locale, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = tz
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: ResetClock.ceilToMinute(date))   // mirror the production ceil-to-minute
    }

    /// 2026-06-21T17:30:00Z. Rendered from a `now` 4 h earlier, so it lands in `resetLine`'s
    /// `≤ 24 h` band and therefore carries the `"at <clock>"` qualifier.
    private static let resetsAt = Date(timeIntervalSince1970: 1_781_026_200)
    private static var now: Date { resetsAt - 4 * 60 * 60 }

    @Test func twelveHourLocaleShowsMeridiem() {
        let tz = TimeZone(identifier: "America/New_York")!
        let loc = Locale(identifier: "en_US")
        guard let s = ResetClock.resetLine(resetsAt: Self.resetsAt, now: Self.now, locale: loc, timeZone: tz)
        else { Issue.record("expected a line"); return }
        #expect(s.hasSuffix(ResetLineClockTests.expected(Self.resetsAt, loc, tz)))
        // 17:30 UTC → 13:30 EDT (-4 in June) → "1:30 PM" in en_US.
        #expect(s.localizedCaseInsensitiveContains("PM"))
        #expect(s.contains("1:30"))
    }

    @Test func twentyFourHourLocaleHasNoMeridiem() {
        let tz = TimeZone(identifier: "Europe/London")!
        let loc = Locale(identifier: "en_GB")
        guard let s = ResetClock.resetLine(resetsAt: Self.resetsAt, now: Self.now, locale: loc, timeZone: tz)
        else { Issue.record("expected a line"); return }
        #expect(s.hasSuffix(ResetLineClockTests.expected(Self.resetsAt, loc, tz)))
        // 17:30 UTC → 18:30 BST in London.
        #expect(s.contains("18:30"))
        #expect(!s.localizedCaseInsensitiveContains("AM"))
        #expect(!s.localizedCaseInsensitiveContains("PM"))
    }

    @Test func ukrainianLocaleIs24Hour() {
        let tz = TimeZone(identifier: "Europe/Kyiv")!
        let loc = Locale(identifier: "uk_UA")
        guard let s = ResetClock.resetLine(resetsAt: Self.resetsAt, now: Self.now, locale: loc, timeZone: tz)
        else { Issue.record("expected a line"); return }
        #expect(s.hasSuffix(ResetLineClockTests.expected(Self.resetsAt, loc, tz)))
        // 17:30 UTC → 20:30 in Kyiv (EEST, +3 in June).
        #expect(s.contains("20:30"))
    }

    // DST: the SAME absolute instant renders one hour apart across a transition, because
    // the named time zone resolves standard vs daylight offset. America/New_York 2026:
    // spring-forward 2026-03-08, fall-back 2026-11-01.

    @Test func dstStandardTimeOffset() {
        // 2026-03-08T06:00:00Z = 01:00 EST (-5), before the 02:00-local spring-forward.
        let est = Date(timeIntervalSince1970: 1_772_949_600)
        let tz = TimeZone(identifier: "America/New_York")!
        let loc = Locale(identifier: "en_GB")
        let s = ResetClock.resetLine(resetsAt: est, now: est - 3 * 60 * 60, locale: loc, timeZone: tz)
        #expect(s?.contains("01:00") == true)
    }

    @Test func dstDaylightTimeOffset() {
        // 2026-03-08T08:00:00Z = 04:00 EDT (-4), after the spring-forward.
        let edt = Date(timeIntervalSince1970: 1_772_956_800)
        let tz = TimeZone(identifier: "America/New_York")!
        let loc = Locale(identifier: "en_GB")
        let s = ResetClock.resetLine(resetsAt: edt, now: edt - 3 * 60 * 60, locale: loc, timeZone: tz)
        #expect(s?.contains("04:00") == true)
    }
}

// The `ResetClock.resetDisplay` suite was removed with the function itself (ADR-0091) — its only caller
// was the menu bar's `.expanded` countdown, which no longer exists. Every part it exercised is still
// covered where it now lives: the parse-both/nearest-of-two selection in the `nearestReset` suite above,
// and the formatting in `timeToReset`/`relativeRounded` below.

// MARK: - relativeRounded (popup "resets in …", single-unit, nearest-rounded)

@Suite("ResetClock.relativeRounded")
struct RelativeRoundedTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    @Test func subMinuteRendersLessThanOneMinute() {
        // Sub-minute → "<1m" (no seconds value), matching the menu bar (#36 follow-up).
        #expect(ResetClock.relativeRounded(resetsAt: at(10), now: now) == "<1m")
        #expect(ResetClock.relativeRounded(resetsAt: at(29), now: now) == "<1m")
        #expect(ResetClock.relativeRounded(resetsAt: at(59), now: now) == "<1m")
    }

    @Test func minutesRoundToNearest() {
        #expect(ResetClock.relativeRounded(resetsAt: at(20 * 60), now: now) == "20m")        // 20m exactly
        #expect(ResetClock.relativeRounded(resetsAt: at(20 * 60 + 20), now: now) == "20m")   // 20m20s → 20m
        #expect(ResetClock.relativeRounded(resetsAt: at(20 * 60 + 40), now: now) == "21m")   // 20m40s → 21m
    }

    @Test func minutesBandEndsAtFiftyMinutes() {
        // 49 min stays in minutes; 55 min crosses into the hours band and rounds to 1h (not 60m).
        #expect(ResetClock.relativeRounded(resetsAt: at(49 * 60), now: now) == "49m")
        #expect(ResetClock.relativeRounded(resetsAt: at(55 * 60), now: now) == "1h")
    }

    @Test func hoursRoundToNearest() {
        #expect(ResetClock.relativeRounded(resetsAt: at(3 * 3_600), now: now) == "3h")            // 3h exactly
        #expect(ResetClock.relativeRounded(resetsAt: at(3 * 3_600 + 40 * 60), now: now) == "4h")  // 3h40m → 4h
    }

    @Test func hoursBandEndsAtTwentyThreeHours() {
        // 22 h stays in hours; 23.5 h crosses into days and rounds to 1d (not 24h).
        #expect(ResetClock.relativeRounded(resetsAt: at(22 * 3_600), now: now) == "22h")
        #expect(ResetClock.relativeRounded(resetsAt: at(23 * 3_600 + 1_800), now: now) == "1d")
    }

    @Test func daysRoundToNearest() {
        #expect(ResetClock.relativeRounded(resetsAt: at(3 * 86_400), now: now) == "3d")                 // 3d exactly
        #expect(ResetClock.relativeRounded(resetsAt: at(3 * 86_400 + 18 * 3_600), now: now) == "4d")    // 3d18h → 4d
    }

    @Test func nilWhenPastOrNow() {
        #expect(ResetClock.relativeRounded(resetsAt: at(0), now: now) == nil)
        #expect(ResetClock.relativeRounded(resetsAt: at(-60), now: now) == nil)
    }
}

// MARK: - resetLine (unified popup line: bare / next / on / at, in local time — #167)

@Suite("ResetClock.resetLine")
struct ResetLineTests {
    // now = 1970-01-12 13:46:40 UTC — a Monday. Offsets land on known weekdays under UTC.
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }
    private let utc = TimeZone(identifier: "UTC")!
    private let gb = Locale(identifier: "en_GB")   // 24-hour
    private let us = Locale(identifier: "en_US")   // 12-hour

    /// The English weekday name the private `weekdayString` would emit for `date` in `tz` — computed
    /// with an identically-configured formatter so a future change to that helper is caught, not
    /// hardcoded. Ceils to the minute first, matching the helper.
    private func expectedWeekday(_ date: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "EEEE"
        return f.string(from: ResetClock.ceilToMinute(date))
    }

    /// The wall-clock string the private `absoluteString` would emit for `date` in `locale`/`tz`.
    private func expectedClock(_ date: Date, _ locale: Locale, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = tz
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: ResetClock.ceilToMinute(date))
    }

    // ── Zone: > 7 d → bare "Nd" ──────────────────────────────────────────────────────────────
    @Test func beyondSevenDaysIsBareDayCount() {
        #expect(ResetClock.resetLine(resetsAt: at(15 * 86_400), now: now, locale: gb, timeZone: utc) == "15d")
        // 8d exactly out → still bare (> 7 d), no weekday.
        #expect(ResetClock.resetLine(resetsAt: at(8 * 86_400), now: now, locale: gb, timeZone: utc) == "8d")
    }

    // ── Zone: 6 d < r ≤ 7 d → "Nd next <weekday>" ────────────────────────────────────────────
    @Test func withinSevenDaysNamesNextWeekday() {
        let d = at(7 * 86_400)
        #expect(ResetClock.resetLine(resetsAt: d, now: now, locale: gb, timeZone: utc)
                == "7d next \(expectedWeekday(d, utc))")
        // Just inside the 6-day boundary (6d 12h) → "next" band, number rounds to 7d.
        let d2 = at(6 * 86_400 + 12 * 3_600)
        #expect(ResetClock.resetLine(resetsAt: d2, now: now, locale: gb, timeZone: utc)
                == "7d next \(expectedWeekday(d2, utc))")
    }

    // ── Zone: 24 h < r ≤ 6 d → "Nd on <weekday>" ─────────────────────────────────────────────
    @Test func withinSixDaysNamesWeekday() {
        let d = at(5 * 86_400)
        #expect(ResetClock.resetLine(resetsAt: d, now: now, locale: gb, timeZone: utc)
                == "5d on \(expectedWeekday(d, utc))")
        // 6 d exactly (≤ 6 d) → "on" band, not "next".
        let d6 = at(6 * 86_400)
        #expect(ResetClock.resetLine(resetsAt: d6, now: now, locale: gb, timeZone: utc)
                == "6d on \(expectedWeekday(d6, utc))")
    }

    // ── Zone: r ≤ 24 h → "Nh at <time>" / "Nm at <time>" ─────────────────────────────────────
    @Test func withinTwentyFourHoursShowsClock() {
        let d = at(20 * 3_600)
        #expect(ResetClock.resetLine(resetsAt: d, now: now, locale: gb, timeZone: utc)
                == "20h at \(expectedClock(d, gb, utc))")
        // 24 h exactly (≤ 24 h) → clock band, not weekday. relativeRounded gives "1d" at 24h boundary.
        let d24 = at(24 * 3_600)
        #expect(ResetClock.resetLine(resetsAt: d24, now: now, locale: gb, timeZone: utc)
                == "1d at \(expectedClock(d24, gb, utc))")
    }

    @Test func minutesShowClock() {
        let d = at(45 * 60)
        #expect(ResetClock.resetLine(resetsAt: d, now: now, locale: gb, timeZone: utc)
                == "45m at \(expectedClock(d, gb, utc))")
        // 60 m exactly (≤ 24 h, > 0) → still the clock band.
        let d60 = at(60 * 60)
        #expect(ResetClock.resetLine(resetsAt: d60, now: now, locale: gb, timeZone: utc)
                == "1h at \(expectedClock(d60, gb, utc))")
    }

    @Test func subMinuteShowsLessThanOneMinuteAtClock() {
        let d = at(30)
        #expect(ResetClock.resetLine(resetsAt: d, now: now, locale: gb, timeZone: utc)
                == "<1m at \(expectedClock(d, gb, utc))")
    }

    // ── Local timezone conversion: a UTC 00:00 reset reads in local wall-clock ────────────────
    @Test func clockIsInLocalTimeZoneNotUTC() {
        // A reset instant that is 00:00 UTC, shown in Europe/Kyiv (UTC+2 in this era), must NOT read
        // "00:00" — it converts to the local wall clock. Build the instant explicitly at 00:00 UTC.
        let kyiv = TimeZone(identifier: "Europe/Kyiv")!
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = utc
        let midnightUTC = utcCal.date(from: DateComponents(year: 1970, month: 1, day: 15, hour: 0))!
        // Choose a `now` a few hours before so it lands in the ≤ 24 h clock band.
        let justBefore = midnightUTC.addingTimeInterval(-20 * 3_600)
        let line = ResetClock.resetLine(resetsAt: midnightUTC, now: justBefore, locale: gb, timeZone: kyiv)
        let expected = expectedClock(midnightUTC, gb, kyiv)
        #expect(line == "20h at \(expected)")
        #expect(expected != "00:00", "00:00 UTC must render in local time, not midnight")
    }

    @Test func weekdayIsInLocalTimeZone() {
        // Same 00:00 UTC instant, far enough out to hit the weekday band, shown in a tz where the local
        // day differs. Under a positive offset (Kyiv) midnight UTC is still the same date; use a
        // NEGATIVE offset zone so 00:00 UTC falls on the *previous* local day, proving tz is honoured.
        let la = TimeZone(identifier: "America/Los_Angeles")!  // UTC-8/-7 → previous local day
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = utc
        let midnightUTC = utcCal.date(from: DateComponents(year: 1970, month: 1, day: 18, hour: 0))!
        let justBefore = midnightUTC.addingTimeInterval(-5 * 86_400)
        let line = ResetClock.resetLine(resetsAt: midnightUTC, now: justBefore, locale: gb, timeZone: la)
        #expect(line == "5d on \(expectedWeekday(midnightUTC, la))")
        // The local (LA) weekday must differ from the UTC one for this instant (00:00 UTC = prev day).
        #expect(expectedWeekday(midnightUTC, la) != expectedWeekday(midnightUTC, utc))
    }

    // ── Locale: 12h vs 24h clock ─────────────────────────────────────────────────────────────
    @Test func clockRespectsLocaleHourCycle() {
        let d = at(3 * 3_600)   // 3 h out → clock band
        let gbLine = ResetClock.resetLine(resetsAt: d, now: now, locale: gb, timeZone: utc)
        let usLine = ResetClock.resetLine(resetsAt: d, now: now, locale: us, timeZone: utc)
        #expect(gbLine == "3h at \(expectedClock(d, gb, utc))")
        #expect(usLine == "3h at \(expectedClock(d, us, utc))")
        // 24-hour vs 12-hour differ (e.g. "16:46" vs "4:46 PM"); the two must not be equal here.
        #expect(gbLine != usLine)
    }

    // ── Weekday is English regardless of locale ──────────────────────────────────────────────
    @Test func weekdayIsEnglishRegardlessOfLocale() {
        // Even under a non-English locale the weekday name stays English (helper pins en_US_POSIX).
        let d = at(5 * 86_400)
        let fr = Locale(identifier: "fr_FR")
        let line = ResetClock.resetLine(resetsAt: d, now: now, locale: fr, timeZone: utc)
        #expect(line == "5d on \(expectedWeekday(d, utc))")   // expectedWeekday is always English
    }

    // ── Fallback: non-positive remaining → nil ───────────────────────────────────────────────
    @Test func nilWhenNowOrPast() {
        #expect(ResetClock.resetLine(resetsAt: at(0), now: now, locale: gb, timeZone: utc) == nil)
        #expect(ResetClock.resetLine(resetsAt: at(-60), now: now, locale: gb, timeZone: utc) == nil)
    }

    // ── verbose: the ⌥ form prepends "resets in" to every band ───────────────────────────────

    /// The prefix lands on **all four** bands, not just the clock one — a bare `"15d"` reads as a
    /// duration only because of the unit, so it gains the words too.
    @Test func verbosePrefixesEveryBand() {
        let far = at(15 * 86_400)
        #expect(ResetClock.resetLine(resetsAt: far, now: now, verbose: true, locale: gb, timeZone: utc)
                == "resets in 15d")

        let next = at(7 * 86_400)
        #expect(ResetClock.resetLine(resetsAt: next, now: now, verbose: true, locale: gb, timeZone: utc)
                == "resets in 7d next \(expectedWeekday(next, utc))")

        let weekday = at(5 * 86_400)
        #expect(ResetClock.resetLine(resetsAt: weekday, now: now, verbose: true, locale: gb, timeZone: utc)
                == "resets in 5d on \(expectedWeekday(weekday, utc))")

        let hours = at(2 * 3_600)
        #expect(ResetClock.resetLine(resetsAt: hours, now: now, verbose: true, locale: gb, timeZone: utc)
                == "resets in 2h at \(expectedClock(hours, gb, utc))")

        let minutes = at(45 * 60)
        #expect(ResetClock.resetLine(resetsAt: minutes, now: now, verbose: true, locale: gb, timeZone: utc)
                == "resets in 45m at \(expectedClock(minutes, gb, utc))")
    }

    /// Verbose is opt-in: the default stays the bare line every existing caller renders, so the
    /// resting popup is unchanged by the prefix existing.
    @Test func defaultIsNotVerbose() {
        let d = at(2 * 3_600)
        let bare = ResetClock.resetLine(resetsAt: d, now: now, locale: gb, timeZone: utc)
        #expect(bare == "2h at \(expectedClock(d, gb, utc))")
        #expect(bare?.contains(ResetClock.resetLinePrefix) == false)
    }

    /// The two forms differ by exactly the prefix — nothing else about the line changes under ⌥.
    @Test func verboseIsBareLinePlusPrefix() {
        let offsets: [TimeInterval] = [15 * 86_400, 7 * 86_400, 5 * 86_400, 2 * 3_600, 45 * 60, 30]
        for offset in offsets {
            let d = at(offset)
            let bare = ResetClock.resetLine(resetsAt: d, now: now, locale: gb, timeZone: utc)
            let verbose = ResetClock.resetLine(resetsAt: d, now: now, verbose: true, locale: gb, timeZone: utc)
            #expect(verbose == "\(ResetClock.resetLinePrefix) \(bare ?? "")")
        }
    }

    /// A non-positive remaining is `nil` in both forms — the prefix never manufactures a line where
    /// there is none (the caller's "resetting…" fallback still owns that state).
    @Test func verboseIsNilWhenNowOrPast() {
        #expect(ResetClock.resetLine(resetsAt: at(0), now: now, verbose: true, locale: gb, timeZone: utc) == nil)
        #expect(ResetClock.resetLine(resetsAt: at(-60), now: now, verbose: true, locale: gb, timeZone: utc) == nil)
    }
}

// MARK: - ceilToMinute (round reset display up to the next whole minute)

@Suite("ResetClock.ceilToMinute")
struct CeilToMinuteTests {

    /// Exact whole minute stays put — no spurious advance.
    @Test func exactMinuteUnchanged() {
        let d = Date(timeIntervalSince1970: 1_800_000_000)   // multiple of 60
        #expect(ResetClock.ceilToMinute(d) == d)
    }

    /// One second past the minute rounds up to the next minute.
    @Test func oneSecondRoundsUp() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let plus1 = base.addingTimeInterval(1)
        #expect(ResetClock.ceilToMinute(plus1) == base.addingTimeInterval(60))
    }

    /// 59 seconds past the minute rounds up to the next minute (the `…:59` API case).
    @Test func fiftyNineSecondsRoundsUp() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let plus59 = base.addingTimeInterval(59)
        #expect(ResetClock.ceilToMinute(plus59) == base.addingTimeInterval(60))
    }

    /// Fractional sub-second also advances (the API emits microseconds).
    @Test func fractionalSecondRoundsUp() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let plusFraction = base.addingTimeInterval(0.5)
        #expect(ResetClock.ceilToMinute(plusFraction) == base.addingTimeInterval(60))
    }

    /// End-to-end: two near-simultaneous API resets (`…:59:59` and the next `…:00:00`) render as the
    /// SAME wall-clock minute, the bug the user reported (`08:59` vs `09:00`).
    ///
    /// Asserted through the popup's `resetLine` since #284 (ADR-0074) — the menu bar no longer renders
    /// a clock, so the popup's `"at <clock>"` qualifier is the only surface where this can regress.
    @Test func adjacentResetsCollapseToSameMinute() {
        let utc = TimeZone(identifier: "UTC")!
        let gb = Locale(identifier: "en_GB")
        // 06:59:59 and 07:00:00 on the same day.
        let a = ResetClock.parse("2026-06-23T06:59:59.013864+00:00")!
        let b = ResetClock.parse("2026-06-23T07:00:00.013870+00:00")!
        // 3 h earlier → inside resetLine's `≤ 24 h` band, so both lines carry the clock qualifier.
        let nowEarly = a.addingTimeInterval(-3 * 60 * 60)
        guard let sa = ResetClock.resetLine(resetsAt: a, now: nowEarly, locale: gb, timeZone: utc),
              let sb = ResetClock.resetLine(resetsAt: b, now: nowEarly, locale: gb, timeZone: utc)
        else { Issue.record("expected a line"); return }
        #expect(sa == sb, "adjacent resets should render the same minute, got \(sa) vs \(sb)")
        #expect(sa.contains("07:00"))
    }
}

// MARK: - nextReset (last-resort reset estimate for null-window synthesis)

@Suite("ResetClock.nextReset")
struct NextResetTests {

    /// 5-hour window: estimate is `now + 18000 s`, then rounded up to a 10-minute boundary.
    @Test func fiveHourEstimateRoundedTo10Min() {
        // now is a multiple of 600 (1_000_000 = 600 * 1666.66… → not exact), so verify via the
        // contract rather than a hand-computed constant.
        let result = ResetClock.nextReset(now: now, window: .fiveHour)
        let raw = now.addingTimeInterval(18_000)
        #expect(result == ResetClock.ceilTo10Minutes(raw))
        #expect(result >= raw)                                   // never earlier than the real estimate
        #expect(result.timeIntervalSince1970.truncatingRemainder(dividingBy: 600) == 0)  // on a 10-min grid
    }

    /// 7-day window uses the 604800 s duration.
    @Test func sevenDayEstimateUsesWeekDuration() {
        let result = ResetClock.nextReset(now: now, window: .sevenDay)
        let raw = now.addingTimeInterval(604_800)
        #expect(result == ResetClock.ceilTo10Minutes(raw))
    }

    /// An exact 10-minute boundary stays put (ceil leaves it alone).
    @Test func exactBoundaryUnchanged() {
        let onGrid = Date(timeIntervalSince1970: 1_800_000_000)   // multiple of 600
        #expect(ResetClock.ceilTo10Minutes(onGrid) == onGrid)
    }

    /// One second past a 10-minute boundary rounds up to the next one.
    @Test func oneSecondRoundsUpToNext10Min() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let plus1 = base.addingTimeInterval(1)
        #expect(ResetClock.ceilTo10Minutes(plus1) == base.addingTimeInterval(600))
    }
}

// MARK: - timeToResetCompactDays — merged into `timeToReset` (#284, ADR-0074)
//
// The compact-days variant (#100) existed only because `timeToReset` switched to a wall-clock string
// past 90 minutes, which read badly for a reset days out — so the idle 7-day countdown needed its own
// entry point that forced `relativeRounded`'s day branch instead. With the threshold gone, plain
// `timeToReset` *is* `relativeRounded`, so the two collapsed into one function and the separate suite
// disappeared with it. Its cases live on in `RelativeTests.cases` above: `4d`, `1d`, `3d18h → 4d`,
// `23h59m → 1d`, `45m`, and `<1m` for a past reset.
