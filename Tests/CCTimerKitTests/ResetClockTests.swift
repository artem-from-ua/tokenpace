import Testing
import Foundation
@testable import CCTimerKit

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

// MARK: - timeToReset (relative band)

/// One table row: `offset` seconds from `now` → expected `TimeToReset`.
struct RelCase: Sendable {
    let offset: TimeInterval
    let want: TimeToReset
}

@Suite("ResetClock.timeToReset.relative")
struct RelativeTests {

    private static let cases: [RelCase] = [
        // seconds band (0, 60)
        RelCase(offset: 1,                 want: .relative("1s")),
        RelCase(offset: 40,                want: .relative("40s")),
        RelCase(offset: 59,                want: .relative("59s")),
        // seconds → minutes boundary at exactly 60 s
        RelCase(offset: 60,                want: .relative("1m")),
        // minutes only (h == 0)
        RelCase(offset: 45 * 60,           want: .relative("45m")),
        RelCase(offset: 89 * 60,           want: .relative("1h29m")),
        // exact hour(s) → trailing 0m dropped
        RelCase(offset: 60 * 60,           want: .relative("1h")),
        // hours + minutes
        RelCase(offset: 60 * 60 + 60,      want: .relative("1h1m")),
        RelCase(offset: 70 * 60,           want: .relative("1h10m")),
        // truncation toward zero: 1h10m59s of remaining drops the 59 s
        RelCase(offset: 70 * 60 + 59,      want: .relative("1h10m")),
    ]

    @Test(arguments: RelativeTests.cases)
    func relative(_ c: RelCase) {
        let got = ResetClock.timeToReset(resetsAt: now + c.offset, now: now)
        #expect(got == c.want, "offset \(c.offset)s expected \(c.want), got \(got)")
    }

    @Test func exactlyTwoHoursDropsZeroMinutes() {
        // 2h is still > 90 min → absolute, NOT relative. Verify the relative formatter's
        // "drop 0m" rule separately at an hour value that stays inside the relative band:
        // covered by the 1h case above. Here assert 2h takes the absolute branch.
        let got = ResetClock.timeToReset(resetsAt: now + 2 * 60 * 60, now: now,
                                         locale: Locale(identifier: "en_GB"),
                                         timeZone: TimeZone(identifier: "UTC")!)
        if case .absolute = got { } else { Issue.record("expected .absolute for 2h, got \(got)") }
    }

    @Test func resetExactlyNowIsResetNow() {
        #expect(ResetClock.timeToReset(resetsAt: now, now: now) == .resetNow)
    }

    @Test func resetInPastIsResetNow() {
        #expect(ResetClock.timeToReset(resetsAt: now - 1, now: now) == .resetNow)
    }
}

// MARK: - timeToReset (absolute/relative boundary)

@Suite("ResetClock.timeToReset.boundary")
struct BoundaryTests {

    // 24-hour locale + fixed UTC zone so the boundary assertions don't depend on environment.
    private static let loc = Locale(identifier: "en_GB")
    private static let tz  = TimeZone(identifier: "UTC")!

    private static func band(_ offset: TimeInterval) -> TimeToReset {
        ResetClock.timeToReset(resetsAt: now + offset, now: now, locale: loc, timeZone: tz)
    }

    @Test func justUnderNinetyIsRelative() {
        #expect(BoundaryTests.band(89 * 60) == .relative("1h29m"))
    }

    @Test func exactlyNinetyIsRelative() {
        // Strict `>` threshold: exactly 90 min stays relative (`1h30m`).
        #expect(BoundaryTests.band(90 * 60) == .relative("1h30m"))
    }

    @Test func oneSecondPastNinetyIsAbsolute() {
        if case .absolute = BoundaryTests.band(90 * 60 + 1) { } else {
            Issue.record("expected .absolute at 90min+1s")
        }
    }

    @Test func justOverNinetyIsAbsolute() {
        if case .absolute = BoundaryTests.band(91 * 60) { } else {
            Issue.record("expected .absolute at 91min")
        }
    }
}

// MARK: - timeToReset (absolute band: locale + DST)

@Suite("ResetClock.timeToReset.absolute")
struct AbsoluteTests {

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

    /// Far-future reset (well over 90 min) so we are unambiguously in the absolute band.
    /// 2026-06-21T17:30:00Z.
    private static let resetsAt = Date(timeIntervalSince1970: 1_781_026_200)

