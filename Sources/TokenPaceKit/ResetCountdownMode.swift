import Foundation

// MARK: - ResetCountdownMode

/// How the menu-bar widget decides **whether** to show the reset countdown for the 5h/7d pacing bars
/// (#103, ADR-0028/0029). Chosen by the user via a picker in Settings and threaded into
/// `MenuBarLayout.make` — the pure model layer never reads `PersistedConfig`, so the shell passes the
/// resolved mode in (mirrors how `calmColors` reaches `StatusItemView`).
///
/// Every mode except ``never`` runs the same severity-driven selection table; the mode only
/// parameterises the **both bars calm** cell: the countdown is normally dropped as noise, and
/// ``always`` instead shows the nearest reset. When a countdown is shown at all, an ahead-of-pace 7d
/// reset that is days away is shown too (a 7d **red**/exhausted bar and a 5h noisy bar's reset are
/// always shown).
///
/// Stored raw-string in `UserDefaults` (like `WebDesktopMode`) with a forward-compatible decode so a
/// newer build's value never makes an older build fail — an unknown raw falls back to ``smart``.
public enum ResetCountdownMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// Always show a countdown: the severity table, plus the "both calm" cell shows the **nearest**
    /// reset (so the widget is never blank).
    case always = "always"
    /// **Default.** The severity table decides — shown when well ahead of pace or a limit is reached.
    /// Presented in Settings as "When well ahead or limit reached".
    case smart = "smart"
    /// Never show any reset countdown.
    case never = "never"

    /// Forward-compatible decode: an unrecognised raw string falls back to ``smart`` (the default)
    /// instead of throwing. Mirrors `WebDesktopMode` / `ServiceStatus`'s unknown philosophy. Legacy
    /// values `show_distant_7d` / `hide_distant_7d` therefore decode to ``smart`` (#168).
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ResetCountdownMode(rawValue: raw) ?? .smart
    }

    /// Whether, when **both** bars are calm, the widget still shows a countdown (the nearest reset).
    /// Only ``always`` does.
    public var showsWhenBothCalm: Bool { self == .always }

    /// Whether an ahead-of-pace 7d countdown that is days away is shown (with a calm 5h bar). True
    /// whenever a countdown is shown at all — i.e. every mode except ``never`` (which never reaches
    /// this cell).
    public var showsSevenDayAheadWhenFar: Bool { self != .never }
}
