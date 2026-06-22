import Foundation

// MARK: - TimeToReset

/// How the countdown to a single limit reset should be displayed.
///
/// A discriminated result so the rendering layer (`StatusItemView`, issue #10) owns the
/// presentation and the logic layer owns none of the glyphs. Tests assert on the case and
/// its associated value, not on a fully styled UI string.
///
/// The three cases map to the three time bands defined in SPEC ("Поведінка агента — час"),
/// with two deliberate divergences from `statusline.sh` (see ADR-0006):
/// - ``absolute(_:)`` replaces statusline's coarse `~Nh`/`~Nd` for far-off resets.
/// - ``relative(_:)`` adds a sub-minute **seconds** band that statusline does not have.
public enum TimeToReset: Sendable, Equatable {
    /// Reset is **more than 90 minutes** away: show the absolute wall-clock time,
    /// already formatted to the injected `Locale`/`TimeZone` (e.g. `"5:30 PM"` for a
    /// 12-hour locale, `"17:30"` for a 24-hour locale). DST is applied by Foundation.
    case absolute(String)

    /// Reset is **within (0, 90] minutes** (down to one second): a compact relative
    /// duration — `"1h10m"`, `"45m"`, `"1h"`, or `"40s"`. No spaces, no zero-padding.
    case relative(String)

    /// Reset is **now or in the past** (remaining ≤ 0): the cached usage snapshot is
    /// stale. The view renders a glyph (statusline uses ⏰); the polling layer should
    /// treat this as a signal to re-query the usage API out of turn. The reactive
    /// re-poll itself is **not** this module's job — `ResetClock` stays pure.
    case resetNow
}

// MARK: - NearestReset

/// The limit window whose reset comes first, plus its instant.
///
/// The menu bar shows the countdown to whichever of the 5h / 7d limits resets soonest
/// (SPEC "час до найближчого ресету"). Returned by ``ResetClock/nearestReset(fiveHour:sevenDay:)``
/// so callers know which limit drives the display.
public struct NearestReset: Sendable, Equatable {
    /// Which rolling window resets first. Reuses `PacingModel`'s ``LimitWindow``.
    public let window: LimitWindow
    /// The reset instant of that window.
    public let resetsAt: Date
}

// MARK: - ResetClock

/// Pure parsing and formatting of limit-reset times, ported from the Claude Code
/// statusline (`statusline.sh`) with the SPEC-mandated absolute-time divergence.
///
/// Like `PacingModel`, every entry point is **stateless and deterministic**: the current
/// instant, locale, and time zone are injected as parameters (locale/zone default to
/// `.current`) so tests need no clock or environment mocking. The type is isolated from
/// network, Keychain, and AppKit — it consumes raw API strings / `Date`s and returns plain
/// Swift values.
///
/// ## Relationship to `statusline.sh`
/// | bash function | Swift entry point |
/// |---|---|
/// | `parse_reset_epoch` | ``parse(_:)`` |
/// | `format_time_remaining` | ``timeToReset(resetsAt:now:locale:timeZone:)`` |
/// | (nearest-of-two selection, inline in statusline) | ``nearestReset(fiveHour:sevenDay:)`` |
///
/// ## Divergences from statusline (ADR-0006)
/// `format_time_remaining` only ever prints a **relative** duration. cc-timer instead:
/// - shows the **absolute** local `hh:mm` when the reset is > 90 minutes away;
/// - uses a flat **90-minute** absolute/relative threshold (not statusline's per-window
///   2h / 48h `threshold_hours`);
/// - drops trailing zero minutes (`2h`, not `2h0m`) and adds a sub-minute **seconds**
///   band (`40s`);
/// - returns ``TimeToReset/resetNow`` instead of hard-coding the ⏰ glyph.
public enum ResetClock {

    // MARK: parse

    /// The 90-minute boundary, in seconds. Reset farther away → absolute; at or nearer
    /// (but still in the future) → relative. The comparison is strict `>` (see
    /// ``timeToReset(resetsAt:now:locale:timeZone:)``), so exactly 90 minutes is relative.
    private static let absoluteThreshold: TimeInterval = 90 * 60

