import Foundation

// MARK: - SuppressDays

/// Which weekday pair the "Back to work!" notification is fully suppressed on (#160). Chosen by the
/// user via a radio group in Settings and stored raw-string in `UserDefaults`; the pure quiet-hours
/// evaluator (``NotificationSchedule``) reads only the resolved value, never `PersistedConfig`.
///
/// The two non-``never`` options model the two common "weekend" conventions. The mapping to Gregorian
/// weekday numbers lives here (not in the evaluator) so the `1 = Sunday … 7 = Saturday` convention is
/// documented in exactly one place — see ``suppressedWeekdays``.
///
/// Stored raw-string with a forward-compatible decode (like ``CalmBarHiding``) so a newer build's
/// value never makes an older build fail: an unknown raw falls back to ``never``.
public enum SuppressDays: String, Sendable, Equatable, Codable, CaseIterable {
    /// **Default.** Never suppress on any weekday — only the allowed-hours window gates delivery.
    case never = "never"
    /// Suppress on Friday and Saturday.
    case friSat = "fri_sat"
    /// Suppress on Saturday and Sunday.
    case satSun = "sat_sun"

    /// Forward-compatible decode: an unrecognised raw string falls back to ``never`` (the default)
    /// instead of throwing. Mirrors ``CalmBarHiding``'s unknown philosophy.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SuppressDays(rawValue: raw) ?? .never
    }

    /// The Gregorian weekday numbers this option suppresses, using `Calendar`'s convention
    /// (`1 = Sunday, 2 = Monday, … 6 = Friday, 7 = Saturday`), or an empty set for ``never``.
    ///
    /// ``NotificationSchedule`` compares this against the weekday of the day the **current allowed
    /// window instance opened** (not necessarily `now`'s calendar day — see that type for the
    /// wrap-around anchoring rule).
    public var suppressedWeekdays: Set<Int> {
        switch self {
        case .never:  return []
        case .friSat: return [6, 7]   // Fri, Sat
        case .satSun: return [7, 1]   // Sat, Sun
        }
    }
}
