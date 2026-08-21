---
status: accepted
date: 2026-08-14
supersedes: []
superseded_by: []
---

# ADR-0096: A zero tick on Pressure too — centered on the zero pill, dimmed

> **Postscript (0.96.1):** the tick's width is **1.5 pt**, not 1 pt, on both scales. On a live bar,
> tips one point thick turned out too hard to catch at a glance, especially after the
> `zeroTickAlpha` = 0.55 dimming this ADR introduced. The "don't confuse it with the Progress
> marker" argument still stands unchanged: it rests on the whole construction (thin, neutral,
> under the track, fixed), and 1.5 pt is still less than a **third** of the marker's 5 pt. At the
> same time, the tick's left edge was pinned to the **half-pixel grid**: at a fractional width,
> centering on a rounded `cx` placed the edge mid-pixel, and one side rendered softer than the
> other. The rest of the decision — position (center of the zero pill), tone, 10 pt height,
> drawn under the track — is unchanged.

## Context

[ADR-0079](0079-centred-zero-gauge-scale.md) gave Gauge a fixed tick at 0.5 — the zero the strip
grows from; [ADR-0089](0089-gauge-centre-tick-calm-tone.md) refined its tone and height. Pressure
deliberately had no such mark: `PopupBarView.tickFractions` recorded the objection — **a lone
vertical tooth on a 34 pt bar looks exactly like the Progress time marker**, so the two styles
would stop being distinguishable. So the menu bar under Pressure got no tick at all.

On a live bar this has a cost. The Pressure strip grows from a zero the eye can't see: a short
strip and a slightly shorter one differ by only a couple points of color, and nothing on the track
says where the scale starts counting. Zero also sits somewhere other than where it's expected:
`pressureLength` clamps **40% of the state space** (79% of it calm) to one minimal pill, so
"nothing is burning" and "almost exactly on plan" draw identically — with no reference point, that
sameness reads as "the bar is broken."

The 0079 objection hasn't gone anywhere, though — it needed to be resolved, not sidestepped.

## Decision

**Pressure gets the same tick as Gauge, at its own zero.** `drawCentreTick` became
`drawZeroTick(in:)` and branches on `BarScale`: `.centred` → the bar's center, `.remaining` → the
strip's zero. Progress (`.window`) gets nothing — the time marker already carries position there,
and a second vertical mark next to it would read as competing.

**The objection is resolved by construction, not by refusal.** The tick doesn't resemble the
Progress marker for exactly the same reasons it doesn't in Gauge: a fifth of the marker's width
(1 pt vs. 5), a neutral tone instead of a pacing color, drawn **under** the track (only the tips
visible), and it **doesn't move**. That's exactly what makes it safe to give to Pressure — the same
conditions Gauge already satisfies from 0079.

**Position — the center of the zero pill, not 0.0 and not 0.20.** A degenerate strip floors to the
minimal pill, whose left tip `PopupBarView.pillRect` pins to `rect.minX`; so the pill's drawn
center sits half a pill's width in from the edge. The position is **read from `pillRect`**, not
recomputed with local arithmetic — that way the tick stays anchored to the pill however that
pinning resolves, and `minStripWidth` remains the single knob for the whole inset geometry.

The 20% mark ("exactly on plan") the popup's ruler shows is deliberately **not** used: on a 34 pt
bar, a tooth there sits a couple points from the pill and reads as noise rather than a reference
point. A tick at 20% remains a feature of the popup, where the bar is longer and there's room to
spare.

**The tick is dimmed — on both scales.** A `zeroTickAlpha` multiplier of **0.55**, applied on top
of `bright()`. The tick is scale fixture, not data: it says where to measure from and never
changes, so at full text-alpha it would compete for attention with the bar's one mark that actually
moves. It's a multiplier rather than its own absolute alpha, and it's applied at the point of
drawing rather than inside `bright()`: that alpha is calibrated with a color picker against the
system clock and is **shared** with the reset text and ⚠️ — they must not move together with the
tick, and the multiplier keeps the tick anchored to that same calibration. Color from the tuner
uses that alpha as its base, so the carried-over role fades in the same proportion.

## Consequences

- The menu bar's Pressure no longer has a state with zero fixed marks on the track.
- The zero tick is **not** a Gauge-specific element: in mockups and write-ups it's mandatory in
  both marker-free menu bar styles. The impossible-combinations table in
  [ui-state-truth.md](../reference/ui-state-truth.md) has three rows added.
- Both scales became slightly quieter than the previous edition: Gauge also changes appearance,
  even though its geometry and position never moved.
- `tickFractions` remains **the popup's ruler**; its comment there was rewritten — it no longer
  claims the menu bar has no tick under Pressure.
- Render-only: `BarLayout`, `PacingSeverity`, presets, and migration are unchanged.

## Alternatives considered

- **A tick at 20%, like the popup's.** Rejected: on a 34 pt bar that's a couple points from the
  pill — noise instead of a reference point, and exactly the crowding that made 0079 drop ticks
  from the menu bar in the first place.
- **A tick at `rect.minX` (the track's left edge).** Rejected: the edge isn't the scale's zero,
  it's the saturation point for "far behind" (blue lives there). A mark there would flag the end of
  the strip, not a reference point.
- **`scaleX(0)` instead of `pillRect(at: 0).midX`.** Rejected: it ignores the left tip's pinning to
  `rect.minX`, so the tick would sit next to the pill instead of under it.
- **Change `brightAlpha`.** Rejected: it's shared with the reset text and ⚠️ and calibrated against
  the system clock — dimming the tick would shift them too.
