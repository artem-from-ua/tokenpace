---
status: accepted
date: 2026-08-13
supersedes: []
superseded_by: []
---

# ADR-0089: The Gauge center tick — in the calm-fill tone, 1 pt taller

> **Style renamed: `Gauge` → `Balance`** ([ADR-0109](0109-centred-style-renamed-to-balance.md),
> #388). The tick, its tone, its height, and the `centreTick` role — unchanged; only the name of
> the style whose zero mark it draws has changed. This ADR's filename keeps the old slug: an
> `accepted` ADR is immutable, and other docs link to it.

> **Refined by [ADR-0096](0096-zero-tick-on-pressure.md)**: the tick is no longer Gauge-specific —
> Pressure draws the same one, at its own zero. The tone and height set here still stand for both,
> but a `zeroTickAlpha` multiplier of **0.55** is layered on top: the `bright()` alpha (0.865)
> stays shared with the reset text and ⚠️ and doesn't move, while the tick fades relative to it. So
> "the same tone as the calm fill" should now be read as "the same tone, dimmed by 0.55."

## Context

[ADR-0079](0079-centred-zero-gauge-scale.md) introduced the Gauge center tick in the menu bar — a
fixed vertical mark at 0.5, from which the colored strip grows. The tick is drawn **under** the
track, so only its tips are visible, poking out above and below the pill.

The color choice back then was its own role, `centreTick`, defaulting to `secondaryLabelColor` — "a
notch brighter" than the marker's outline (`indicatorRing`) and than the popup ruler's tick
(`tick`). The tick borrowed its height from the time marker: `Metrics.tickHeight` = 9 pt.

On a live bar, both choices read worse than they did on paper:

- `secondaryLabelColor` is a separate gray, unlike anything else: not the tone the menu bar uses to
  draw **any** other neutral element. Next to the system icons it reads as a third, foreign shade.
- 9 pt at a 1 pt width — the tips end up 2 pt above and below the 5-pt pill. At that reach, a dim
  gray gets lost, and finding zero becomes a search.

## Decision

**Color — the calm-fill tone: the `centreTick` role defaults to the `calmWhite` value
(`labelColor`), passed through `bright()` at the point of drawing — exactly like the bar's calm
fill.** This is the menu bar's monochrome foreground: white on a dark bar, black on a light one,
with the same `brightAlpha` = 0.865 that aligns our elements with the system clock. Zero is a scale
fixture, not a status, so it takes the neutral foreground rather than its own gray a notch darker.

**Height — a dedicated metric, `centreTickHeight` = 10 pt** (instead of the borrowed
`tickHeight` = 9). Sharing a height with the time marker was a coincidence of the first draft, not
a decision — the two shapes are sized for opposite jobs. The extra point gives the tips poking out
from under the track the legibility they lacked at a fifth of the marker's width.

The rest of the 0079 design is unchanged: `centreTickWidth` = 1 pt (a fifth of the Progress
marker's 5 pt), drawn **under** the track, present in **every** state including idle, never a
pacing color. The role stays separate rather than being replaced by `calmWhite`: the value is
identical, but these are two different surfaces, and the color tuner must be able to tell them
apart.

## Consequences

- The bar carries fewer shades: the tick no longer introduces its own gray, and instead uses the
  same neutral foreground the calm fill is already drawn with.
- The tick flips with appearance (white/black) instead of being a fixed halftone.
- ADR-0076's objection, which kept ticks out of the menu bar entirely ("a lone vertical tick on a
  34 pt bar looks like a Progress time marker"), remains overturned: width 1 vs. 5 pt, drawn under
  the track vs. over it, a fixed position vs. `timeFraction`, and a neutral color vs. pacing. A
  height of 10 vs. 9 doesn't erase that difference — it operates within shapes already
  distinguished along four other dimensions.

## Superseded from ADR-0079

Everything still stands except two details in the section "Why this isn't the tick that 0076
rejected":

- the paragraph "**Color — its own role, `centreTick`, defaulting to `secondaryLabelColor`**" — in
  the part about the **default value** and the "a notch brighter" argument. The claim "its own
  role, menu-bar-only, configurable in the color tuner" still stands;
- the "width × height" row of the comparison table: **1 × 10** pt, not 1 × 9. Read the "color" row
  as "neutral `centreTick` (the calm-fill tone, `labelColor` through `bright()`)."

The `gaugeOffset` scale, `BarScale`, the drawing order, and the tick's presence in every state are
unchanged.
