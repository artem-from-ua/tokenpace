---
status: superseded
date: 2026-08-02
supersedes: []
superseded_by: [0076, 0080, 0081, 0098, 0112]
---

# ADR-0062: Configurable pacing-bar presentation — bar style, Calm mode, far-behind threshold

> **Postscript ([#381](https://github.com/artem-from-ua/cc-timer/issues/381)).** §2 still stands in
> substance, but not by name. `CalmColorMode` is now called
> [`ColorAdvice`](../../Sources/TokenPaceKit/ColorAdvice.swift), its label is `Colors tell me`, its
> key is `menuBar.colorsTell`, and the cases `off` / `yellowGreen` / `yellowGreenBlue` became
> `howItsGoing` / `slowDownOrSpeedUp` / `slowDown`
> ([ADR-0104](0104-appearance-named-for-behaviour-on-three-layers.md)). The derived `mutesCalm` /
> `mutesBlue` are unchanged, so rendering stays the same. **The option's scope was narrowed**
> ([ADR-0105](0105-color-advice-governs-pacing-bars-only.md)): it now governs only pacing bars — not
> the service dot, not the currency glyph, not the idle pill — and does nothing at all under
> Pressure, since the calm side is muted unconditionally there. `showTicks`, `FarBehindInterval`, and
> `barStyle` from this ADR are no longer in storage; the remaining keys were renamed with a surface
> prefix (`menuBar.` / `dropdown.`).

> **§"Presets (expanded)" superseded by
> [ADR-0112](0112-appearance-presets-preview-apply-commits.md)**: the segmented control is gone
> (radio buttons from [ADR-0099](0099-appearance-nests-its-two-surfaces.md)), and `Custom` as a
> non-clickable indicator is replaced by a `My setup` row — the saved config itself, always
> clickable. Clicking a preset is now a **preview**, and only the `Apply` button writes it. §"Single
> source of defaults — the `.workHarder` preset" still stands.

> **Partially superseded by [ADR-0098](0098-ruler-split-identify-always-explain-on-option.md)**: §4
> no longer stands — `showTicks` is removed from Settings, the presets, and the export. The ruler is
> now split by what each mark does: the zero tick is always visible, the rest sit behind ⌥ Option.
> What still stands: §2 `CalmColorMode` and the presets as the single source of defaults.
>
> **Partially superseded by [ADR-0081](0081-weekly-capacity-gate-for-blue.md)**: §3 no longer
> stands — `FarBehindInterval` is removed from Settings, the multiplier is fixed at ×2, and
> `BarLayout.behindMultiplier` is replaced by `blueAllowed`, which carries the weekly-capacity gate.
> The rest (§2 `CalmColorMode`, §4 `showTicks`, the presets) still stands.
>
> **Partially superseded by [ADR-0080](0080-per-surface-bar-style.md)** (#329): §1 no longer stands
> for the part about "one enum for two surfaces." The `.mixed` case is removed, and `BarStyle` now
> describes the presentation of **one** surface — the menu bar and the popup each store their own
> style under its own key (`menuBarStyle` / `dropdownStyle`), so all nine pairs are available,
> not four. The derived `menuBarScale` / `popupScale` / `menuBarShowsTimeMarker` /
> `popupShowsTimeMarker` are replaced by a single `scale` and a single `showsTimeMarker`. The
> `.workHarder` preset now sets **Gauge** on both surfaces instead of Mixed. The rest — `CalmColorMode`,
> `FarBehindInterval`, `showTicks`, the preset as the single source of defaults — still stands.

> **Partially superseded by [ADR-0076](0076-pressure-scale-for-marker-less-bar.md)** (#307): a strip
> with no marker no longer equals the width of the pacing gap (`gapEnd − gapStart`) — it is now
> computed on a renormalized `[now .. reset]` scale (`BarLayout.pressureLength`), and the ticks
> beneath it mark quarters of remaining time rather than fractions of the window. UI names changed
> too: "Pace & Time" → **Progress**, "Pace" → **Pressure**; the enum cases and their `rawValue` were
> renamed too (`.pacing` → `.progress`, `.simple` → `.pressure`), with old values migrated on
> launch. The rest of this entry — the per-surface choice, `CalmColorMode`, `FarBehindInterval`,
> `showTicks`, the presets — still stands.

> Partially supersedes [ADR-0061](0061-far-behind-blue-pacing-zone.md): the behind threshold is no
> longer a **fixed** width (now configurable via `FarBehindInterval`), and the boolean "Work harder"
> option is replaced by the three-state `CalmColorMode`. The blue severity case, the 20-minute start
> override, the 5h/7d scope, and `ColorRole.paceBlue` from 0061 still stand.

## Context

[ADR-0061](0061-far-behind-blue-pacing-zone.md) added the blue far-behind zone with a **fixed**
threshold (60 min / 5h, 24 h / 7d) and a boolean "Work harder" toggle (keep blue colored under
calm). #224 expands bar presentation across several axes that were previously hardcoded or absent:

- **How the bar is presented.** Until now a bar always had a colored `gap` plus a current-time
  marker ("you are here"). Not everyone needs dense pacing graphics — for some, the state color
  alone, with no marker, is enough.
- **How much color to mute** was two separate booleans (`calmMenuBarColors` +
  `workHarderColors`), whose combination ("calm on + work harder off" = mute blue too) was
  unintuitive.
- **The green→blue threshold** was fixed — there was no way to make blue rarer/more frequent or
  turn it off entirely.
- **The ticks under the bar** in the popup were always drawn.

## Decision

**Pull bar presentation out into four render-only options, each a kit enum with forward-compatible
decoding, with a single source of defaults (the `.workHarder` preset).**

### 1. `BarStyle` — how it's presented (per surface)

A three-state enum that chooses whether to draw a **time marker** separately for the menu bar and
the popup:

- `.pacing` — gap + marker on **both** surfaces (the pre-reform presentation).
- `.mixed` — a strip (pace-only) in the **menu bar**, gap + marker in the **popup** (a marker only
  where there's room).
- `.simple` — a strip (pace-only) on **both**: no marker.

**Strip (pace-only)** — a colored band **from the left edge**, whose length equals the width of the
pacing gap (`gapEnd − gapStart`), in the same semantic state color. That is, exactly as much color
as in Pace & Time, but without the time mark. The branching in the drawing code goes through
`BarStyle.menuBarShowsTimeMarker` / `popupShowsTimeMarker`, so `StatusItemView` and `PopupBarView`
don't drift out of sync.

> ⚠️ **Superseded by [ADR-0076](0076-pressure-scale-for-marker-less-bar.md).** The strip's length no
> longer equals `gapEnd − gapStart` — it is `BarLayout.pressureLength` = `(r + k − 1)/k`, so it no
> longer carries the **same** amount of color as Progress: it is wider precisely where the state is
> more acute.

### 2. `CalmColorMode` — what gets muted (replacing two booleans)

A three-state enum that **replaces** the pair `calmMenuBarColors` + `workHarderColors`. The name
describes which **calm** colors mute to white (orange/red warnings are always colored):

- `.off` — nothing mutes.
- `.yellowGreen` — green/yellow mute; far-behind **blue stays** (= the old "calm on + work harder
  on").
- `.yellowGreenBlue` — green/yellow **and** blue mute (= the old "calm on + work harder off", the
  quietest).

The render layer reads two derived flags — `mutesCalm` and `mutesBlue` — so `calmedGapColor`'s
logic is unchanged; only the source of the flags becomes one enum instead of two keys.

### 3. `FarBehindInterval` — a configurable green→blue threshold

A four-state enum that scales the behind width from ADR-0061 (base 1h / 5h, 1d / 7d) by a
multiplier:

- `.off` — no blue at all (threshold → +∞).
- `.short` (×1) — 1h / 1d (= the old fixed threshold from ADR-0061).
- `.medium` (×2, **default**) — 2h / 2d.
- `.long` (×3) — 3h / 3d.

`behindThreshold(windowDurationSeconds:multiplier:)` multiplies the base width by the multiplier
(`.off` → `.greatestFiniteMagnitude`, so `surplus > threshold` is never true). The multiplier is
carried by a new field, `BarLayout.behindMultiplier` (mirroring `windowDurationSeconds`), so **Kit
severity and AppKit color read the same value** — they never diverge. `AppKit` passes
`PersistedConfig.farBehindInterval.multiplier ?? 0` into `barLayout(...)` via `MenuBarLayout.make` /
`PopupLayout.make`.

### 4. ~~`showTicks` — ticks under the bar in the popup (opt-out)~~

> **Superseded by [ADR-0098](0098-ruler-split-identify-always-explain-on-option.md).** The option is
> gone: the ruler is now split by what each mark does — the zero tick (identify the style) is
> always visible, the rest (explain the scale) sit behind ⌥ Option.

A boolean gate on `PopupBarView.drawTicks`. The menu bar has no ticks, so this option is popup-only.

### Single source of defaults — the `.workHarder` preset

`AppearancePreset.default = .workHarder` (#224). Every Appearance getter in `PersistedConfig`, when
its key is absent, reads the value from `AppearancePreset.defaultValues.<field>` instead of its own
literal. Consequence: **a new Appearance option automatically defaults to its `.workHarder`
value** — the default lives in one place (the preset), not duplicated across getters. Fresh
install / Reset → Work harder!.

### Presets (expanded)

> ~~Three presets are governed by a segmented control (`Chill | Work harder! | Control freak |
> Custom`), where **Custom** is a non-clickable indicator.~~ Superseded by
> [ADR-0112](0112-appearance-presets-preview-apply-commits.md) (the control is radio buttons from
> [ADR-0099](0099-appearance-nests-its-two-surfaces.md); the fourth row is `My setup`, clicking a
> preset previews it). The table below is historical: `showTicks` and `FarBehindInterval` are
> removed from storage, and the style names changed
> ([ADR-0109](0109-centred-style-renamed-to-balance.md)).

Preset values as of this ADR:

| Preset | CalmColorMode | BarStyle | showTicks | FarBehindInterval |
|---|---|---|---|---|
| Chill | `.yellowGreenBlue` | `.simple` | off | `.off` |
| Work harder! (**default**) | `.yellowGreen` | `.mixed` | on | `.medium` |
| Control freak | `.off` | `.pacing` | on | `.medium` |

> ⚠️ The `BarStyle` column is superseded by [ADR-0080](0080-per-surface-bar-style.md): a preset now
> sets **two** values (menu bar / dropdown), and `.workHarder` is now `.gauge` on both. The current
> table lives there.

## Consequences

- **Bar style, Calm mode, and the far-behind threshold are now configurable** through Settings →
  Appearance, each a single enum key in `PersistedConfig`.
- **A conflict state in the UI.** When `FarBehindInterval == .off`, the "Yellow + Green + Blue" item
  in the Calm control is disabled (there's no blue to mute) — a popover explains why, the same way
  the presets' "Custom" indicator does.
- **The `workHarderColors` key is gone** — merged into `calmColorMode`. The old logs
  `calm-colors: menu-bar set` / `work-harder-colors: menu-bar set` are replaced by
  `calm-color-mode: set`.
- **Defaults shifted** relative to ADR-0061: the default far-behind threshold is now 2h/2d (×2), not
  1h/1d; the default preset is Work harder! (mixed bars, ticks on). An existing user with no saved
  keys will see the new presentation.
- **Two duplicated drawing paths** (`StatusItemView.drawBar`, `PopupBarView.draw`) each add a Simple
  branch — cross-reference comments and shared per-surface helpers guard against drift.
- **ADR-0061 still stands** for the blue severity case, the start override, the 5h/7d scope, and
  `paceBlue` — this entry only makes the width/muting configurable.
