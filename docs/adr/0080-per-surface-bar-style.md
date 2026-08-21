---
status: accepted
date: 2026-08-11
supersedes: []
---

# ADR-0080: Bar style is chosen separately for each surface

> Partially supersedes [ADR-0062](0062-configurable-bar-presentation.md) (§1 `BarStyle`): the style
> choice is **no longer** a single key whose values encode a pair of surfaces, and the `.mixed` case is
> gone — `BarStyle` now describes the presentation of **one** surface, and there are two surfaces,
> each with its own key. The rest of 0062 (`CalmColorMode`, `FarBehindInterval`, the presets
> mechanism itself as the single source of defaults) still stands.

> Partially supersedes [ADR-0079](0079-centred-zero-gauge-scale.md) (§"What stayed unchanged," the
> "Presets" point): `.workHarder` is no longer Mixed, it's **Gauge**, and Gauge is no longer
> "manual-selection only." The rest of 0079 — the `gaugeOffset` scale, `BarScale`, the center tick,
> its `centreTick` role — stands unchanged in full.

## Context

[ADR-0062](0062-configurable-bar-presentation.md) introduced `BarStyle` as a **three-way** choice
where each value set a pair: "what to draw in the menu bar / what in the popup":

| case | menu bar | dropdown |
|---|---|---|
| `.progress` | Progress | Progress |
| `.mixed` | Pressure | **Progress** |
| `.pressure` | Pressure | Pressure |
| `.gauge` (from [0079](0079-centred-zero-gauge-scale.md)) | Gauge | Gauge |

`.mixed` existed for a specific reason, and the reason was sound: a time marker is cramped on a
34 pt menu-bar bar, and the popup has plenty of room — "a marker only where there's room for one."
But the way this was expressed mixes two independent things into one value: **which presentation**
and **on which surface**. Consequences:

- **The type knows about surfaces.** `BarStyle` carried four derived properties —
  `menuBarScale`, `popupScale`, `menuBarShowsTimeMarker`, `popupShowsTimeMarker` — each a "case →
  surface" table. Adding a style meant adding a row to two tables that were easy to let drift apart.
