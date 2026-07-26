import Foundation

// MARK: - NotificationSchedule

/// The pure "quiet hours" gate for the "Back to work!" notification (#160): given the current instant,
/// the user's allowed-hours window and suppressed-weekday choice, decide whether a notification may be
/// delivered. `Date`/`Calendar`-injected so it is fully deterministic in tests (mirrors
/// ``CreditsPacing/monthElapsedFraction(now:timeZone:)``); the shell builds a device-zone gregorian
/// `Calendar` and passes it in.
///
/// Delivery is allowed only when **both** guards pass (AND):
/// 1. `now`'s local time-of-day is inside the allowed **hours** window, and
/// 2. the current window instance's day is **not** a suppressed weekday.
///
/// ## Hours window
/// A window is `[startMinute, endMinute)` in minute-of-day (`0…1439`, local wall clock):
/// - **Non-wrap** (`start < end`): inside when `start <= m < end` (start inclusive, end exclusive).
/// - **Wrap across midnight** (`start > end`, e.g. 17:00–08:00 "evenings and nights"): inside when
///   `m >= start || m < end`.
/// - **`start == end`**: treated as the whole day allowed (a mis-set picker never silently kills all
///   notifications). See ``windowLengthMinutes(startMinute:endMinute:)``.
///
/// ## Weekday suppression is anchored to when the window *opened* (Rule A)
/// For a wrap window the "day" a suppression applies to is the day the **current window instance
/// opened**, not `now`'s calendar day. Worked example — window 13:00–01:00, suppress Saturday–Sunday:
/// the night from Fri 13:00 to Sat 01:00 belongs to **Friday**, so Sat 00:30 is *allowed* (Friday's
/// window), while Sat 14:00 and Sun 00:30 (Saturday's window) are *suppressed*, and Mon 00:30 (still
/// Sunday's window) is *suppressed* too. This keeps the AND semantics meaningful for wrap windows —
/// a plain `weekday(now)` check would suppress Sat 00:30, contradicting the intent.
///
/// The anchor rule lives in one private helper (``windowAnchorDate(now:startMinute:endMinute:calendar:)``)
/// so switching to a simpler `weekday(now)` rule would be a localised change.
public enum NotificationSchedule {

    /// Whether a notification may be delivered at `now`, given the allowed-hours window and the
    /// suppressed-weekday choice. See the type doc for the full boolean.
    ///
    /// - Parameters:
    ///   - now: The instant to evaluate (inject for deterministic tests; do **not** call `Date()` here).
    ///   - window: Allowed window as `(startMinute, endMinute)` in minute-of-day `0…1439`, local time.
    ///   - suppress: Which weekday pair is fully suppressed.
    ///   - calendar: A gregorian calendar carrying the user's `timeZone` (and locale). Injected so the
    ///     same instant can be evaluated in different zones in tests.
    public static func isAllowed(
        at now: Date,
        window: (startMinute: Int, endMinute: Int),
        suppress: SuppressDays,
        calendar: Calendar
    ) -> Bool {
        let start = clampMinute(window.startMinute)
        let end = clampMinute(window.endMinute)

        guard insideHours(now, startMinute: start, endMinute: end, calendar: calendar) else {
            return false
        }
        guard !suppress.suppressedWeekdays.isEmpty else { return true }

        let anchor = windowAnchorDate(now: now, startMinute: start, endMinute: end, calendar: calendar)
        let anchorWeekday = calendar.component(.weekday, from: anchor)
        return !suppress.suppressedWeekdays.contains(anchorWeekday)
    }

    /// The length of the allowed window in minutes, for the Settings "Nh window" hint. A wrap window
    /// (`start > end`) wraps through midnight; `start == end` is the whole day (`1440`), matching
    /// ``isAllowed(at:window:suppress:calendar:)``'s "always inside" reading of equal endpoints.
    public static func windowLengthMinutes(startMinute: Int, endMinute: Int) -> Int {
        let start = clampMinute(startMinute)
        let end = clampMinute(endMinute)
        if start == end { return 1440 }
        return (end - start + 1440) % 1440
    }

    // MARK: - Internals

    /// `now`'s minute-of-day in the calendar's zone.
    private static func minuteOfDay(_ now: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: now)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Whether `now`'s minute-of-day is inside `[start, end)`, handling wrap and equal endpoints.
    private static func insideHours(
        _ now: Date,
        startMinute start: Int,
        endMinute end: Int,
        calendar: Calendar
    ) -> Bool {
        if start == end { return true }                 // whole day
        let m = minuteOfDay(now, calendar: calendar)
        if start < end { return m >= start && m < end } // non-wrap
        return m >= start || m < end                    // wrap across midnight
    }

    /// The instant the **currently-open** window instance started — the anchor for weekday suppression
    /// (Rule A). For a non-wrap window, or a wrap window when we are at/after `start` today, that is
    /// `now`'s day; for the "spilled past midnight" tail of a wrap window (`m < end`), the window opened
    /// *yesterday*, so anchor to `now − 1 day`.
    private static func windowAnchorDate(
        now: Date,
        startMinute start: Int,
        endMinute end: Int,
        calendar: Calendar
    ) -> Date {
        let isWrapTail = start > end && minuteOfDay(now, calendar: calendar) < end
        guard isWrapTail else { return now }
        return calendar.date(byAdding: .day, value: -1, to: now) ?? now
    }

    /// Defensive clamp so a corrupt stored value can never feed an out-of-range minute into the logic.
    private static func clampMinute(_ minute: Int) -> Int {
        min(1439, max(0, minute))
    }
}