    /// Parse the API `resets_at` string into an absolute `Date`.
    ///
    /// **Port of `parse_reset_epoch`** (`statusline.sh` lines 205–218). The API emits
    /// ISO-8601 with **microsecond** fractional seconds and a `+00:00` offset, e.g.
    /// `2026-06-21T05:30:00.619428+00:00`. `ISO8601DateFormatter.withFractionalSeconds`
    /// only handles **milliseconds** (3 digits) and rejects the 6-digit form, so — exactly
    /// like the bash `sed 's/\.[0-9]*+00:00$//'` — the fractional component is stripped
    /// before parsing. Sub-second precision is irrelevant at the app's minute-resolution
    /// display.
    ///
    /// The offset is parsed from the string, so the result is a correct absolute instant
    /// for any offset (`+00:00`, `Z`, or a non-UTC `+02:00`) — more robust than the bash,
    /// which assumes UTC after stripping.
    ///
    /// Returns `nil` for `nil` / empty / `"null"` / otherwise-malformed input, matching the
    /// bash "echo empty string" failure path. Callers treat `nil` as "no reset known".
    ///
    /// - Parameter resetsAt: Raw `five_hour.resets_at` / `seven_day.resets_at` (may be `nil`).
    public static func parse(_ resetsAt: String?) -> Date? {
        guard let raw = resetsAt, !raw.isEmpty, raw != "null" else { return nil }
        // Drop any ".<digits>" immediately before the offset (or trailing Z).
        let stripped = raw.replacingOccurrences(
            of: #"\.\d+(?=([+-]\d{2}:?\d{2})$|Z$)"#,
            with: "",
            options: .regularExpression
        )
        // A fresh formatter per call: `ISO8601DateFormatter` is not `Sendable`, so it cannot
        // be a shared `static let` under Swift 6 strict concurrency. Parsing happens at most
        // once per render (on data change), so the allocation cost is negligible —
        // consistent with the per-call `DateFormatter` in `absoluteString`.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: stripped)
    }

    // MARK: nearestReset

    /// Pick the limit that resets **first** (smallest `resets_at`) between the 5h and 7d
    /// windows — the countdown the menu bar shows (SPEC "найближчий ресет").
    ///
    /// Both inputs are optional because either `resets_at` may be missing or unparseable
    /// (see ``parse(_:)``). Returns `nil` only when **both** are `nil`. When exactly one is
    /// present, that one wins. On an exact tie the 5h window wins — it is the faster-cycling,
    /// more actionable limit.
    ///
    /// - Parameters:
    ///   - fiveHour: Parsed 5h reset `Date`, or `nil`.
    ///   - sevenDay: Parsed 7d reset `Date`, or `nil`.
    public static func nearestReset(fiveHour: Date?, sevenDay: Date?) -> NearestReset? {
        switch (fiveHour, sevenDay) {
        case let (.some(five), .some(seven)):
            // Exact tie → fiveHour (`<=` keeps the 5h window on equality).
            return five <= seven
                ? NearestReset(window: .fiveHour, resetsAt: five)
                : NearestReset(window: .sevenDay, resetsAt: seven)
        case let (.some(five), nil):
            return NearestReset(window: .fiveHour, resetsAt: five)
        case let (nil, .some(seven)):
            return NearestReset(window: .sevenDay, resetsAt: seven)
        case (nil, nil):
            return nil
        }
    }

    // MARK: timeToReset

    /// Render the countdown to a single reset instant.
    ///
    /// **Divergent port of `format_time_remaining`** (`statusline.sh` lines 221–263). The
    /// band boundaries (ADR-0006):
    ///
    /// | remaining            | statusline                          | cc-timer (this fn)             |
    /// |----------------------|-------------------------------------|--------------------------------|
    /// | `≤ 0`                | `⏰`                                 | ``TimeToReset/resetNow``        |
    /// | `(0, 60) s`          | (n/a — bash floors to `0m`)         | `"\(s)s"` — **new** seconds band |
    /// | `[60 s, 90 min]`     | `"\(h)h\(m)m"` / `"\(m)m"`          | same, but trailing `0m` dropped  |
    /// | `> 90 min`           | coarse `~Nh` / `~Nd`                | ``TimeToReset/absolute(_:)`` — **new** |
    ///
    /// Boundary: strict `>` 90 min → absolute; **exactly 90 min → relative** (`1h30m`), since
    /// near the cap the live `Nh Nm` countdown is more useful than a static clock.
    ///
    /// **Relative arithmetic** (from the bash integer math, all truncated toward zero):
    /// `h = (diff % 86400) / 3600`, `m = (diff % 3600) / 60`, `s = diff % 60`, `diff` in
    /// whole seconds. Branches: `diff < 60 → "\(s)s"`; else drop a zero `m` (`"\(h)h"` when
    /// `m == 0`) or a zero `h` (`"\(m)m"` when `h == 0`), otherwise `"\(h)h\(m)m"`. The
    /// `${days}d${hours}h` sub-case of bash Branch 2 is unreachable at ≤ 90 min (days == 0),
    /// so it is intentionally not ported.
    ///
    /// **Absolute branch** (no statusline analog): format `resetsAt` as wall-clock `hh:mm`
    /// in the injected `timeZone` (Foundation applies DST automatically), honoring the
    /// injected `locale`'s 12h/24h convention via `setLocalizedDateFormatFromTemplate("jmm")`
    /// (`j` is the locale's hour-cycle skeleton). SPEC "Час ресету — локальний час пристрою".
    ///
    /// - Parameters:
    ///   - resetsAt: The reset instant (typically ``NearestReset/resetsAt``).
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    ///   - locale: Drives 12h vs 24h in the absolute branch. Default `.current`.
    ///   - timeZone: Wall-clock zone + DST source for the absolute branch. Default `.current`.
    public static func timeToReset(
        resetsAt: Date,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> TimeToReset {
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return .resetNow }
        if remaining > absoluteThreshold {
            return .absolute(absoluteString(for: resetsAt, locale: locale, timeZone: timeZone))
        }
        return .relative(relativeString(seconds: Int(remaining))) // truncate toward zero
    }

