import Foundation

// MARK: - BarStyle (#224)

/// How the pacing bars are **presented** — chosen by the user via a segmented control in Settings →
/// Appearance. The presentation can differ **per surface** (menu-bar widget vs dropdown popup): a bar
/// is drawn either as **Progress** (grey track + coloured gap + a "you are here" time-indicator
/// marker) or as **Pressure** (a left-anchored colour ribbon, no marker). Both carry the *same*
/// pacing state colour, so they never disagree on "what state am I in".
///
/// The two presentations differ in **scale**, not only in whether time is marked (#307):
/// - **Progress** draws on the **window** scale — two positional marks on one track: the marker at
///   `timeFraction`, and the capsule's far edge, which is always `usageFraction`.
/// - **Pressure** draws on the **remaining** scale — ``BarLayout/pressureLength``
///   (`(r + k − 1)/k`, `r = (u − t)/(1 − t)`), whose zero sits left of `t`. Width alone encodes
///   severity there, at fixed positions: 20 % is exactly on pace, 32.8 % is where yellow turns
///   orange, 100 % is exhausted. A time marker is impossible: on this track it would sit at zero
///   forever, which is also why the popup's tick ruler marks 20 % instead of window fractions.
///
/// The three cases pick which presentation each surface uses:
/// - ``pressure`` — **Pressure** on both surfaces (no marker anywhere).
/// - ``mixed`` — **Pressure** in the menu bar, **Progress** in the dropdown (the marker appears only
///   where there's room for it).
/// - ``progress`` — **Progress** on both surfaces (marker everywhere; the shipped pre-#224 look).
///
/// This is a **render-only** distinction: it changes how each bar is *drawn*, never the underlying
/// `BarLayout`, `PacingSeverity`, or which bars are shown. The Kit stays UI-free — the shell reads this
/// from `PersistedConfig` and threads it into `StatusItemView` / `PopupBarView` via the per-surface
/// helpers below (mirrors how `calmColors` reaches the render layer).
///
/// Stored raw-string in `UserDefaults` with a forward-compatible decode so a newer build's value never
/// makes an older build fail — an unknown raw falls back to ``progress`` (the shipped behaviour).
/// The pre-#307 raws (`"pacing"`/`"simple"`) are migrated in `PersistedConfig.migrateBarStyleIfNeeded`;
/// they must **not** be silently swallowed by that fallback, which is why the migration runs before
/// any read.
public enum BarStyle: String, Sendable, Equatable, Codable, CaseIterable {
    /// **Progress** on both surfaces: a grey track, a coloured pacing gap between the used edge and the
    /// time edge, and a "you are here" time-indicator marker. The shipped behaviour before #224.
    /// Raw value was `"pacing"` before #307.
    case progress = "progress"
    /// **Pressure** in the menu bar, **Progress** in the dropdown (#224). The compact menu-bar bar drops
    /// the marker; the roomier dropdown keeps it.
    case mixed = "mixed"
    /// **Pressure** on both surfaces: no time marker anywhere. A colour ribbon anchored to the **left
    /// edge** whose length is ``BarLayout/pressureLength`` — the gap measured against the time left
    /// before the reset — coloured by the pacing state (far-behind blue → calm green → yellow →
    /// orange → red). The colour *is* the "what state am I in" answer and the width is how urgent it
    /// is, with no marker to correlate against. Raw value was `"simple"` before #307.
    case pressure = "pressure"

    /// Whether the **menu-bar** widget draws the time-indicator marker (Progress) vs the left-anchored
    /// ribbon (Pressure). Only ``progress`` marks the menu bar.
    public var menuBarShowsTimeMarker: Bool { self == .progress }

    /// Whether the **dropdown popup** draws the time-indicator marker (Progress) vs the ribbon
    /// (Pressure). ``progress`` and ``mixed`` both mark the popup; ``pressure`` does not.
    public var popupShowsTimeMarker: Bool { self != .pressure }

    /// Whether the **menu-bar** bar is measured on the renormalised `[now .. reset]` track
    /// (``BarLayout/pressureLength``) instead of the window scale (#307).
    ///
    /// Exactly the inverse of ``menuBarShowsTimeMarker``, and that is the point: "no marker" and
    /// "remaining scale" are one decision, not two that could drift apart. A marker cannot coexist
    /// with this scale — it would sit at zero forever — so naming the implication here keeps the two
    /// renderers from each re-deriving it from a negated flag.
    public var menuBarUsesPressureScale: Bool { !menuBarShowsTimeMarker }

    /// Whether the **dropdown popup**'s bar is measured on the renormalised `[now .. reset]` track
    /// (``BarLayout/pressureLength``) instead of the window scale (#307). Also decides the tick
    /// ruler's fractions: window subdivisions mean nothing on this track, so `PopupBarView` marks
    /// quarters of the time remaining instead.
    public var popupUsesPressureScale: Bool { !popupShowsTimeMarker }

    /// The pre-#307 raw values, mapped to the cases that replaced them. `"mixed"` is unchanged and so
    /// is absent here.
    ///
    /// Read by both the `Codable` decode below (exported appearance JSON written by an older build,
    /// and shared configs) and `PersistedConfig.migrateBarStyleIfNeeded` (the stored `UserDefaults`
    /// value). Keeping the mapping in one place means the two can never disagree about what
    /// `"simple"` meant.
    public static let legacyRawValues: [String: BarStyle] = [
        "pacing": .progress,
        "simple": .pressure,
    ]

    /// Decode with legacy support *before* the forward-compatible fallback (#307): a `"pacing"` /
    /// `"simple"` raw written by an older build maps to the case that replaced it, rather than being
    /// swallowed by the unknown-value fallback. Without this, importing a pre-#307 config would
    /// silently turn `Pace` into `Progress` — the exact trap the rename had to avoid.
    ///
    /// An unrecognised raw still falls back to ``progress`` (the default, i.e. the shipped behaviour)
    /// instead of throwing, so a *newer* build's value never makes an older one fail. Mirrors
    /// `ResetCountdownMode`'s unknown philosophy.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BarStyle(rawValue: raw) ?? BarStyle.legacyRawValues[raw] ?? .progress
    }
}
