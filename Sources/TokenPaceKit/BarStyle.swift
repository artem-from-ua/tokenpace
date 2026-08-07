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
///   (`|u − t| / (1 − t)`), where `0` is now and `1` is the reset. The length answers "how much of
///   the time I have left would this gap consume", so width carries the same urgency the colour does.
///   A time marker is impossible here: on this track it would sit at zero forever.
///
/// The three cases pick which presentation each surface uses:
/// - ``simple`` — **Pressure** on both surfaces (no marker anywhere).
/// - ``mixed`` — **Pressure** in the menu bar, **Progress** in the dropdown (the marker appears only
///   where there's room for it).
/// - ``pacing`` — **Progress** on both surfaces (marker everywhere; the shipped pre-#224 look).
///
/// **The case names predate the UI names and deliberately still differ from them** (#307): the raw
/// strings below are persisted in `UserDefaults` and in the exported appearance JSON, and both
/// decode paths fall back *silently* on an unknown raw — renaming them would quietly reset every
/// user who picked anything but the default. So `.simple` is presented as **Pressure** and
/// `.pacing` as **Progress**; `docs/reference/log-messages.md` carries the same mapping for
/// `bar-style: set <raw>`.
///
/// This is a **render-only** distinction: it changes how each bar is *drawn*, never the underlying
/// `BarLayout`, `PacingSeverity`, or which bars are shown. The Kit stays UI-free — the shell reads this
/// from `PersistedConfig` and threads it into `StatusItemView` / `PopupBarView` via the per-surface
/// helpers below (mirrors how `calmColors` reaches the render layer).
///
/// Stored raw-string in `UserDefaults` with a forward-compatible decode so a newer build's value never
/// makes an older build fail — an unknown raw falls back to ``pacing`` (the shipped behaviour).
public enum BarStyle: String, Sendable, Equatable, Codable, CaseIterable {
    /// **Progress** on both surfaces: a grey track, a coloured pacing gap between the used edge and the
    /// time edge, and a "you are here" time-indicator marker. The shipped behaviour before #224.
    case pacing = "pacing"
    /// **Pressure** in the menu bar, **Progress** in the dropdown (#224). The compact menu-bar bar drops
    /// the marker; the roomier dropdown keeps it.
    case mixed = "mixed"
    /// **Pressure** on both surfaces: no time marker anywhere. A colour ribbon anchored to the **left
    /// edge** whose length is ``BarLayout/pressureLength`` — the gap measured against the time left
    /// before the reset — coloured by the pacing state (far-behind blue → calm green → yellow →
    /// orange → red). The colour *is* the "what state am I in" answer and the width is how urgent it
    /// is, with no marker to correlate against.
    case simple = "simple"

    /// Whether the **menu-bar** widget draws the time-indicator marker (Progress) vs the left-anchored
    /// ribbon (Pressure). Only ``pacing`` marks the menu bar.
    public var menuBarShowsTimeMarker: Bool { self == .pacing }

    /// Whether the **dropdown popup** draws the time-indicator marker (Progress) vs the ribbon
    /// (Pressure). ``pacing`` and ``mixed`` both mark the popup; ``simple`` does not.
    public var popupShowsTimeMarker: Bool { self != .simple }

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

    /// Forward-compatible decode: an unrecognised raw string falls back to ``pacing`` (the default,
    /// i.e. the shipped behaviour) instead of throwing. Mirrors `ResetCountdownMode`'s unknown
    /// philosophy.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BarStyle(rawValue: raw) ?? .pacing
    }
}