    // MARK: resetDisplay (convenience)

    /// Convenience: parse both raw `resets_at` strings, pick the nearest, and format it in
    /// one call — so `UsageClient` / the view-model can wire raw API fields straight to the
    /// view without re-deriving the same selection + formatting logic.
    ///
    /// Returns `nil` only when **neither** string parses. `which` tells the caller which
    /// limit drives the countdown (for the accompanying bar/label). `now`/`locale`/`timeZone`
    /// are threaded to ``timeToReset(resetsAt:now:locale:timeZone:)``.
    ///
    /// - Parameters:
    ///   - fiveHourResetsAt: Raw `five_hour.resets_at` (may be `nil`).
    ///   - sevenDayResetsAt: Raw `seven_day.resets_at` (may be `nil`).
    ///   - now: Current instant.
    ///   - locale: Drives 12h vs 24h. Default `.current`.
    ///   - timeZone: Wall-clock zone + DST source. Default `.current`.
    public static func resetDisplay(
        fiveHourResetsAt: String?,
        sevenDayResetsAt: String?,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> (which: LimitWindow, display: TimeToReset)? {
        guard let nearest = nearestReset(
            fiveHour: parse(fiveHourResetsAt),
            sevenDay: parse(sevenDayResetsAt)
        ) else { return nil }
        let display = timeToReset(resetsAt: nearest.resetsAt, now: now, locale: locale, timeZone: timeZone)
        return (nearest.window, display)
    }

    // MARK: - Popup countdown (relative-always + bounded absolute)

    /// A compact relative countdown for **any** positive remaining time, extended with a **days**
    /// band that ``timeToReset(resetsAt:now:)`` lacks (it only spans ≤ 90 min): `"3d"`, `"5h"`,
    /// `"20m"`, `"1h30m"`, `"40s"`.
    ///
    /// Unlike `timeToReset`, this never switches to an absolute clock — it is the always-shown
    /// "resets in …" part of the popup detail line (#11); the absolute "@ hh:mm" is a separate,
    /// bounded piece (see ``absoluteWithin(resetsAt:now:withinHours:locale:timeZone:)``).
    ///
    /// - Returns: The duration string, or `nil` when the reset is now/past (`remaining ≤ 0`) —
    ///   the caller renders that as a stale signal, matching ``TimeToReset/resetNow``.
    public static func relativeDuration(resetsAt: Date, now: Date) -> String? {
        let remaining = Int(resetsAt.timeIntervalSince(now))   // truncate toward zero
        guard remaining > 0 else { return nil }
        if remaining >= 86_400 {
            let days = remaining / 86_400
            let hours = (remaining % 86_400) / 3_600
            return hours == 0 ? "\(days)d" : "\(days)d\(hours)h"
        }
        return relativeString(seconds: remaining)
    }

    /// The absolute local wall-clock `hh:mm` of the reset — but **only when it is within
    /// `withinHours`** of `now`; otherwise `nil`.
    ///
    /// The popup shows "resets in <relative> @ <absolute>" only when a clock time is actually
    /// useful (the reset is soon); for a reset days away the "@ hh:mm" is noise, so the caller
    /// omits it. 5h windows are always within 24 h (→ always a time); 7d windows and per-model
    /// sub-windows show the time only in their final day. Locale/zone drive 12/24h + DST, reusing
    /// the same formatter as ``timeToReset(resetsAt:now:)``.
    ///
    /// - Parameter withinHours: The threshold; default 24 h (SPEC: per the user's popup spec).
    /// - Returns: `"10:30"` / `"5:30 PM"` when within the window, else `nil`.
    public static func absoluteWithin(
        resetsAt: Date,
        now: Date,
        withinHours: Double = 24,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0, remaining < withinHours * 3_600 else { return nil }
        return absoluteString(for: resetsAt, locale: locale, timeZone: timeZone)
    }

    // MARK: - Private formatting

    /// Compact relative duration for a strictly-positive `seconds` remaining (≤ 90 min).
    /// See ``timeToReset(resetsAt:now:locale:timeZone:)`` for the band rules.
    private static func relativeString(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let hours = (seconds % 86_400) / 3_600
        let mins  = (seconds % 3_600) / 60
        if hours == 0 { return "\(mins)m" }   // < 1 h → minutes only
        if mins == 0  { return "\(hours)h" }  // exact hour(s) → drop trailing 0m
        return "\(hours)h\(mins)m"
    }

    /// Absolute wall-clock `hh:mm` for `date`, locale-aware (12/24h) and DST-correct via
    /// `timeZone`. A fresh `DateFormatter` per call: it depends on the injected
    /// locale/zone, and these calls fire at most once per render (on data change).
    private static func absoluteString(for date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: date)
    }
}
