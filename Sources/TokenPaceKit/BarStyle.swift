import Foundation

// MARK: - BarStyle (#224)

/// How the pacing bars are **presented** — chosen by the user via a segmented control in Settings →
/// Appearance. The presentation can differ **per surface** (menu-bar widget vs dropdown popup): a bar
/// is drawn either as the dense **pace & time** view (grey track + coloured gap + a "you are here"
/// time-indicator marker) or the simplified **pace** view (a left-anchored colour ribbon whose length
/// equals the gap width, no marker). Both carry the *same* pacing state colour, so they never disagree
/// on "what state am I in" — the only difference is whether the time position is marked.
///
/// The three cases pick which view each surface uses:
/// - ``simple`` — pace-only on **both** surfaces (no marker anywhere).
/// - ``mixed`` — pace-only in the **menu bar**, pace & time in the **dropdown** (the marker appears
///   only where there's room for it).
/// - ``pacing`` — pace & time on **both** surfaces (marker everywhere; the shipped pre-#224 look).
///
/// This is a **render-only** distinction: it changes how each bar is *drawn*, never the underlying
/// `BarLayout`, `PacingSeverity`, or which bars are shown. The Kit stays UI-free — the shell reads this
/// from `PersistedConfig` and threads it into `StatusItemView` / `PopupBarView` via the per-surface
/// helpers below (mirrors how `calmColors` reaches the render layer).
///
/// Stored raw-string in `UserDefaults` with a forward-compatible decode so a newer build's value never
/// makes an older build fail — an unknown raw falls back to ``pacing`` (the shipped behaviour).
public enum BarStyle: String, Sendable, Equatable, Codable, CaseIterable {
    /// Pace & time on both surfaces: a grey track, a coloured pacing gap between the used edge and the
    /// time edge, and a "you are here" time-indicator marker. The shipped behaviour before #224.
    case pacing = "pacing"
    /// Pace-only in the menu bar, pace & time in the dropdown (#224). The compact menu-bar bar drops the
    /// marker; the roomier dropdown keeps it.
    case mixed = "mixed"
    /// Pace-only on both surfaces: no time marker anywhere. A colour ribbon anchored to the **left
    /// edge** whose length is the pacing gap's width, coloured by the pacing state (far-behind blue →
    /// calm green → yellow → orange → red). The colour of the filled part *is* the "what state am I in"
    /// answer, with no marker to correlate against.
    case simple = "simple"

    /// Whether the **menu-bar** widget draws the time-indicator marker (pace & time) vs the left-anchored
    /// ribbon (pace only). Only ``pacing`` marks the menu bar.
    public var menuBarShowsTimeMarker: Bool { self == .pacing }

    /// Whether the **dropdown popup** draws the time-indicator marker (pace & time) vs the ribbon (pace
    /// only). ``pacing`` and ``mixed`` both mark the popup; ``simple`` does not.
    public var popupShowsTimeMarker: Bool { self != .simple }

    /// Forward-compatible decode: an unrecognised raw string falls back to ``pacing`` (the default,
    /// i.e. the shipped behaviour) instead of throwing. Mirrors `ResetCountdownMode`'s unknown
    /// philosophy.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BarStyle(rawValue: raw) ?? .pacing
    }
}
