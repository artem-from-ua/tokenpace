import Foundation

// MARK: - ResetCountdownMode

/// How the menu-bar widget decides **which** reset countdown to show (or to hide) for the 5h/7d
/// pacing bars (#103, ADR-0028/0029). Chosen by the user via a radio group in Settings and threaded
/// into `MenuBarLayout.make` — the pure model layer never reads `PersistedConfig`, so the shell
/// passes the resolved mode in (mirrors how `calmColors` reaches `StatusItemView`).
///
/// Every mode except ``never`` runs the same severity-driven selection table; the mode only
/// parameterises **two** cells of it:
/// - **both bars calm** → the countdown is normally dropped as noise; ``always`` instead shows the
///   nearest reset.
/// - **7d ahead-of-pace (orange) while days away and 5h calm** → ``always``/``showDistant7d`` show it,
///   ``hideDistant7d`` hides it unless the 7d reset is `< 24 h` out. (A 7d **red**/exhausted bar is
///   always shown; a 5h noisy bar's reset is always shown.)
///
/// Stored raw-string in `UserDefaults` (like `WebDesktopMode`) with a forward-compatible decode so a
/// newer build's value never makes an older build fail — an unknown raw falls back to ``showDistant7d``.
public enum ResetCountdownMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// Always show a countdown: the severity table, plus the "both calm" cell shows the **nearest**
    /// reset (so the widget is never blank).
    case always = "always"
    /// **Default.** Severity table; a distant (≥24 h) ahead-of-pace 7d countdown **is** shown.
    case showDistant7d = "show_distant_7d"
    /// Severity table, but a distant (≥24 h) ahead-of-pace 7d countdown is **hidden** (shown only
    /// when the 7d reset is `< 24 h` out).
    case hideDistant7d = "hide_distant_7d"
    /// Never show any reset countdown.
    case never = "never"

    /// Forward-compatible decode: an unrecognised raw string falls back to ``showDistant7d`` (the
    /// default) instead of throwing. Mirrors `WebDesktopMode` / `ServiceStatus`'s unknown philosophy.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ResetCountdownMode(rawValue: raw) ?? .showDistant7d
    }

    /// Whether, when **both** bars are calm, the widget still shows a countdown (the nearest reset).
    /// Only ``always`` does.
    public var showsWhenBothCalm: Bool { self == .always }

    /// Whether a **distant** (≥24 h) ahead-of-pace 7d countdown is shown (with a calm 5h bar).
    /// True for ``always`` and ``showDistant7d``; false for ``hideDistant7d``.
    public var showsDistantAhead7d: Bool { self == .always || self == .showDistant7d }
}
