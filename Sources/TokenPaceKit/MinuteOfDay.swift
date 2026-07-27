import Foundation

// MARK: - MinuteOfDay (#168, ADR-0041)

/// Conversions between a stored minute-of-day (0…1439) and a `Date` for a SwiftUI `DatePicker` in
/// `.hourMinute` mode. Only the hour/minute are ever read back, so the calendar day the `Date` carries
/// is arbitrary (an anchor day is used). Kept in the kit so the round-trip is unit-testable.
public enum MinuteOfDay {

    /// Map a stored minute-of-day (clamped 0…1439) to a `Date` on `anchor`'s day in `timeZone`.
    /// `anchor` defaults to "now" at the call site; pass a fixed date in tests for determinism.
    public static func date(from minute: Int, anchor: Date, timeZone: TimeZone = .current) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let base = cal.startOfDay(for: anchor)
        return cal.date(byAdding: .minute, value: min(1439, max(0, minute)), to: base) ?? base
    }

    /// Read a `Date` back as a minute-of-day (0…1439) in `timeZone`.
    public static func minute(from date: Date, timeZone: TimeZone = .current) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