    @Test func twelveHourLocaleShowsMeridiem() {
        let tz = TimeZone(identifier: "America/New_York")!
        let loc = Locale(identifier: "en_US")
        let got = ResetClock.timeToReset(resetsAt: Self.resetsAt, now: now, locale: loc, timeZone: tz)
        guard case let .absolute(s) = got else { Issue.record("expected .absolute, got \(got)"); return }
        #expect(s == AbsoluteTests.expected(Self.resetsAt, loc, tz))
        // 17:30 UTC → 13:30 EDT (-4 in June) → "1:30 PM" in en_US.
        #expect(s.localizedCaseInsensitiveContains("PM"))
        #expect(s.contains("1:30"))
    }

    @Test func twentyFourHourLocaleHasNoMeridiem() {
        let tz = TimeZone(identifier: "Europe/London")!
        let loc = Locale(identifier: "en_GB")
        let got = ResetClock.timeToReset(resetsAt: Self.resetsAt, now: now, locale: loc, timeZone: tz)
        guard case let .absolute(s) = got else { Issue.record("expected .absolute, got \(got)"); return }
        #expect(s == AbsoluteTests.expected(Self.resetsAt, loc, tz))
        // 17:30 UTC → 18:30 BST in London.
        #expect(s.contains("18:30"))
        #expect(!s.localizedCaseInsensitiveContains("AM"))
        #expect(!s.localizedCaseInsensitiveContains("PM"))
    }

    @Test func ukrainianLocaleIs24Hour() {
        let tz = TimeZone(identifier: "Europe/Kyiv")!
        let loc = Locale(identifier: "uk_UA")
        let got = ResetClock.timeToReset(resetsAt: Self.resetsAt, now: now, locale: loc, timeZone: tz)
        guard case let .absolute(s) = got else { Issue.record("expected .absolute, got \(got)"); return }
        #expect(s == AbsoluteTests.expected(Self.resetsAt, loc, tz))
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
        // Use est itself as `now`-relative far-future: pass a `now` well before it.
        let got = ResetClock.timeToReset(resetsAt: est, now: est - 3 * 60 * 60, locale: loc, timeZone: tz)
        guard case let .absolute(s) = got else { Issue.record("expected .absolute, got \(got)"); return }
        #expect(s.contains("01:00"))
    }

    @Test func dstDaylightTimeOffset() {
        // 2026-03-08T08:00:00Z = 04:00 EDT (-4), after the spring-forward.
        let edt = Date(timeIntervalSince1970: 1_772_956_800)
        let tz = TimeZone(identifier: "America/New_York")!
        let loc = Locale(identifier: "en_GB")
        let got = ResetClock.timeToReset(resetsAt: edt, now: edt - 3 * 60 * 60, locale: loc, timeZone: tz)
        guard case let .absolute(s) = got else { Issue.record("expected .absolute, got \(got)"); return }
        #expect(s.contains("04:00"))
    }
}

// MARK: - resetDisplay (end-to-end)

@Suite("ResetClock.resetDisplay")
struct ResetDisplayTests {

    // Reset strings phrased relative to a fixed reference instant so the bands are stable.
    // Reference "now" for this suite: 2026-06-21T05:30:00Z.
    private static let ref = Date(timeIntervalSince1970: 1_782_019_800)

    @Test func picksNearestAndFormatsRelative() {
        // 5h resets in ~45 min, 7d in ~6 days → 5h is nearest, relative band.
        let five  = "2026-06-21T06:15:00.123456+00:00" // ref + 45 min
        let seven = "2026-06-27T05:30:00+00:00"
        let got = ResetClock.resetDisplay(fiveHourResetsAt: five, sevenDayResetsAt: seven, now: Self.ref)
        #expect(got?.which == .fiveHour)
        #expect(got?.display == .relative("45m"))
    }

    @Test func picksNearestAndFormatsAbsolute() {
        // Both far off; 7d sooner than a (hypothetical) far 5h → absolute band.
        let five  = "2026-06-21T10:00:00+00:00"  // ref + 4.5 h
        let seven = "2026-06-21T08:00:00+00:00"  // ref + 2.5 h, nearer
        let got = ResetClock.resetDisplay(
            fiveHourResetsAt: five, sevenDayResetsAt: seven, now: Self.ref,
            locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(got?.which == .sevenDay)
        guard case .absolute = got?.display else {
            Issue.record("expected .absolute, got \(String(describing: got?.display))"); return
        }
    }

    @Test func oneUnparseableFallsBackToOther() {
        let got = ResetClock.resetDisplay(
            fiveHourResetsAt: "null", sevenDayResetsAt: "2026-06-21T06:00:00+00:00", now: Self.ref)
        #expect(got?.which == .sevenDay)
    }

    @Test func bothUnparseableReturnsNil() {
        let got = ResetClock.resetDisplay(fiveHourResetsAt: nil, sevenDayResetsAt: "garbage", now: Self.ref)
        #expect(got == nil)
    }
}

// MARK: - relativeDuration (popup countdown, with a days band)

@Suite("ResetClock.relativeDuration")
struct RelativeDurationTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    @Test func secondsBand() {
        #expect(ResetClock.relativeDuration(resetsAt: at(40), now: now) == "40s")
    }

