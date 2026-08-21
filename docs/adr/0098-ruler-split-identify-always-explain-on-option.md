---
status: accepted
date: 2026-08-15
supersedes: []
superseded_by: []
---

# ADR-0098: The bar ruler splits in two — identify always, explain under ⌥

> Supersedes §4 of [ADR-0062](0062-configurable-bar-presentation.md) (`showTicks` — the popup-only
> opt-out for tick marks): the option is gone entirely, and the ruler is no longer one unit that
> gets switched on or off.

> **Refined by** [ADR-0101](0101-pressure-is-the-gauge-ahead-half.md): the claim "styles differ
> even at rest" still stands, but now rests **solely** on the position of the zero tick (`0` versus
> `0.5`). Pressure and Gauge used to also differ in the length of the ahead side; now Pressure's
> ahead side is **numerically identical** to Gauge's ahead half, so the tick is the only thing that
> tells them apart outside of rest too. This also removes the last reason for the old 20% tick: the
> scale's zero and "exactly on pace" are now the same position.

## Context

[ADR-0062](0062-configurable-bar-presentation.md) §4 gave the popup's tick marks a toggle:
`showTicks`, a Bool gate on `PopupBarView.drawTicks`, popup-only. The `.chill` preset turned it off —
"a quiet look drops the ruler too."

Since then the ruler stopped being uniform. [ADR-0076](0076-pressure-scale-for-marker-less-bar.md)
reduced Pressure to a single tick at 20%, [ADR-0079](0079-centred-zero-gauge-scale.md) gave Gauge a
single tick at 0.5, [ADR-0092](0092-extra-usage-own-ruler.md) replaced the credit bar's teeth with
two month-edge labels, and [ADR-0096](0096-zero-tick-on-pressure.md) introduced a zero tick in the
**menu bar** for both marker-less styles. One toggle remained for all of this — and it switched off,
together, both what explains the scale and what lets you identify the style at all.

That's exactly where it started to hurt. Pressure's strip and Gauge's strip on a calm bar are the
same colored pill; the only thing telling them apart is **where** it grows from. The menu bar already
shows this with the zero tick; the popup did not. So the quietest preset made two different
presentations visually indistinguishable, and a user wondering "why does this bar look different" had
nothing on screen that would name the current style.

At the same time, a permanent ruler under every bar was the densest thing in a calm popup: a row of
teeth under three bars that nobody reads while at rest.

## Decision

**The ruler splits by the job each mark does, and the toggle goes away.**

1. **The zero tick — always.** The position the strip grows from: center (0.5) for Gauge, zero (the
   center of the zero-length pill, as in the menu bar) for Pressure. Drawn **under the track**,
   running through the bar, so only the tips show. This is what lets you identify the style at a
   glance: a tick in the middle is Gauge, a tick on the left is Pressure. **Progress is left alone** —
   its time marker already carries a position, and a second vertical mark next to it would read as a
   competitor.
2. **Everything else — under ⌥ Option.** Hour/day boundaries in Progress, the month-edge labels on
   the credit bar ([ADR-0092](0092-extra-usage-own-ruler.md)), and the `0` label under the tick
   itself. These are scale details: needed when a bar is interrogated, unnecessary when it's glanced
   at in passing. ⌥ in the popup already means exactly this ("show details" — expanded reset lines,
   data age, collapsed sections), so the ruler joins the existing level rather than starting its own
   switch.
3. **`showTicks` is removed.** From `AppearancePresetValues`, from config export, from the Settings
   page; the `UserDefaults` key became `Key.retiredShowTicks` and is swept up by an Appearance reset,
   and older dumps carrying this key import via the ignore-unknown-keys path — the same route as
   `farBehindInterval`. The `.chill` preset no longer differs from `.workHarder` by its ticks.
4. **The Pressure 20% tick is removed.** Next to the labeled zero, a second, unlabeled tooth a few
   points away read as a stray mark rather than a second reading; the boundary it marked is already
   carried by the color change.

The popup's tick is **the same** mark as in the menu bar: they share the role of the `centreTick`
color and the same construction (thin, neutral, under the track, static). The height is **scaled**,
not copied: 10 pt over a 5 pt track in the menu bar, 12 over 6 in the popup — the same proportion,
because a fixed protrusion on a taller bar would read as stubby. The width is 5/7 of the zero-length
pill: at the pill's full width the tick reads as a slab; at 1.5 pt it reads as a sliver peeking out
from behind the wider shape.

The `0` label takes its font, ink, and baseline from the month labels, so both labeled ticks in the
popup follow one convention. It hangs about 4 pt below its row into the `limitSpacing` gap that
nothing else draws into: bar heights stay exactly what the live menu renders.

## Consequences

- **Styles differ at rest**, with no ⌥ and no settings: three distinct silhouettes — a marker
  (Progress), a tick in the middle (Gauge), a tick on the left (Pressure).
- **The calm popup is quieter**: nothing under the bars but a single tick.
- **One fewer option.** Seven Appearance keys instead of eight; the Dropdown Widget page ends with
  two section-visibility rows.
- **The menu bar is unchanged.** ⌥ doesn't reach it (the modifier is only observable while the menu
  is open, and at that point the reader is looking at the popup), so it keeps just the zero tick
  ([ADR-0096](0096-zero-tick-on-pressure.md)) — a permanent pair of teeth on a 34 pt bar would be
  exactly the noise this design avoids.
- **The credit bar is label-free at rest.** [ADR-0092](0092-extra-usage-own-ruler.md) argued that the
  labels are what make the bar read as a calendar month; now they're on demand. The argument still
  stands for the state where a bar is interrogated; at rest, its role is taken over by the fact that
  this is the only bar in the popup drawn in Progress.

## Alternatives considered

- **Keep the toggle, add the zero tick.** Gives the same distinguishability but keeps an option whose
  "off" now hides exactly nothing useful: after the ruler split, "off" would mean hiding the
  ⌥-half, which is already hidden.
- **Everything under ⌥.** Quietest, but then Pressure and Gauge are indistinguishable at rest
  again — exactly the problem this started from.
- **Everything always.** Brings back the density the toggle was created to remove in the first
  place.
- **A through-tick for Progress too.** Rejected: the time marker already gives a vertical, and a
  second one next to it competes with it (the same objection as in
  [ADR-0096](0096-zero-tick-on-pressure.md)).
