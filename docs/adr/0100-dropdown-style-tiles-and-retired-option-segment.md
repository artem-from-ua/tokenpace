---
status: accepted
date: 2026-08-15
supersedes: []
superseded_by: [0104]
---

# ADR-0100: The dropdown picks a style by picture, and the `With ⌥ Option` segment goes away

> **§5–§6 superseded by [ADR-0104](0104-appearance-named-for-behaviour-on-three-layers.md)**
> ([#381](https://github.com/artem-from-ua/cc-timer/issues/381)): `.optionOnly` **no longer stays in
> the enum** — the case is removed, and the old raw value is resolved through
> `PopupSectionVisibility.legacyRawValues` in `.onceUsed`; the separate
> `migrateOptionOnlyVisibilityIfNeeded()` migration and its
> `sectionVisibilityMigratedFromOptionOnly` marker are retired in favor of a single key move. The
> legacy migration of the Boolean `showModelSpecificLimits == false` now leads to
> `whenItNeedsAttention` (the same value under the new name). §6's renaming carries through to every
> row, key, and value in the pane, and the segments in both rows are reversed (quieter on the left).
> **§1–§4 still stand** — tiles on both surfaces, baking the specimen under the theme's vibrant
> appearance, measuring by the track without scaling, and ⌥ having no effect on the specimen.

> Finishes what [ADR-0093](0093-bar-style-picked-by-picture.md) started (whose §5 left the dropdown
> as a text segmented control "temporarily") and **fulfills the prediction** made in
> [ADR-0097 §2](0097-bar-style-preview-rendered-at-runtime.md) that the second surface's preview
> would have its own rules for appearance. Partially supersedes
> [ADR-0087](0087-above-zero-section-visibility.md) as far as segment composition goes.

## Context

The two surfaces had **different controls for the same choice**: the menu bar row used three tiles
with a rendered widget; the dropdown row used a text `SegmentedControl` reading `Pressure | Gauge |
Progress`. ADR-0093 §5 called this asymmetry deliberate and temporary: "we're testing the shape on
one surface, the dropdown moves in a separate PR." The shape stuck. The second surface's turn had
come.

In parallel, a second problem accumulated — smaller, but the same class of "an option that adds
nothing." Both of the dropdown's section-visibility rows offered a **`With ⌥ Option`** segment. But
⌥ is already added via `||` to **every** other mode in `PopupSectionVisibility.shows(...)`:

```swift
case .aboveZero:  return isAboveZero || optionHeld
case .nonCalm:    return isNonCalm   || optionHeld
case .optionOnly: return optionHeld
```

That is, holding ⌥ already reveals the group under any other choice. The only way `.optionOnly`
differed was that it **hid** the group exactly when its data became interesting (the row turned red,
money was spent). That isn't something anyone picks on purpose.

## Decision

### 1. The dropdown's `Style` row — the same tiles

One `BarStylePicker` control for both surfaces, with `enum Surface { menuBar, dropdown }`. Press
state, the accent border, hover, labels, and accessibility are shared; the difference sits exactly
where ADR-0097 said it should.

The row is renamed from `Bar style` to **`Style`**: it sits on a page already called `Menu bar` or
`Dropdown`, so the word "bar" was repeating context already given.

### 2. The dropdown specimen is baked under the current theme's **vibrant** appearance

Not under `.aqua`/`.darkAqua`. Live bars are drawn inside `NSMenu`, which is a vibrant surface, and
the palette resolves differently there. Measured, the track and the pacing green:

| appearance | track | green |
|---|---|---|
| `aqua` | `0,0,0 α0.18` | `40,205,65` |
| **`vibrantLight`** | **`211,211,211 α1.0`** | **`30,195,55`** |
| `darkAqua` | `255,255,255 α0.17` | `50,215,75` |
| **`vibrantDark`** | **`51,51,51 α1.0`** | **`60,225,85`** |

Two consequences, and the second isn't obvious. The hues are simply different — aqua's green isn't
the green the popup actually draws. And under vibrant the track resolves **opaque**, so it stops
depending on what's beneath it; under aqua it's semi-transparent, which is exactly why it used to
pick up the card's color. `211` is exactly the gray measured off the live preview window next to it.

The tile's backing is the **popup's card** (`cardPlateFillOpaque`: 255 light / 30 dark), not the menu
plate the card sits on (236/33). Bars sit on the card, so the specimen sits on it too.

This is the "difference" ADR-0097 §2 anticipated but couldn't put a number on: the dropdown preview
**follows the theme**, the menu bar preview does not (the menu bar stays dark even in light mode, so
it uses a fixed `.vibrantDark` over a black plate). **The two surfaces deliberately follow different
rules.**

### 3. Geometry is measured by the **track**, and nothing is scaled

The tile stays the menu bar's 80×48, so the two Settings rows read as a matched pair. Inside are two
bars (5h on top, 7d below) taken from the same `climbing` stub frame as the menu bar tiles: the two
surfaces explain three styles with **the same set of numbers**, so any difference on screen is a
rendering difference, not a data difference.

The bar is drawn **1:1 on both axes**, only shortened to 56 pt. Track thickness (6 pt) and the marker
(7×14) stay at their live size — ADR-0093 §3 requires this, and any scaling would blur them.

Layout is measured from the **track**, not the view's frame and not the marker. `PopupBarView.viewHeight`
reserves `tickGap + tickLength` for the ⌥ ruler, which the tile doesn't have, and the marker
overhangs the track by `(indicatorHeight − barHeight)/2` on each side; measuring from either of these
leaves the pair sitting **above** center. Two tracks split the tile into three equal parts.

Considered and rejected: rendering at the live 252 pt width and showing the left fragment. Measured —
the tile comes out as a **bare gray track**, because in this frame both the marker and the colored
strip sit past the bar's first quarter. Shortening the bar instead shifts the mark by at most ~2% of
the width (the `minStripWidth/2` inset is a constant derived from **height**, not length).

### 4. ⌥ has no effect on the specimen

`optionHeld` stays `false`. In the live popup, the modifier shows the explanatory ruler and the `0`
label **only while held** — a tile baked with them would advertise a state the row isn't actually in.
Nothing identifying is lost: the zero tick that tells Pressure from Gauge is drawn unconditionally.

### 5. The `With ⌥ Option` segment is removed from **both** visibility rows

The `.optionOnly` case **stays in the enum** — old saved values still have to decode, and this is the
same procedure ADR-0087 applied to `.nonCalm` on the credit row. But no control offers it anymore,
and `PersistedConfig.migrateOptionOnlyVisibilityIfNeeded()` rewrites a saved value to `.aboveZero` —
**on both keys, under one marker**, `sectionVisibilityMigratedFromOptionOnly`. Without the migration,
the row would open with no segment highlighted at all.

At the same time, the legacy migration of the old Boolean flag (`showModelSpecificLimits == false`)
now leads to `.nonCalm` instead of the removed `.optionOnly`.

### 6. `Above zero` → `Once used`

The old name described **threshold mechanics** — a number crossing zero. What the reader actually
picks is **behavior**: show this limit from the moment I started using it. "Once" carries the
starting moment that the threshold phrasing only implied. Removing the ⌥ segment freed up the width
that had been forcing the name to stay two short words.

## Consequences

**ADR-0093's note about "temporarily different controls" no longer stands** — both surfaces now
share one control.

**The dropdown preview needs checking in both themes.** The menu bar tiles stay the same across a
theme change (fixed `.vibrantDark`); the dropdown tiles **must redraw**. The specimen is a baked
`NSImage`, so `BarStylePicker` reads `colorScheme`: without that dependency the view wouldn't rebuild
and the tile would get stuck in whichever theme it was first drawn under.

**Anyone who had `.optionOnly` set silently moves to `.aboveZero`.** This is a visible behavior
change for them: a group that ⌥ used to be the only way to reveal now appears on its own as soon as
it has something in it. The chosen compromise is the closest surviving intent ("don't show it
empty"), and it's the only one **both** rows offer.

**`PopupBarView` became dual-purpose.** It's no longer just the live bar — its `render(in:)` now
draws the tiles too. Any change to the drawing code now touches two surfaces, and that's deliberate:
it's exactly the shared drawing code that makes it impossible for the preview to diverge from the
bar.

**A live-popup bug was found and fixed along the way.** The marker's outline was computed outside
`performAsCurrentDrawingAppearance`, so it baked one tone for both themes (`13,96,26`). The preview,
which renders the same view under an **explicitly set** appearance, made the defect visible; the live
popup never showed it only because the view there always draws in its actual, live appearance.