- **Most combinations were unreachable.** Three presentations × two surfaces is nine pairs; there
  were four cases. "Gauge in the bar, Progress in the popup" is a perfectly reasonable choice (the
  popup has room for two positional labels, the bar doesn't), and there was no way to express it.
- **`.mixed` doesn't scale.** It pins exactly one of the nine pairs. Each additional one would need
  its own case with its own name — and "Pressure-menu-bar-Gauge-dropdown" stops being a style name
  and becomes a description of a combination.
- **Gauge was left orphaned among the presets.** [0079](0079-centred-zero-gauge-scale.md) added a
  fourth style but didn't give it to any preset, so choosing it **always** flipped the preset control
  to "Custom." A style that belongs to no preset sits outside the model where the preset is the sole
  source of defaults (0062).

## Decision

**`BarStyle` describes the presentation for one surface; whoever reads it picks the surface.**

```swift
public enum BarStyle: String, … { case progress, pressure, gauge }

public var scale: BarScale { … }                        // replaces menuBarScale/popupScale
public var showsTimeMarker: Bool { scale == .window }   // replaces the pair of flags
```

Stored as two independent keys — `menuBarStyle` and `dropdownStyle` — and read through two
`PersistedConfig` accessors. All nine pairs are available; the former `.mixed` is simply the pair
`(.pressure, .progress)`, which can now not only be reproduced but named.

`BarScale` doesn't change: renderers still branch on it, and the `switch`es stay exhaustive.

### Presets give one style to both surfaces

| Preset | menu bar | dropdown | before |
|---|---|---|---|
| Chill | Pressure | Pressure | unchanged |
| **Work harder!** (default) | **Gauge** | **Gauge** | Pressure / Progress (`.mixed`) |
| Control freak | Progress | Progress | unchanged |

Presets are three **coherent** looks, so a preset that disagrees with itself between surfaces would
be a fourth look. Mixing surfaces is exactly what falling into "Custom" is for. A side effect: the
three presets cover the three styles exactly once each, so Gauge is no longer an orphan, and no
style is unreachable from the preset row alone (the `everyPresetUsesOneStyleOnBothSurfaces` test).

### Migration: `"mixed"` decomposes, it doesn't collapse

The rule lives in one place — `BarStyle.legacySurfaceStyles(for:)`, which returns a **pair**:

| stored raw value | menu bar | dropdown |
|---|---|---|
| `"mixed"` | `.pressure` | `.progress` |
| `"pacing"` / `"progress"` | `.progress` | `.progress` |
| `"simple"` / `"pressure"` | `.pressure` | `.pressure` |
| `"gauge"` | `.gauge` | `.gauge` |

`"mixed"` is the only value whose surfaces diverge, and that's exactly why the helper returns a pair
rather than a single style: mapping it to **one** style would mean picking a winner and silently
changing the look of one of the surfaces. That's why it isn't in `legacyRawValues` — that table maps
a raw value to a single `BarStyle`, and `"mixed"` doesn't fit it by construction.

The helper is read by **both** consumers — `PersistedConfig.migrateBarStyleIfNeeded` (the stored key)
and the `AppearancePresetValues` decode (a config exported by an older build). So an in-place update
and importing an old dump give the same result; this is the same reason 0076 kept `legacyRawValues`
shared between migration and decode.

### Who the default change affects

Migration relies **only** on the stored key, because the preset is never stored — it's **derived**
from the set of values (`AppearancePreset.matching(_:)`). So "migrate whoever had Work harder!" is
technically impossible, and also unnecessary:

- **The key exists** → the user deliberately chose a style; it's decomposed across the two surfaces,
  and the look doesn't change **by a single pixel**, including for `"mixed"`.
- **The key is absent** → the user never made a choice and was seeing `.workHarder`'s default.
  Nothing is written, and both getters fall through to the new default — Gauge. This is exactly "was
  Work harder! → became Gauge," and only for those the claim actually applies to.

So the default shift affects exactly those who never expressed a preference, and no one else.

## Consequences

- **Nine pairs instead of four.** Including ones that didn't exist before: a denser style in the
  roomy popup and a quieter one in the cramped bar — the same logic that produced `.mixed` is now
  available in any combination, not just one hardcoded one.
- **`BarStyle` doesn't know about surfaces.** One `scale`, one `showsTimeMarker`; a new style adds
  one row to one `switch` instead of two rows to two tables.
- **Two rows in Settings, each in its own section.** The "Bar style" control sits first in **Menu Bar
  Widget** and first in **Dropdown Widget** — right where the other settings for that surface already
  live. The unnamed section above them used to hold only **Far behind pace interval**; after
  [ADR-0081](0081-weekly-capacity-gate-for-blue.md) that option was removed, so the section vanished
  entirely.
- **Hints aren't duplicated.** The full description of the three styles sits under the menu-bar row;
  under the dropdown row there's a single line saying these are the same three styles, chosen
  separately. Repeating three paragraphs a few lines down would bloat the panel with no new
  information.
- **An existing user with an explicit choice sees no change.** Including anyone who chose Mixed: they
  get exactly the same pair, just written as two keys.
- **Anyone who never chose sees Gauge.** The default shifted, and that's deliberate: Gauge is the
  only one that draws the under-spending side ([0079](0079-centred-zero-gauge-scale.md)), and
  `.workHarder` is the preset meant to nudge toward that.
- **The `barStyle` key became legacy-only.** It's read only by migration, after which it's deleted;
  `resetAppearanceToDefaults()` sweeps it too, so the old value doesn't sit around waiting to
  re-seed the new keys on a later launch.
- **Config export has thirteen keys** instead of twelve, and two of them sit in different sections of
  the panel — the dump's key order still mirrors the order of the on-screen controls.

## Alternatives considered

- **Keep `.mixed` as a fourth segment alongside the two new rows.** Would give "compatibility without
  migration," at the cost of two ways to say the same thing: `.mixed` and the pair
  `(.pressure, .progress)` would render identically from different config states. The preset
  indicator would have to treat them as equal, and `matching(_:)` would have to compare equivalence
  classes rather than values.
- **Migrate `"mixed"` to Pressure on both surfaces.** Simpler (one `legacyRawValues` table instead of
  a pair), but it changes the popup's look for anyone who deliberately chose Mixed specifically for
  the marker in the dropdown. Since that choice was the entire reason `.mixed` existed, such a
  migration would undo exactly what the user expressed.
- **Store the pair as one string (`"pressure/progress"`).** One key instead of two, but then
  parsing/validating the pair becomes its own format, and the two independent UI controls would still
  each be writing half of it. Two keys is exactly the structure the setting has.
- **Give Gauge its own preset instead of changing `.workHarder`.** A fourth segment in the preset
  row, which already has four positions counting "Custom." Presets describe how **loud** the
  presentation is, not the geometry; a separate "Gauge" preset would mix two axes into one row.
