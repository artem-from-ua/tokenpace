import Foundation

// MARK: - ResetRadio ↔ ResetCountdownMode (#168, ADR-0042)

/// The reset-countdown choices in the Settings "Menu Bar Widget" section, shown as a menu picker.
/// These map one-to-one to ``ResetCountdownMode``. Kept in the kit (not the app) so the mapping is
/// unit-testable without importing the executable target.
public enum ResetRadio: String, Sendable, Equatable, CaseIterable {
    /// "Always".
    case always
    /// "When pacing well ahead or limit reached".
    case smart
    /// "Never".
    case never
}

extension ResetCountdownMode {

    /// This mode as its picker choice.
    public var radio: ResetRadio {
        switch self {
        case .always: return .always
        case .smart:  return .smart
        case .never:  return .never
        }
    }

    /// The mode for a picker choice.
    public static func from(radio: ResetRadio) -> ResetCountdownMode {
        switch radio {
        case .always: return .always
        case .smart:  return .smart
        case .never:  return .never
        }
    }
}
