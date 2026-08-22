import Foundation

// MARK: - BarScale (#326)

/// Which **scale** a bar is measured on — the geometry underneath a ``BarStyle``, named explicitly
/// rather than derived from whether a marker is drawn (#326, ADR-0079).
///
/// Until the centred scale arrived (#326) there were two scales and exactly one bit told them
/// apart, so "no marker" and
/// "remaining scale" were one decision (`menuBarUsesPressureScale == !menuBarShowsTimeMarker`).
/// A third scale breaks that identity: Balance has no marker either, yet it is not Pressure. The
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
    /// ``BarLayout/balanceOffset``. Zero is the middle; the ribbon grows right when ahead of pace and
    /// left when behind.
    case centred
}

// MARK: - BarStyle (#224)

/// How a pacing bar is **presented** on **one surface** — chosen by the user via a segmented control
/// in Settings → Appearance, separately for the menu-bar widget and the dropdown popup (#329). A bar
/// is drawn either as **Progress** (grey track + coloured gap + a "you are here" time-indicator
/// marker), as **Pressure** (a left-anchored colour ribbon, no marker), or as **Balance** (a ribbon
/// growing either way from the centre, no marker). All of them carry the *same* pacing state colour,
/// so they never disagree on "what state am I in".
///
/// The presentations differ in **scale** (``BarScale``), not only in whether time is marked (#307,
/// #326):
/// - **Progress** draws on the **window** scale — two positional marks on one track: the marker at
///   `timeFraction`, and the capsule's far edge, which is always `usageFraction`.
/// - **Pressure** draws on the **remaining** scale — ``BarLayout/pressureLength``, which is exactly
///   the ahead half of the Balance scale: `max(0, balanceOffset)` = `clamp(r, 0, 1)`,
///   `r = (u − t)/(1 − t)`. Its zero is `t` itself. Width alone encodes severity there, at fixed
///   positions: zero is exactly on pace, `0.16` is where yellow turns orange (the `aheadThreshold`
///   itself), `1` is exhausted. A time marker is impossible: on this track it would sit at zero
///   forever.
/// - **Balance** draws on the **centred** scale — ``BarLayout/balanceOffset`` (`clamp(r, −1, +1)`).
///   Same quantity as Pressure, zero moved to the middle, so the ribbon's *direction* says
///   ahead-or-behind and its length says by how much. This is the only scale that renders the
///   underpace half at all: Pressure's `max(0, …)` flattens every calm state onto one minimum pill,
///   and a surplus you will not get to spend is exactly what that discards.
///
/// **The surface is not part of this type** (#329, ADR-0080). Until then a fourth case, `mixed`,
/// meant "Pressure in the menu bar, Progress in the dropdown" — the only way to give the two surfaces
/// different looks, which forced every property here to be a per-surface pair. Now each surface
/// stores its own `BarStyle`, so this enum answers one question (*which presentation*) and the
/// caller answers the other (*where*). All nine pairs are reachable; the old `mixed` is simply the
/// pair `(.pressure, .progress)`.
///
/// This is a **render-only** distinction: it changes how each bar is *drawn*, never the underlying
/// `BarLayout`, `PacingSeverity`, or which bars are shown. The Kit stays UI-free — the shell reads
/// `PersistedConfig.menuBarStyle` / `.dropdownStyle` and threads each into `StatusItemView` /
/// `PopupBarView` (mirrors how `calmColors` reaches the render layer).
///
/// Stored raw-string in `UserDefaults` with a forward-compatible decode so a newer build's value never
/// makes an older build fail — an unknown raw falls back to ``progress`` (the shipped behaviour).
/// Raws written by older builds (`"pacing"`/`"simple"` from before #307, `"mixed"` from before #329,
/// and `"gauge"` from before #388) are migrated in `PersistedConfig.migrateBarStyleIfNeeded` via
/// ``legacySurfaceStyles(for:)``;
/// they must **not** be silently swallowed by that fallback, which is why the migration runs before
/// any read.
public enum BarStyle: String, Sendable, Equatable, Codable, CaseIterable {
    /// A grey track, a coloured pacing gap between the used edge and the time edge, and a "you are
    /// here" time-indicator marker. The only presentation before #224. Builds before #307 wrote this
    /// raw value as `"pacing"` — see ``legacyRawValues``.
    case progress = "progress"
    /// No time marker: a colour ribbon anchored to the **left edge** whose length is
    /// ``BarLayout/pressureLength`` — the gap measured against the time left before the reset —
    /// coloured by the pacing state (far-behind blue → calm green → yellow → orange → red). The
    /// colour *is* the "what state am I in" answer and the width is how urgent it is, with no marker
    /// to correlate against. Builds before #307 wrote this raw value as `"simple"` — see
    /// ``legacyRawValues``.
    case pressure = "pressure"
    /// A colour ribbon anchored to the bar's **centre** (#326), growing **right** when spending is
    /// ahead of pace and **left** when it is behind, its signed length ``BarLayout/balanceOffset``. A
    /// permanent centre tick marks the zero — without it the direction would have nothing to be a
    /// direction *from*. No time marker: like Pressure, this scale has no position for one.
    ///
    /// Deliberately not called **Gauge** (its name before #388, raw value `"gauge"` — see
    /// ``legacyRawValues``): that name says *instrument*, and "pressure gauge" reads as a variant of
    /// ``pressure`` — the opposite of the real relation, since ``BarLayout/pressureLength`` is this
    /// scale's ahead half. **Balance** names what actually distinguishes it: a zero in the middle,
    /// deviation either way. Unrelated to the credits API's `spend.balance` (a money figure this app
    /// never decodes).
    case balance = "balance"

