import Foundation

// MARK: - ResetRadio + fold/decompose (#168, ADR-0041)

/// The three **visible** reset-countdown radio choices in the Settings "Appearance" pane. The fourth
/// distinction of ``ResetCountdownMode`` (show vs hide a distant 7d reset) is a separate checkbox, so
/// the UI is a 3-way radio (`ResetRadio`) plus one bool (`includeDistant7d`). These two fold to / from
/// a single ``ResetCountdownMode`` for persistence.
///
/// Kept in the kit (not the app) so the fold/decompose round-trip is unit-testable without importing
/// the executable target.
public enum ResetRadio: String, Sendable, Equatable, CaseIterable {
    /// "Always" — the ``ResetCountdownMode/always`` mode.
    case always
    /// "When well ahead or limit reached" — one of the two `distant7d` modes (the checkbox picks which).
    case smart
    /// "Never" — the ``ResetCountdownMode/never`` mode.
    case never
}

extension ResetCountdownMode {

    /// Split a stored mode into the radio choice + the "include distant 7d" checkbox state, mirroring
    /// the old `syncResetCountdownFromConfig`. For `.always`/`.never` the checkbox is forced **on**
    /// (it is disabled and irrelevant in those modes, but a stable on-state avoids a surprising
    /// unchecked box when the user later switches to smart).
    public static func decompose(_ mode: ResetCountdownMode) -> (radio: ResetRadio, includeDistant7d: Bool) {
        switch mode {
        case .always:        return (.always, true)
        case .showDistant7d: return (.smart, true)
        case .hideDistant7d: return (.smart, false)
        case .never:         return (.never, true)
        }
    }

    /// Fold the radio choice + checkbox back into a mode, mirroring the old `resetCountdownModeChanged`.
    /// Only the `.smart` radio consults the checkbox.
    public static func recompose(radio: ResetRadio, includeDistant7d: Bool) -> ResetCountdownMode {
        switch radio {
        case .always: return .always
        case .never:  return .never
        case .smart:  return includeDistant7d ? .showDistant7d : .hideDistant7d
        }
    }
}
