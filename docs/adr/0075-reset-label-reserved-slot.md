---
status: accepted
date: 2026-08-07
---

# ADR-0075: A reserved slot for the reset label — keyed on presence, with centered text

## Context

The menu bar is **right-aligned**, so any change to the widget's width shifts everything to its left
— including other apps' status items. This has already been the subject of a decision twice:
[ADR-0073](0073-awaiting-icon-reserved-slot-and-slide.md)
([#283](https://github.com/artem-from-ua/tokenpace/issues/283)) removed a high-frequency source (the
awaiting-hand icon), and [ADR-0074](0074-one-reset-format-on-both-surfaces.md)
([#284](https://github.com/artem-from-ua/tokenpace/issues/284)) narrowed the widest label from 37.2 to
23.6 pt and removed the jump at the **format change**.

What is left is something the format change cannot cure: the label's width depends on **glyph
count**. `10h` is three characters, `9h` is two. `resetLabelWidth` measured the drawn string, so the
widget "breathed" on every digit-count change
([#303](https://github.com/artem-from-ua/tokenpace/issues/303)).

Measured with `monospacedDigitSystemFont(ofSize: 11)`, with `ceil`, exactly as the code does:

| Label | Width |
|---|---|
| `1h` · `9h` · `4d` · `7d` | 14 pt — narrowest |
| `9m` | 17 pt |
| `10h` · `22h` · `15d` · `30d` | 21 pt |
| `10m` · `45m` · `49m` · `<1m` | **24 pt — maximum** |

Jumps the user actually saw: `10h → 9h` — 7 pt (once per 5-hour window), `49m → 1h` — 10 pt,
`10m → 9m` — 7 pt.

## Decision

**Reserve a slot the width of the widest possible label and center the text inside it — but only
while the label is actually being drawn.**

### 1. The slot is reserved from the label's presence, not from an option

This is a deliberate **departure** from §1 of [ADR-0073](0073-awaiting-icon-reserved-slot-and-slide.md),
where the slot is reserved from a setting and held even when the glyph is absent. The frequency
dictates the difference: the hand icon toggles dozens of times a day **during ordinary work**, so
reserving from the option was the only way to stop the jitter.

The reset label behaves differently. In the default `smart` mode, whether it shows at all is decided
by severity through `MenuBarLayout.selectReset` ([ADR-0029](0029-reset-countdown-selection-by-severity.md)),
meaning **most of the time there is no label at all**. Reserving from an option would mean holding
24 pt of emptiness in the calm state — exactly what
[ADR-0073](0073-awaiting-icon-reserved-slot-and-slide.md) rejected in its "reserve all five slots"
alternative: the calm state paying for the emergency state on a surface where width is already scarce.

So: `resetToShow == nil` → 0 pt, as before; the label is present → the full slot.

**The label's own appearance/disappearance still shifts the widget** (slot + `labelGap` ≈ 29 pt). This
is left as is, deliberately: in `smart` mode, that transition coincides with an event the user is
already watching for — the "a jump that explains itself" argument from
[ADR-0073](0073-awaiting-icon-reserved-slot-and-slide.md).

### 2. One width for every unit

A per-unit width (24 pt for minutes, 21 pt for hours and days) would save 3 pt, but would bring back a
jump at the unit change (`49m` → `1h`) — half of the very defect being fixed. Rejected: a slot that
jumps by itself is not a slot.

### 3. The width is computed, not hardcoded

`resetLabelSlot` is a `static let`, computed lazily from `resetLabelFont` — the same font the label is
drawn in. A literal `24` would silently stop matching the text if `ofSize: 11` or the system font ever
changed; a computed number cannot drift from what is actually drawn.

Four probes suffice — `<1m`, `00m`, `00h`, `00d`. This is enough because the font is
monospaced-**digit**: every digit has the same width, so a two-digit probe stands in for every value
of its unit, and `<1m` stands in for the single non-digit form. An exhaustive sweep of `1…49m` /
`1…22h` / `1…30d` produces the same number at ~500× the cost (45 ms versus 0.095 ms), so the probes
are the whole space, not a sample of it.

**Screen scale changes nothing.** Text metrics are in **points**; the backing scale (1×/2×/3×) affects
glyph rasterization, not width. Verified: `10m` = 23.6220703125 in all three contexts. Moving between
Retina and a non-Retina monitor, changing a "Scaled" resolution, or an external display need no
recomputation — hence `static let` (computed once per process lifetime), rather than a per-frame
computation or a subscription to screen-change notifications.

### 4. `max`, not a bare slot — a safeguard, not case coverage

`resetLabelWidth` returns `max(resetLabelSlot, measured)`. No live state ever reaches the second
branch: a blocked countdown resolves through `BlockingReset.forBlocked`, which requires **every**
window exhausted, and the 7-day window resets in at most 7 days (`7d`, 14 pt); even credits/monthly
tops out at `30d` (21 pt). There is no such thing as a three-digit day count.

`max` here is insurance against **silent clipping** in the future: a formatter change or a window with
a longer horizon would produce a string outside the probes, and a bare slot would cut off the glyph
with no signal at all, whereas `max` simply widens the element — today's behavior.

### 5. The text is centered in the slot

The empty space splits in half. Left alignment would dump all 10 pt against the element's right edge,
and the label would read as detached from it; right alignment would do the opposite, into the gap
after the bars. The offset is rounded to a whole point, so the glyphs stay on the pixel grid and don't
go soft next to the bars beside them.

### 6. The font is one constant

`monospacedDigitSystemFont(ofSize: 11, weight: .regular)` was duplicated between measurement and
drawing. Now that centering also depends on their identity (a mismatch would shift the text within its
own slot), the font was factored out into `resetLabelFont` — a single source for the slot, the
measurement, and the render.

### 7. The ADR-0073 §2 trap does not apply here — checked, not assumed

There, reserving width without advancing `originX` would have left an empty space to the right of all
the content, and the fix would not have worked. The reset label is the **last** element before the
right `hPadding` in both branches (`drawBars`, `drawBlockedReset`), so there is nothing to advance
after it. But that is exactly why the centering (§5) is part of the decision, not decoration: without
it, all the empty space would sit as a single block on the right.

## Consequences

- **The cost is up to 10 pt of empty space** around short labels (`1h`, `4d`) while the label is on
  screen. Centering splits it in half (5 pt on each side), so it reads as padding rather than a hole.
- **The widget's width no longer depends on what the label shows.** Verified on a real bar: at `5h`
  (14 pt) and at `12m` (24 pt), the neighboring system item sits at the same position.
- **The jitter-source table from [ADR-0073](0073-awaiting-icon-reserved-slot-and-slide.md) closes off
  one more row.** What remains is the credits icon, the pause glyph, and the service dot — all
  low-frequency and all toggling exactly when the user is already looking at the widget for that same
  reason.
- **The probes are pinned to the formatter.** If `ResetClock.relativeRounded` ever starts emitting a
  shape outside `<1m`/`Nm`/`Nh`/`Nd`, the probes will need updating; until then `max` (§4) prevents
  clipping.
- **There are no automated tests for this** — `StatusItemView` lives in the AppKit target, which the
  project does not test (the same caveat as in the "Consequences" section of
  [ADR-0074](0074-one-reset-format-on-both-surfaces.md)). A width regression is only visible on a
  screenshot of a real bar.

## Related

- [ADR-0073](0073-awaiting-icon-reserved-slot-and-slide.md) — the awaiting-hand icon's reserved slot;
  this ADR borrows the pattern itself and the "a jump that explains itself" argument. **Not**
  superseded: it's a different width source, both decisions still stand, and the reservation here is
  deliberately keyed differently (§1).
- [ADR-0074](0074-one-reset-format-on-both-surfaces.md) — one format on both surfaces; it narrowed the
  maximum to 23.6 pt, which is what made this reservation affordable.
- [ADR-0029](0029-reset-countdown-selection-by-severity.md) — when the countdown shows at all.
- [#303](https://github.com/artem-from-ua/tokenpace/issues/303) — the ticket with the measurements and
  the trade-off.