    /// The style's name as a **word**, Title Case: `"Pressure"` / `"Balance"` / `"Progress"`.
    ///
    /// The single source for both places a user reads a style name: the Settings segments
    /// (`AppearanceBarStyle.segments`, verbatim) and the dropdown's per-bar caption (lowercased —
    /// see ``caption``). Kept here rather than beside either surface so a rename lands once — which
    /// is what #388 then did: `"Gauge"` became `"Balance"` by editing this one line, and both
    /// surfaces followed. Two literals would have meant two half-renames.
    ///
    /// Spelled out rather than derived from `rawValue`: the raw values are **persisted** keys, and
    /// deriving display text from them would make a stored string load-bearing for the UI. That
    /// separation is what let #388 change the word here while the stored raw migrated separately.
    public var displayName: String {
        switch self {
        case .pressure: return "Pressure"
        case .balance:  return "Balance"
        case .progress: return "Progress"
        }
    }

    /// The style's name as it appears **in the dropdown**, beside each bar's title under ⌥ (#396):
    /// lowercase — `"pressure"` / `"balance"` / `"progress"`.
    ///
    /// Lowercase only here, deliberately. In Settings the word is a control's label and keeps its
    /// capital as the style's own name (the window is otherwise sentence case — `Slow down`,
    /// `How it's going` — so this is the proper-noun exception, not the house style); in the popup it
    /// is a quiet annotation sitting next to a row title in the same ink as the supporting numbers,
    /// and a capital there would read as a second heading competing with the row's own name.
    public var caption: String { displayName.lowercased() }

    /// Which scale this presentation is measured on (#326). The renderers branch on this rather than
    /// on a negated marker flag, because three scales no longer fit in one bit.
    public var scale: BarScale {
        switch self {
        case .progress: return .window
        case .pressure: return .remaining
        case .balance: return .centred
        }
    }

    /// Whether the bar draws the time-indicator marker. Derived from the scale, not the other way
    /// round: a marker only has a position on ``BarScale/window`` — on either of the others it would
    /// sit at zero forever.
    ///
    /// This also decides the popup's tick ruler: window subdivisions mean nothing off the window
    /// scale, so the marker-less scales carry no teeth at all (ADR-0098) — they are identified by
    /// their **zero** alone, drawn by `PopupBarView.drawZeroTick` and captioned under ⌥.
    public var showsTimeMarker: Bool { scale == .window }

    /// Raw values written by older builds, mapped to the cases that replaced them.
    ///
    /// Covers the *renames* only, from two separate rounds: `"pacing"`/`"simple"` from #307, and
    /// `"gauge"` from #388. `"mixed"` is not here because it never named a presentation — it named a
    /// **pair** of them, so it cannot map to a single case; see ``legacySurfaceStyles(for:)``.
    ///
    /// Every entry is load-bearing for someone's stored setting, so entries are **removed only when
    /// no supported upgrade path can still carry that raw**. `"gauge"` in particular was the shipped
    /// default (`.workHarder`) before #388: dropping it would reset the majority of installs.
    public static let legacyRawValues: [String: BarStyle] = [
        "pacing": .progress,
        "simple": .pressure,
        "gauge": .balance,
    ]

    /// Splits a raw value written by an older build into the pair of per-surface styles that
    /// reproduces what that build drew (#329). Returns `nil` for a raw this build cannot place —
    /// the caller then leaves the setting alone and lets the preset default apply.
    ///
    /// | stored raw | menu bar | dropdown |
    /// |---|---|---|
    /// | `"mixed"` | ``pressure`` | ``progress`` |
    /// | `"pacing"` / `"progress"` | ``progress`` | ``progress`` |
    /// | `"simple"` / `"pressure"` | ``pressure`` | ``pressure`` |
    /// | `"gauge"` / `"balance"` | ``balance`` | ``balance`` |
    ///
    /// `"mixed"` is why this exists and why it returns a pair: it is the one legacy value whose two
    /// surfaces disagree, so mapping it through ``legacyRawValues`` would have to pick a winner and
    /// silently change how one surface looks. Splitting it instead means a user who deliberately
    /// chose Mixed sees **no** visual change across the upgrade.
    ///
    /// Read by both `PersistedConfig.migrateBarStyleIfNeeded` (the stored `UserDefaults` value) and
    /// `AppearanceConfigValues`' decode (an exported config written by an older build), so the two
    /// paths can never disagree about what `"mixed"` — or `"simple"` — meant.
    public static func legacySurfaceStyles(for raw: String) -> (menuBar: BarStyle, dropdown: BarStyle)? {
        if raw == "mixed" { return (.pressure, .progress) }
        guard let style = BarStyle(rawValue: raw) ?? legacyRawValues[raw] else { return nil }
        return (style, style)
    }

    /// Decode with legacy support *before* the forward-compatible fallback (#307): a `"pacing"`,
    /// `"simple"` or `"gauge"` raw written by an older build maps to the case that replaced it, rather
    /// than being swallowed by the unknown-value fallback. Without this, importing an older config
    /// would silently turn `Pace` into `Progress` (#307) or `Gauge` into `Progress` (#388) — the exact
    /// trap each rename had to avoid.
    ///
    /// This decodes **one surface**, so `"mixed"` is deliberately *not* handled here: a pair cannot
    /// come out of a single-value container. It is split one level up, in `AppearanceConfigValues`'
    /// decode, where which key belongs to which surface is known (#329).
    ///
    /// An unrecognised raw still falls back to ``progress`` (the default, i.e. the shipped behaviour)
    /// instead of throwing, so a *newer* build's value never makes an older one fail. Mirrors
    /// `TopBarHiding`'s unknown philosophy.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BarStyle(rawValue: raw) ?? BarStyle.legacyRawValues[raw] ?? .progress
    }
}
