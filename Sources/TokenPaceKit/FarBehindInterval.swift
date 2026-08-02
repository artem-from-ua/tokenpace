import Foundation

// MARK: - FarBehindInterval (#224)

/// How much of a **surplus** (being under the linear pace line) counts as "far behind pace" — the
/// threshold where the on-pace **green** grades into the far-behind **blue** (ADR-0061). The blue zone's
/// width is a fixed span of real time per window; this option scales that span so the user can tune how
/// eagerly blue appears.
///
/// The base span is **1 hour** for the 5-hour window and **1 day** for the 7-day window; each case
/// multiplies both by its ``multiplier``. So ``medium`` (the default, ×2) is the shipped ADR-0061
/// behaviour — 5h: 2h, 7d: 2d — while ``short`` needs only a 1h/1d surplus to turn blue and ``long``
/// needs 3h/3d. ``off`` disables the blue zone entirely — the behind side stays green at any surplus.
///
/// Stored raw-string in `UserDefaults` with a forward-compatible decode (an unknown raw falls back to
/// ``medium``), mirroring `BarStyle` / `ResetCountdownMode`. Render-only in effect: it changes the
/// green↔blue split point, not the layout or which bars show.
public enum FarBehindInterval: String, Sendable, Equatable, Codable, CaseIterable {
    /// No blue: the far-behind zone is disabled, so the behind side stays **green** at any surplus.
    case off = "off"
    /// The tightest split — 5h: 1h, 7d: 1d. Blue appears with the smallest surplus.
    case short = "short"
    /// **Default** — 5h: 2h, 7d: 2d. The shipped ADR-0061 threshold.
    case medium = "medium"
    /// The widest split — 5h: 3h, 7d: 3d. Blue needs the largest surplus.
    case long = "long"

    /// The multiplier applied to the base blue-behind width (1h for 5h, 1d for 7d). ``off`` returns
    /// `nil` — there is no finite threshold; the caller treats a `nil` multiplier as "never blue".
    public var multiplier: Int? {
        switch self {
        case .off:    return nil
        case .short:  return 1
        case .medium: return 2
        case .long:   return 3
        }
    }

    /// Forward-compatible decode: an unrecognised raw string falls back to ``medium`` (the default,
    /// i.e. the shipped threshold) instead of throwing. Mirrors `BarStyle` / `ResetCountdownMode`.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FarBehindInterval(rawValue: raw) ?? .medium
    }
}
