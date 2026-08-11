import Foundation

// MARK: - BarScale (#326)

/// Which **scale** a bar is measured on — the geometry underneath a ``BarStyle``, named explicitly
/// rather than derived from whether a marker is drawn (#326, ADR-0079).
///
/// Until Gauge there were two scales and exactly one bit told them apart, so "no marker" and
/// "remaining scale" were one decision (`menuBarUsesPressureScale == !menuBarShowsTimeMarker`).
/// A third scale breaks that identity: Gauge has no marker either, yet it is not Pressure. The
/// implication that survives is one-directional and still worth naming — **a time marker is only
/// meaningful on ``window``** — so the marker flags are now *derived from* the scale rather than
/// the reverse, and the renderers branch on the scale itself.
public enum BarScale: String, Sendable, Equatable, CaseIterable {
    /// Fractions of the **window**: `0` is the window's start, `1` its reset. Two positional marks
    /// live here — the time marker at `timeFraction` and the capsule's far edge at `usageFraction`
    /// — so this is the only scale on which a marker means anything.
    case window
    /// Fractions of the **time remaining**, left-anchored: ``BarLayout/pressureLength``.
    case remaining
    /// Fractions of the time remaining, **signed about the bar's centre**:
    /// ``BarLayout/gaugeOffset``. Zero is the middle; the ribbon grows right when ahead of pace and
    /// left when behind.
    case centred
}

// MARK: - BarStyle (#224)

/// How the pacing bars are **presented** — chosen by the user via a segmented control in Settings →
/// Appearance. The presentation can differ **per surface** (menu-bar widget vs dropdown popup): a bar
/// is drawn either as **Progress** (grey track + coloured gap + a "you are here" time-indicator
/// marker), as **Pressure** (a left-anchored colour ribbon, no marker), or as **Gauge** (a ribbon
/// growing either way from the centre, no marker). All of them carry the *same* pacing state colour,
/// so they never disagree on "what state am I in".
///
/// The presentations differ in **scale** (``BarScale``), not only in whether time is marked (#307,
/// #326):
/// - **Progress** draws on the **window** scale — two positional marks on one track: the marker at
///   `timeFraction`, and the capsule's far edge, which is always `usageFraction`.
/// - **Pressure** draws on the **remaining** scale — ``BarLayout/pressureLength``
///   (`(r + k − 1)/k`, `r = (u − t)/(1 − t)`), whose zero sits left of `t`. Width alone encodes
///   severity there, at fixed positions: 20 % is exactly on pace, 32.8 % is where yellow turns
///   orange, 100 % is exhausted. A time marker is impossible: on this track it would sit at zero
///   forever, which is also why the popup's tick ruler marks 20 % instead of window fractions.
/// - **Gauge** draws on the **centred** scale — ``BarLayout/gaugeOffset`` (`clamp(r/k, −1, +1)`,
///   `k` on the ahead half only). Same numerator as Pressure, zero moved to the middle, so the
///   ribbon's *direction* says ahead-or-behind and its length says by how much. This is the only
///   scale that renders the underpace half at all: Pressure's `max(0, …)` flattens every calm state
///   onto one minimum pill, and a surplus you will not get to spend is exactly what that discards.
///
/// The four cases pick which presentation each surface uses:
/// - ``pressure`` — **Pressure** on both surfaces (no marker anywhere).
/// - ``mixed`` — **Pressure** in the menu bar, **Progress** in the dropdown (the marker appears only
///   where there's room for it).
/// - ``gauge`` — **Gauge** on both surfaces (no marker anywhere; a permanent centre tick instead).
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
    /// **Gauge** on both surfaces (#326): a colour ribbon anchored to the bar's **centre**, growing
    /// **right** when spending is ahead of pace and **left** when it is behind, its signed length
    /// ``BarLayout/gaugeOffset``. A permanent centre tick marks the zero — without it the direction
    /// would have nothing to be a direction *from*. No time marker: like Pressure, this scale has no
    /// position for one.
    case gauge = "gauge"

    /// Which scale the **menu-bar** bar is measured on (#326). The renderers branch on this rather
    /// than on a negated marker flag, because three scales no longer fit in one bit.
    public var menuBarScale: BarScale {
        switch self {
        case .progress: return .window
        case .mixed, .pressure: return .remaining
        case .gauge: return .centred
        }
    }

    /// Which scale the **dropdown popup**'s bar is measured on (#326). Also decides the tick ruler's
    /// fractions: window subdivisions mean nothing off the window scale, so `PopupBarView` marks the
    /// one landmark each other scale does have — 20 % (exactly on pace) on ``BarScale/remaining``,
    /// the centre on ``BarScale/centred``.
    public var popupScale: BarScale {
        switch self {
        case .progress, .mixed: return .window
        case .pressure: return .remaining
        case .gauge: return .centred
        }
    }

    /// Whether the **menu-bar** widget draws the time-indicator marker. Derived from the scale, not
    /// the other way round: a marker only has a position on ``BarScale/window`` — on either of the
    /// others it would sit at zero forever.
    public var menuBarShowsTimeMarker: Bool { menuBarScale == .window }

    /// Whether the **dropdown popup** draws the time-indicator marker. Same derivation as
    /// ``menuBarShowsTimeMarker``: ``progress`` and ``mixed`` mark the popup, ``pressure`` and
    /// ``gauge`` do not.
    public var popupShowsTimeMarker: Bool { popupScale == .window }

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