    @Test func minutesBand() {
        #expect(ResetClock.relativeDuration(resetsAt: at(45 * 60), now: now) == "45m")
    }

    @Test func hoursAndMinutes() {
        #expect(ResetClock.relativeDuration(resetsAt: at(90 * 60), now: now) == "1h30m")
    }

    @Test func exactHourDropsZeroMinutes() {
        #expect(ResetClock.relativeDuration(resetsAt: at(2 * 3600), now: now) == "2h")
    }

    @Test func daysBand() {
        // 3 days exactly → "3d" (no trailing hours).
        #expect(ResetClock.relativeDuration(resetsAt: at(3 * 86_400), now: now) == "3d")
    }

    @Test func daysAndHours() {
        // 3 days + 5 h → "3d5h".
        #expect(ResetClock.relativeDuration(resetsAt: at(3 * 86_400 + 5 * 3600), now: now) == "3d5h")
    }

    @Test func dayBoundary() {
        // Exactly 24 h is the start of the days band → "1d".
        #expect(ResetClock.relativeDuration(resetsAt: at(86_400), now: now) == "1d")
    }

    @Test func nilWhenPastOrNow() {
        #expect(ResetClock.relativeDuration(resetsAt: at(0), now: now) == nil)
        #expect(ResetClock.relativeDuration(resetsAt: at(-60), now: now) == nil)
    }
}

// MARK: - absoluteWithin (clock time only inside the threshold)

@Suite("ResetClock.absoluteWithin")
struct AbsoluteWithinTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }
    private let utc = TimeZone(identifier: "UTC")!
    private let gb = Locale(identifier: "en_GB")   // 24-hour

    @Test func withinThresholdReturnsClock() {
        let s = ResetClock.absoluteWithin(resetsAt: at(5 * 3600), now: now, locale: gb, timeZone: utc)
        #expect(s != nil)
    }

    @Test func beyondThresholdReturnsNil() {
        // 3 days out → no clock time.
        #expect(ResetClock.absoluteWithin(resetsAt: at(3 * 86_400), now: now, locale: gb, timeZone: utc) == nil)
    }

    @Test func exactlyAtThresholdIsExcluded() {
        // Strict `<` 24 h: exactly 24 h away → nil.
        #expect(ResetClock.absoluteWithin(resetsAt: at(24 * 3600), now: now, locale: gb, timeZone: utc) == nil)
    }

    @Test func justInsideThresholdIncluded() {
        #expect(ResetClock.absoluteWithin(resetsAt: at(24 * 3600 - 60), now: now, locale: gb, timeZone: utc) != nil)
    }

    @Test func nilWhenPast() {
        #expect(ResetClock.absoluteWithin(resetsAt: at(-60), now: now) == nil)
    }

    @Test func customThreshold() {
        // withinHours: 1 → 90 min away is outside.
        #expect(ResetClock.absoluteWithin(resetsAt: at(90 * 60), now: now, withinHours: 1, locale: gb, timeZone: utc) == nil)
        #expect(ResetClock.absoluteWithin(resetsAt: at(30 * 60), now: now, withinHours: 1, locale: gb, timeZone: utc) != nil)
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
    @Test func adjacentResetsCollapseToSameMinute() {
        let utc = TimeZone(identifier: "UTC")!
        let gb = Locale(identifier: "en_GB")
        let nowEarly = Date(timeIntervalSince1970: 1_781_000_000)   // well before, so absolute band
        // 06:59:59 and 07:00:00 on the same far-future day.
        let a = ResetClock.parse("2026-06-23T06:59:59.013864+00:00")!
        let b = ResetClock.parse("2026-06-23T07:00:00.013870+00:00")!
        guard case let .absolute(sa) = ResetClock.timeToReset(resetsAt: a, now: nowEarly, locale: gb, timeZone: utc),
              case let .absolute(sb) = ResetClock.timeToReset(resetsAt: b, now: nowEarly, locale: gb, timeZone: utc)
        else { Issue.record("expected absolute band"); return }
        #expect(sa == sb, "adjacent resets should render the same minute, got \(sa) vs \(sb)")
        #expect(sa.contains("07:00"))
    }
}
