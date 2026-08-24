# Source of truth for UI renders

The reference for any depiction of the interface outside the app itself: artifacts, mockups,
documentation, issue comments. **Every number here is taken from the code; every state has been
verified reachable.**

> The rule this grew out of: a render drawn from memory or from somebody else's mockup illustrates a
> product that does not exist. An analysis built on such a render is false even when the text is
> right.

Related documents: [menu-bar-signals.md](menu-bar-signals.md) solves the **inverse** problem — not
"how do I draw this state" but "what does what's already on screen mean" (first "is there a number",
and only then the bars); [bar-status-conditions.md](bar-status-conditions.md) — which data makes a bar
take which color; [users-and-goals.md](users-and-goals.md) — the "is this signal useful" test.

## Before you draw anything

1. **Find the formatter** that prints this text and quote it — do not paraphrase.
2. **Run the state through the model** — color and status are computed, not chosen.
3. **Check the metrics** against the `Metrics` of the relevant view.
4. **Verify the state is reachable** — see "Impossible combinations" below.
5. **Icons are real SF Symbols**, rendered from the system. Not emoji, not Unicode substitutes, not
   SVGs from a library — see below.

## Metrics

### Menu bar — `StatusItemView.Metrics`

| Constant | Value |
|---|---|
| `barWidth` | 34 |
| `barHeight` | 5 |
| `barGap` (between bars **inside** one provider's block) | 5 |
| `blockGap` (between two providers' blocks) | **8** — wider than `barGap`, so the grouping reads as "bars together, blocks apart" |
| `barCorner` (track **and** strip) | 1.5 |
| `tickWidth` × `tickHeight` (time marker) | 5 × 9 |
| `centreTickWidth` × `centreTickHeight` (zero tick — Balance **and** Pressure) | **1.5** × **10** (under the track) |
| `zeroTickAlpha` (multiplier applied to `brightAlpha` for the zero tick) | **0.55** |
| `hPadding` | 2 |
| `labelGap` | 5 |
| `awaitingIconSize` + gap | 12 + 6 |
| `awaitingSlideTravel` | 22 (= `height`) |
| `pauseGlyphSize` + gap | 11 + 3 |
| `creditsIconSize` + gap | 12 + 4 |
| `statusDotDiameter` + gap | 6 + 4 |

The label font is `NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)`.

**The awaiting-hand slot is reserved from the options, not from the data**
([#283](https://github.com/artem-from-ua/cc-timer/issues/283),
[ADR-0073](../adr/0073-awaiting-icon-reserved-slot-and-slide.md)): `awaitingIconSize + gap` counts
toward the widget's width while **both** toggles are on — the master "Show sessions awaiting input"
(Extra features) **and** "Show awaiting-input icon in the menu bar" (Appearance) — **regardless of
whether anyone is waiting for input right now**. Both are required: turning the master off only
*disables* the second toggle, while its stored value stays `true`, so checking the Appearance option
alone would hold ≈18 pt for a feature that is switched off.
When you draw the menu bar in a mockup, do not remove that space along with the icon — otherwise the
neighboring elements land somewhere other than where the app will put them. The glyph itself travels
along Y by `awaitingSlideTravel` (clipped to the slot), so an intermediate frame is a **clipped** hand
near the lower edge, not a shrunken or semi-transparent one.

### Popup — `PopupBarView.Metrics`

| Constant | Value |
|---|---|
| `barHeight` | 6 |
| `corner` (track **and** strip) | 2.25 |
| `indicatorWidth` × `indicatorHeight` | 7 × 14 |
| `indicatorCorner` | 2 |
| marker outline | 1 pt, `monochromeGrey` blended 40% with the marker color |
| `tickLength` / `tickGap` / `tickWidth` | 5 / 2 / 2 |
| bar view height (`PopupBarView.viewHeight`) | **14** = `indicatorHeight`. There is **no** reserve for the tick ruler (#388): the ticks are drawn inside the marker's lower overhang. Before that the view was 21 pt, and those extra 7 pt of emptiness under every bar read as increased spacing *between limit blocks* |
| `boundaryCaptionSize` (month captions, credit bar) | 9 |
| `boundaryCaptionDrop` / `boundaryCaptionGap` | 5 / 3 |
| `minStripWidth` | `0.75 × barHeight − 1` = 3.5 (menu bar: 2.75) |

**The `scaleX` inset:** every fraction maps as `inset + f × (width − 2·inset)`, where
`inset = minStripWidth/2`. A fraction of 1.0 does **not** land on the right edge.

Text: `NSFont.systemFont(ofSize: dropdownTextSize)` — **neither half of any line is bold**.

## Icons — real SF Symbols only

**Emoji, Unicode substitutes (`⚡`, `✋`, `❚❚`) and hand-drawn glyphs in mockups are forbidden.** They
have a different width, a different optical weight and a different shape than what the app will draw
— which means the mockup shows an interface that does not exist, and every conclusion about layout
drawn from it is false.

Render them from the system, with the same parameters the code uses:

```swift
// mock-symbols.swift — run with `swift mock-symbols.swift`
import AppKit

func png(_ name: String, _ colour: NSColor,
         pt: CGFloat = 11, scale: CGFloat = 4) -> String? {
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .semibold)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return nil }          // ← nil = the symbol does NOT exist
    let w = base.size.width * scale, h = base.size.height * scale
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let r = NSRect(x: 0, y: 0, width: w, height: h)
    base.draw(in: r)
    colour.set()
    r.fill(using: .sourceAtop)                                     // tinting
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
        .map { "data:image/png;base64," + $0.base64EncodedString() }
}
```

The result then goes into the HTML as `<img src="data:image/png;base64,…">` sized in points
(`width: 12px; height: 15px` for 12×15 pt) — the artifact CSP blocks external hosts, so no other route
works anyway.

### What this buys you beyond accuracy

- **`nil` means the symbol does not exist.** That is how we found out `hare.slash` and
  `hare.fill.slash` are missing from SF Symbols — and exactly why Deadline mode uses `bolt`, which has
  a system-provided slashed counterpart.
- **Real widths.** `hare` is 20 pt, `bolt` is 12 pt. On a surface where the budget is measured in
  points, an 8 pt difference decides the choice.
- **Tinting as in the code.** `contentTintColor` in the app = `fill(using: .sourceAtop)` here, so the
  glyph color in the mockup is the one on screen.

### Parameters that must match the code

| Parameter | Where to get it |
|---|---|
| `pointSize` | `Metrics.awaitingIconSize` (12), `pauseGlyphSize` (11), `creditsIconSize` (12), `Metrics.textSize` in the popup |
| `weight` | `.semibold` — that is how every existing glyph on both surfaces is configured |
| color | a role from `ColorRole`, not an arbitrary shade |
| `scale` | 4× for retina; the HTML size stays in points |

## Bar anatomy

> **Three scales, not one** ([ADR-0076](../adr/0076-pressure-scale-for-marker-less-bar.md), #307;
> [ADR-0079](../adr/0079-centred-zero-gauge-scale.md), #326). `Progress` measures in fractions of the
> **window**, `Pressure` in fractions of the **time remaining** from the left edge, `Balance` in those
> same fractions of time remaining but **signed from the center**. That is why "a capsule at 40%"
> describes a different quantity in each of them, and they cannot be compared directly. In Kit the
> scale is named explicitly — `BarScale { window, remaining, centred }`; there are **three** style
> cases: `.progress`, `.pressure`, `.balance`.
>
> **Style is a property of the surface, not of the app**
> ([ADR-0080](../adr/0080-per-surface-bar-style.md)). The menu bar and the popup each store
> their own choice (`menuBarStyle` / `dropdownStyle`), so in a mockup you **cannot assume** both
> surfaces draw the same thing — all nine pairs are available. `(.pressure, .progress)` is simply
> one of those nine pairs, like any other.
>
> **Bars are drawn in THREE places, not on two surfaces** (#261,
> [ADR-0110](../adr/0110-legend-is-a-static-page-rendered-by-the-live-code.md)). The third is the
> **Settings › Appearance › Legend** page, and it lives by different rules than the two surfaces: its
> states are **fixed** (`LegendCatalog` in Kit) and depend on **neither** `menuBarStyle`/`dropdownStyle`
> nor `ColorAdvice` — it explains the vocabulary, not the configuration. The practical consequence for
> mockups and analyses: "it looks like this on both surfaces" no longer describes the app completely,
> and a change to a bar metric now changes **three** pictures. Two things about Legend exist nowhere
> else: **the ruler ticks are visible without ⌥** (the page exists in order to name them —
> [ADR-0098](../adr/0098-ruler-split-identify-always-explain-on-option.md) carved out exactly this
> case), and **all three styles are visible at once**, because each one's anatomy is explained
> alongside the others.
>
> Stored legacy raw values migrate through `BarStyle.legacyRawValues`, which covers all three current
> cases. `"mixed"` is **deliberately absent** from `BarStyle.legacyRawValues`: that table maps a raw
> value to **one** style, whereas `"mixed"` decomposes into **different** values on the two surfaces, so
> its migration is carried by a separate `BarStyle.legacySurfaceStyles(for:)` that returns a pair.
>
> **One bar sits outside this matrix — the credit bar**
> ([ADR-0092](../adr/0092-extra-usage-own-ruler.md)). It is always drawn on the **window** scale
> (Progress), whatever `dropdownStyle` says, because its window is a calendar month, not a limit
> window. The nine pairs still stand for the pacing bars; a mockup in which the credit bar is drawn
> with a Pressure or Balance strip is false **under any** settings. In the renderer you can see this
> from the fact that every branch reads `effectiveScale`, not `barStyle.scale`.

### What `.progress` draws (**Progress**)

1. A gray full-width track, radius 2.25 — **the same** as the strip above it
2. **A color capsule over the span `gapStart..gapEnd`** — not a fill from zero
3. A tick ruler under the bar: fractions of the **window**, `k / subdivisions` (only when
   `subdivisions >= 2`)
4. A time marker at `timeFraction`

`gapStart = min(usage, time)`, `gapEnd = max(usage, time)`.

**The capsule's left edge is data, not the strip's origin**
([#323](https://github.com/artem-from-ua/cc-timer/issues/323)). Everything to the left of the capsule
reads as "already spent", so the capsule must not start any further left than `gapStart` for **any**
`usage`/`time`. The minimum pill width (`minStripWidth`, 3.5 pt at `barHeight` 6) therefore stretches
**to the right**, and pinning the left edge to the edge of the track is not applied in Progress — both
live in `PopupBarView.stripRect(pinsStart:)`.

This is **not** a special case for zero spend: the floor kicks in on any gap narrower than 3.5 pt,
which is to say every time spending tracks the pace almost exactly. At `usage = 0` it is simply most
visible, because there the left edge also falls into the strip snap to `minX` and the pill would
otherwise creep out from under the time marker. The invariant is checked by
[`scripts/check-strip-geometry.py`](../../scripts/check-strip-geometry.py) on a 1001×1001 grid: zero
affected states, against 19,910 (drifting up to 4.75 pt) before the floor was introduced — the scale
is why this is an invariant and not a rounding detail.

### What `.pressure` draws (**Pressure**)

A strip from the **left edge** of length `BarLayout.pressureLength`, with no marker. This is
**exactly the right half of the Balance scale**
([ADR-0101](../adr/0101-pressure-is-the-gauge-ahead-half.md)):

```
r      = (u − t) / (1 − t)
length = max(0, balanceOffset) = clamp(r, 0, 1)
```

No coefficient at all: `pressureScaleCoefficient` (`k = 1.25`) has been removed from the code.

In the popup there are **no ticks under it whatsoever**
([ADR-0098](../adr/0098-ruler-split-identify-always-explain-on-option.md)) — the reference point is
carried by the zero tick itself, labeled `0` under ⌥.

In the menu bar there is a **zero tick** (`drawZeroTick`), the same one Balance has, only at a
different position ([ADR-0096](../adr/0096-zero-tick-on-pressure.md)). It sits **not** on the track's
left edge but at the **center of the zero pill**: a degenerate strip is floored to the minimum pill,
whose left tip `PopupBarView.pillRect` pins to `rect.minX`, so its center is half a pill further in.
The position is read from `pillRect` rather than computed separately, so it stays with the pill under
any change to the inset geometry (`minStripWidth` is the only knob). Metrics and tone are as in
Balance (1.5 × 10 pt, under the track, neutral `centreTick`, dimmed by `zeroTickAlpha` = 0.55).

This is **not** `gapEnd − gapStart` and **not** the absolute difference. The width itself encodes
severity, at fixed positions at any point in the window:

| color | width |
|---|---|
| blue | `0%` |
| green | `0%` |
| yellow | `0 – 16%` |
| orange | `16 – 100%` |
| red | `100%` |

Consequences you can see in a mockup:

- **zero means "exactly on pace"** (`u == t`), and it also goes to the **entire** calm side — green and
  blue alike. Together with the minimum-pill floor that is **54%** of the state space drawing the same
  dot **on a gray track**;
- **16% is the yellow/orange boundary**, and it is exactly `aheadThreshold`: the drawn length is the
  same number the model compares, with no reconversion;
- **there is no gap before red** — the scale runs continuously to 100% (the `(k − 1)` term left the top
  20% of the bar unreachable, so the bar jumped over it);
- at `u ≥ 1` (exhausted) the strip is **always full**, for any `t`;
- the strip **does not bounce back**: when spending stops, it falls to zero and stays there;
- **half of the yellow band drowns in the floor** (the `0 – 16%` range against a pill of `8.1%`). In
  real states there is headroom left — at `t = 30%, u = 38%` yellow draws 3.9 pt against a floor of
  2.75 pt.

A time marker is **impossible** here: on this track it would always sit at zero.

### What `.balance` draws (**Balance**)

Zero is **in the middle** of the bar ([ADR-0079](../adr/0079-centred-zero-gauge-scale.md), #326). The
same numerator and denominator as in Pressure; what changes is where you measure from:

```
r      = (u − t) / (1 − t)
offset = clamp(r, −1, +1)           // symmetric: both halves take the raw r (ADR-0101)
```

1. A gray full-width track — as everywhere else.
2. **A color capsule from the center** to `0.5 + offset/2`: **to the right** when `u > t`, **to the
   left** when `u < t`. This is not a fill from the edge and not `gapEnd − gapStart`.
3. **A centre tick** — in **every** state, idle included. In the menu bar that is `centreTickWidth` =
   **1.5 pt** (not 5!) × `centreTickHeight` = **10 pt** in the neutral `centreTick` (its own role;
   the default is the **tone of the calm fill**: `labelColor` via `bright()`, i.e. white on a dark bar
   and black on a light one), further dimmed by the `zeroTickAlpha` = **0.55** multiplier, drawn
   **under** the track: only the tips show above and below
   ([ADR-0089](../adr/0089-gauge-centre-tick-calm-tone.md),
   [ADR-0096](../adr/0096-zero-tick-on-pressure.md)).
   In the popup there is no separate tick — its role is played by the single ruler tick at **0.5**.
   **This is not a Balance-only element**: Pressure draws the same tick, at its own zero — see the
   Pressure section.
4. There is no time marker — same as Pressure.

Consequences you can see in a mockup:

- **The center means "exactly on pace"** (`u == t`) — and it is the same zero Pressure has: `t` **is**
  the zero of both scales ([ADR-0101](../adr/0101-pressure-is-the-gauge-ahead-half.md)). A degenerate
  strip is floored to a **centered** pill;
- **the side reads independently of the length**: the same length means opposite states depending on
  the direction. Under muting ("Colors tell me" in a muting mode, or Pressure — where it is
  unconditional) the calm-range color is the same on both sides — all that is left is the direction
  from the tick;
- the left half is **full** when `u ≤ 2t − 1` (headroom greater than the time remaining). Impossible
  before `t = 50%`, routine at the end of a window;
- at `u ≥ 1` the **right half is full**, for any `t`;
- the ahead side is **identical to Pressure by construction**: `pressureLength ≡ max(0,
  balanceOffset)`, i.e. one and the same quantity, not two that agree up to a correction (the
  difference used to be `0.20`). A mockup in which switching Pressure ↔ Balance shifted the right half
  is false;
- **the strip always overlaps zero by half a pill width** — toward the side it is heading
  (`stripRect(anchoredAt:)`, both surfaces). Otherwise it merely *starts* at `scaleX(0.5)`, and its
  rounded cap turns away from that point, while the tick at that same x is **centered** — so the color
  visibly backs away from the tick, mirrored on either side. With the overlap the strip reads as
  something that **grows out of** zero rather than starting next to it. The degenerate span is covered
  by this rule on its own: it becomes an exactly centered pill;
- **there is a dead zone around zero** — a consequence of `minStripWidth`, not a separate rule. On the
  menu bar half the scale is 15.62 pt while the minimum pill is 2.75 pt, so everything with
  `|offset| ≲ 0.176` draws as the same centered pill (measured on the `balance-sweep` stub: at
  `offset = 0.0914` the "clean" strip is 1.38 pt, and
  `stripRect` expands it symmetrically from the center). A mockup in which a small lead is drawn as a
  noticeably offset short strip is false: it will be centered. In the popup the bar is much wider, so
  the zone there is correspondingly narrower.

### What the credit bar draws ("Extra usage")

**Progress anatomy always**, plus its own ruler instead of ticks
([ADR-0092](../adr/0092-extra-usage-own-ruler.md)):

1. A gray track, a color capsule over `gapStart..gapEnd`, a time marker at `timeFraction` — items 1, 2
   and 4 from `.progress`, unchanged.
2. **No ticks** — none at all. Not window fractions, not 20%, not the center: a month has 28–31 days,
   and no even division lands on a real boundary.
3. **Two captions at the edges of the track** — the first and last day of the calendar month (`Jan 1`
   on the left, `Jan 31` on the right), 9 pt, in the `dimmedLabel` tone — **the same ink as the
   amounts line above the bar**. Pinned to the edges of the track (not to the edges of tick captions,
   which do not exist) and dropped `boundaryCaptionDrop` below the tick line.

Consequences you can see in a mockup:

- the bar **does not react** to the dropdown's Style: switching Pressure ↔ Balance ↔ Progress moves the
  token bars and leaves this one where it is;
- the **window** is taken in UTC (that is where the monthly limit resets — and it is what defines the
  bar's geometry), while the boundaries themselves are **rendered in the reader's zone**, like the
  `resetLine` on the same row: an instant is a point common to everyone. So east of UTC August reads as
  `Aug 1 … Sep 1`, west of it as `Jul 31 … Aug 31`;
- with an **unlimited** cap there is no bar and no captions (`bar == nil` ⟹ `monthBounds == nil`);
- the captions are part of the ⌥ half of the ruler: without ⌥ they are absent, just like the ticks.

### A zero-length strip is a pill, not emptiness

In a Pressure bar the strip is the **only** mark on the bar, so even at a length of exactly 0 it is
drawn as a pill of minimum width (`minStripWidth`, 2.75 pt on the menu bar) — `PopupBarView.pillRect`.
An empty track would read as "no data", not as "zero". **Both** surfaces behave this way: the menu bar
through `fillZone(floorEmptyToPill:)`, the popup through a fallback to `pillRect` when the span is
degenerate ([ADR-0076](../adr/0076-pressure-scale-for-marker-less-bar.md); before it, the popup left an
empty track).

The state `usage == time == 0` is not a rounding artifact but a regular frame: after every reset of
the 5-hour window `PollingEngine.applyIdleGrace`/`suppress`
([ADR-0041](../adr/0041-idle-grace-on-reset-boundary.md),
[ADR-0045](../adr/0045-honest-reset-boundary-grace.md)) hold a "ready" frame with `0%` and
`resets_at = now + 5h` until the first spend arrives. In Progress this floor is **absent** on the
**pacing** bar: there an empty gap means "exactly on pace", and the marker already shows the position.
On the **idle** bar the floor applies in all three styles — idle draws a pill under Progress too
([ADR-0078](../adr/0078-idle-drawn-as-zero-in-both-styles.md)), the marker just covers it.

### What the idle bar draws

**The same in all three styles** ([ADR-0078](../adr/0078-idle-drawn-as-zero-in-both-styles.md)) — idle
is zero on both scales, so all three styles draw zero:

- **The shared base** — a gray track + a **minimum pill at zero**, **green** (`ready to start`) or gray
  (`blocked`). The same shape any zero-length strip has. No zones. There is no blue idle on any
  surface, and the weekly state does not affect this pill
  ([ADR-0105](../adr/0105-color-advice-governs-pacing-bars-only.md)).
- **Progress** adds a **time marker at zero** (the window has just rolled over) — it covers the pill, so
  Progress idle reads as "track + marker on the left".
- **Pressure** leaves the pill by itself.

**There is no full-width solid fill in any style** ([ADR-0078](../adr/0078-idle-drawn-as-zero-in-both-styles.md)) — a full-width fill would read as Pressure at full pressure, the loudest mark for the
calmest state.

The tick ruler is present in both (Pressure has no ticks — only the zero tick, ADR-0098). On the menu
bar, under muting, idle takes the shared `calmWhite` rather than a dimmer tone of its own — and at
exactly the same alpha (`bright()`), so it does not glow brighter than the calm bars beside it. **When
exactly it gets muted** is a simple rule: `barStyle == .pressure ||
colorsTell.mutesCalm`. That is: under **Pressure always**, and under Progress/Balance in either of the
two muting "Colors tell me" modes (`Slow down`, `Slow down or speed up`). There are no exceptions.

**In the popup under Pressure a calm zero-length pill glows harder.** A strip collapsed to zero has no
width to carry the color, so instead of the ambient halo (radius 21 pt, alpha 0.35) it gets a **triple**
pass — radii 40 / 22 / 10 pt, alpha 1.0 each, from wide to narrow, so the light accumulates at the
center and falls off outward
([PopupViewController.swift:561](../../Sources/TokenPace/PopupViewController.swift#L561)). Calm states
only: in a warning the strip has a length of its own and there is nothing to boost.

### The time marker gives the style away — don't forget it

**A bar with no marker is Pressure (`.pressure`) or Balance (`.balance`), but definitely not Progress
(`.progress`).** The most common mistake in mockups: labeling a render "Progress" while drawing only a
color strip. The marker is not decorative detail — it is what tells one style from another.

And it is **not the only** difference: the scale changes along with the marker. A bar without a marker
is measured against the time remaining, so a mockup in which "Pressure" is drawn with a length of
`gapEnd − gapStart` is false even without any marker at all
([ADR-0076](../adr/0076-pressure-scale-for-marker-less-bar.md)).

The rule is **one-way**, and that is exactly how it is named in Kit: a marker has a position **only** on
the window scale, i.e. `showsTimeMarker == (scale == .window)`. The converse no longer holds — there are
three scales, and two of them have no marker. So a mockup without a marker still has to be taken all
the way: `Pressure` measures from the **left edge**, `Balance` **signed from the center**, and the two
are easy to confuse (see `BarScale`, [ADR-0079](../adr/0079-centred-zero-gauge-scale.md)).

`BarStyle` has **one** `scale` and one `showsTimeMarker`
([ADR-0080](../adr/0080-per-surface-bar-style.md)): the type describes one surface's presentation,
and which surface that is, is known by whoever reads it. There is no per-surface flag pair anywhere
in the model.

Before publishing a mockup with bars:

- a marker at `timeFraction` is present on **every** `.progress` bar — in the menu bar too (5 × 9 pt,
  not just the popup's 7 × 14), i.e. `BarStyle.showsTimeMarker == (self == .progress)`. The surface has
  no say in it: the marker is determined by **that surface's style**, not by whether it is the menu bar
  or the popup. So "marker in the popup only" is not a property of the type but the specific pair
  `(menuBarStyle: .pressure, dropdownStyle: .progress)`, which the user can set (and which is exactly
  what migrating the old `.mixed` produces);
- **the two surfaces may be drawn in different styles** — and that is not a mockup error but an
  available state (nine pairs, #329). The error is silently assuming they are the same and labeling the
  mockup with a single word "Style"; label each surface separately;
- in a bar **without** a marker the length is `pressureLength`, and there are no ticks in the popup at
  all (only the zero tick, labeled under ⌥). Four ticks under a marker-less 5h bar (window fractions)
  is the same mistake as a marker under Pressure;
- the marker stands at **its own** fraction, not at the edge of the strip: at `usage > time` it is
  **left** of the gap, at `usage < time` **right** of it. Both bars with the marker on the left means
  the geometry was copied, not computed;
- every x goes through the `scaleX` inset, the marker included.

A quick check: if the picture has two bars and both markers are on the same side, it is almost
certainly wrong.

### What nobody draws

**A fill from zero to `usageFraction`.** The level is not drawn in any style — that is a deliberate
decision ([ADR-0062](../adr/0062-configurable-bar-presentation.md)). If the picture has a strip starting
at the left edge and ending at "how much has been spent", the picture is wrong.

Similar to a fill but not one: **any** `.pressure` bar, where the strip is also left-anchored even
though its length is `pressureLength` (the gap against the time remaining), not the level. A
left-anchored strip does **not** by itself mean a level fill: only the start matches, not the end.

**The credit bar never appears under `.pressure`** — it is always Progress
([ADR-0092](../adr/0092-extra-usage-own-ruler.md)), so a left-anchored credit strip does not occur at
all.

## Color is computed, not chosen

```swift
// PacingModel.severity
if pacing == .onPaceOrBehind {                    // usage <= time
    if !blueAllowed { return .calm }              // blue is not offered here — three reasons: ADR-0115
    if elapsed <= 1200 { return .calm }           // 20-min start override
    return (time - usage) > behindThreshold ? .farBehind : .calm
}
if usageFraction >= 1 { return .exhausted }       // RED
if remainingSeconds <= 1200 { return .ahead }     // 20-min end override
return (usage - time) < 0.16 * (1 - time) ? .calm : .ahead
```

**The order of the branches is critical.** Both 20-minute overrides sit **after** the exit from the calm
branch — so at `usage <= time` they are unreachable. The state "97% spent, 97% of the time, 9 minutes to
reset" stays **green**.

A quick check before drawing:

| Condition | Color |
|---|---|
| `usage >= 1` | red |
| `usage > time`, `usage − time >= 0.16 × (1 − time)` | orange |
| `usage > time`, below the threshold | yellow |
| `usage <= time`, behind by ≤ the threshold | green |
| `usage <= time`, behind by > the threshold | blue (base 5h/7d only) |

## Claiming something about behavior — quote the line of code

The rule is broader than texts and colors: **any** claim about what the app does is backed by a function
name with a line number, not by a retelling. Not "it looks like it does X", but the formatter or
property from the file — everything else is a guess that looks like a fact.

Two ways to get it wrong, both of which have happened:

- **The order of the branches decides as much as their contents.** In `PacingModel.severity` above, both
  20-minute overrides sit **after** the exit from the calm branch, so at `usage <= time` they are
  unreachable. Read them apart from the order and you get a state that does not exist.
- **A property's name is not proof.** It can be a conjunction with live data rather than a flag: that is
  exactly how `showAwaitingInMenuBar` looked like an "icon enabled" toggle while in fact it also
  depended on whether anyone was waiting for input **that very second** — which made the widget's width
  jump dozens of times a day. That is why the slot is now reserved from the option and the property is
  called `reservesAwaitingSlot` ([ADR-0073](../adr/0073-awaiting-icon-reserved-slot-and-slide.md),
  [#283](https://github.com/artem-from-ua/tokenpace/issues/283)). The old name **does not exist** in the
  code — if it turned up in somebody's analysis, that analysis was written from memory.

## Texts — quote the formatter

| What | Where | Rule |
|---|---|---|
| Limit status | `PopupViewController.statusText` | — |
| Credits status | `creditsStatusText:1914` | `usage >= 1` → always `"limit reached"`, never "ahead" |
| Credit amounts | `creditsAmountText:1922` | `"€10.8 of €15"` — **both amounts, no percentage**. The right half is `CompactMoney.capText`: a whole cap loses the fraction (`€15`, not `€15.0`), because it is a constant from billing. The left half keeps the ladder (`€12.0` at a spend of exactly 12), with two exceptions: **zero** — untouched spend is `€0`; **a sub-cent amount** — a non-zero spend smaller than the smallest displayable unit is `<€0.01` (not `€0.00`, which would lie about there being no spend, and not rounding up, which would overstate the amount). Under ⌥ both are exact: `"€10.77 of €15.00"` |
| No cap | `creditsSpentOnlyText` | `"€10.8 spent"` — no bar and no verdict; under ⌥ `"€10.77 spent"` |
| Stand-by line, popup (7d, ⌥) | `PopupViewController.standByText` | `"stand by 2d for green"` — how long not to spend for the bar to turn green. The duration is `ResetClock.rounded(duration:)`, **the same** band format as the reset (`45m` · `3h` · `2d`). Values and thresholds come from `PacingModel.displayableStandBySecondsForGreen` |
| Reset line, popup | `ResetClock.resetLine` | `"15d"` · `"5d on Friday"` · `"20h at 03:00"`. Under **⌥** — with the prefix `"resets in"` (`verbose: true`): `"resets in 20h at 03:00"` |
| Percentage spent, popup | `PopupViewController.usedText` | `"20%"`; under **⌥** — `"20% used"`. Both halves of the detail line take on words together with `resetText` |
| Reset label, menu bar | `ResetClock.timeToReset` | **one unit at any distance** — `"45m"` · `"5h"` · `"4d"` · `"<1m"`. There is no clock time (`20:40`) and no combined `1h30m` ([ADR-0074](../adr/0074-one-reset-format-on-both-surfaces.md)) |

## The ink hierarchy in the popup

| Line | Content | Role |
|---|---|---|
| Top | the limit's name **and the status word** | `.label` — full |
| Bottom | the percentage **and** the reset line | `.dimmedLabel` |
| Under the bar — **the credit row only** | the month boundary captions (`Jan 1` / `Jan 31`), 9 pt | `.dimmedLabel` — the same ink as the amounts line |

`dimmedLabel` = `tertiaryLabelColor.blended(0.5, of: .secondaryLabelColor)` — weaker than secondary.

The third line takes **the same** tone as the second one deliberately
([ADR-0092](../adr/0092-extra-usage-own-ruler.md)): the captions belong to the row's secondary tier, not
to some third one. An intermediate shade between `dimmedLabel` and the track's tone would make them a
separate level of hierarchy, which this row does not have.

The split runs along **lines**, not along a "name ↔ value" axis: the verdict stands in full ink together
with the name, and that is deliberate — it is the most actionable element of the row.

## Provider plates and the header dot (#454, ADR-0121; #503, ADR-0125)

The popup holds **one plate per provider** — separate glass, separate stack, separate rows. Several
providers on one plate read as one subject with subheadings, and the component names cannot correct
that (`Actions`, `Issues`, `CLI` and `API` never say whose they are). A provider that is off
collapses its plate to zero height, so the popup ends at the last enabled one.

**The order is `ProviderID.displayOrder`: Claude, Codex, GitHub.** Claude is pinned first because it
owns the usage bars — its plate is the main stack, and every other provider is a satellite card below
it. The rest is alphabetical by `displayName`. This is deliberately **not** the enum's case order
(`claude, github, codex`), which is archive identity: the raw values are journal-stable, so a case
appended later must not reorder the screen. A popup reading Claude → GitHub → Codex is a bug.

**The Codex plate carries both halves** (#504, [ADR-0127](../adr/0127-codex-quota-from-the-app-server.md)):
the quota's bars *and* the status rows. It is the only satellite plate that does — GitHub is
status-only — and it stands on **either** half, so a user with every Codex service off but the quota
on still gets a plate.

Its anatomy, top to bottom: the `Codex` wordmark (`#5871C0`) with its status dot, then one bar per
**reported** quota window, then the status rows. The quota bars come first, matching Claude's plate,
where the limits sit above the service lines.

| | At rest | Holding ⌥ |
|---|---|---|
| Header | `Codex` — the bare wordmark, plus its dot when the provider is calm | `Codex ･ Plus` — the plan word, and the poll age after it |
| Quota rows | title, status word, `n% used`, the reset line, the bar | the verbose forms, plus a **stand-by** line on a 7-day window when there is advice to give |
| Quota row — window not started | title, `ready to start`, a green knobless bar, and **no second line** | unchanged: there is no detail to expand |
| Quota row — not started, account flagged reached | title, `waiting for limit reset`, a **grey** knobless bar, and no second line | unchanged: there is no detail to expand |
| Status rows | only what is broken or just recovered | replaced by this provider's incidents |

**A Codex window that has not started renders like Claude's idle 5-hour row, and for the same
reason.** `account/rateLimits/read` answers a spotless window with a `resetsAt` it recomputes as
`now` plus the window's own length on every read — measured on a live Plus account, three reads
across thirteen seconds returned `usedPercent 0` with the reset at `now + 604 800 s` each time, and
the value itself advanced those same thirteen seconds. Drawn as an instant that is a 7-day countdown that
slides forward and never ticks down. It is detected as `resetsAt − now ≈ windowDurationSeconds`
within **±120 s** *and* nothing spent, and the row then carries the title, `ready to start`, a green
knobless bar and no detail line at all — no `0%`, no reset, and specifically **not** `resetting…`,
which would claim a reset is happening this second.

The raw value stays observable: Troubleshoot's `Reported resets` line prints the epoch seconds the
server sent, so the backend's behaviour can still be read off a surface even though no countdown
draws it.

**But `ready to start` is gated on the account, not just on the window.** `rateLimits` carries two
account-level flags — `spendControlReached` and `rateLimitReachedType` — and upstream reports
accounts showing 100 % left while actually rate-limited
([openai/codex#34360](https://github.com/openai/codex/issues/34360),
[#36528](https://github.com/openai/codex/issues/36528)). So a spotless window is a claim about the
window, not a promise the next request succeeds. With either flag set the same row keeps its shape
and swaps its word: **grey**, `waiting for limit reset` — Claude's wording for an idle window with
no path to start, deliberately neutral about which limit blocks. The widget answers *can I work*,
and saying yes over a server that has said no is the worst answer it has
([#518](https://github.com/artem-from-ua/tokenpace/issues/518)).

**An absent flag is "unavailable", never "false".** Both arrive `null` on the live Plus account, so
only an explicit `spendControlReached: true` counts, and **any** non-empty `rateLimitReachedType`
does — the vocabulary is the server's and will grow, so a word we have not met must not read as
silence. The flags gate the not-started row **only**: an anchored window keeps its percentage,
pacing and countdown, all of which stay true while the account is flagged.

**The plan word is ⌥-gated, exactly as Claude's is.** It names the subscription once and never
changes between polls, so it is an on-demand detail rather than something to watch. A resting
screenshot showing a bare `Codex` is correct; a plan word visible at rest is the bug.

**The ⌥ stand-by line is gated by the window's *duration*, not by a row index.** Claude's gate is
`index == 1` because its layout fixes that order; Codex's single row sits at index 0 and its window is
a week — exactly the case the line exists for. Pacing on a five-hour window is not worth waiting out
because it resets twice a working day; what makes that true is the length, not the position.

**A section header's dot is drawn only while that provider is `operational`.** This is the one dot in
the app that appears on a calm state — and, symmetrically, the one that *disappears* when something is
wrong. Both halves matter when you draw a state:

| Provider state | Header dot | Rows below |
|---|---|---|
| `operational` (calm) | **green** `ColorRole.green`, a real `GlowDotView` | none — a healthy component draws no row |
| `degraded` / `partialOutage` / `majorOutage` / `underMaintenance` | **none** — title flush left | one row per non-operational component, each with its own dot and its own name |
| `unknown` (the poll failed) | **none** — `unknown` is not an exception | grey rows, one per component |
| no poll has landed yet | **none** — "not yet" is not "we could not tell" | none |

The dot answers the state where the rows are hidden. The moment the rows appear they carry their own
dots and **name the service**, so a worst-of-N above them would restate less precisely what they
already say ([ADR-0121](../adr/0121-github-as-a-status-only-provider.md) §D2).

**No dot means no reserved column** — the provider's name sits flush left, not behind a hidden indent.
The *service rows* do reserve that column (their names line up under one another whatever each row's
dot is doing), but a header is not one of a set; it is the thing the set hangs from. When the dot is
present it uses the rows' own gap and nudge, so every dot in the popup lands on one vertical line.

**Under ⌥** each plate switches to **its own** incidents ([ADR-0071](../adr/0071-incident-subscriptions.md)
§2 — the dimension, not the level of detail), and every satellite header grows the same `· updated …`
tail Claude's carries, reading **that provider's own** poll age — they poll on independent cadences,
so one age standing for all of them would be a quiet lie. The subscribe control sits on whichever plate has
an incident — both when both do — and either one toggles the same app-wide subscription.

### Impossible combinations these introduce

| Combination | Why it is impossible |
|---|---|
| A **header dot and service rows on the same plate** | `headerDot(for:)` returns a dot for `.operational` and nothing else, and a component that is `operational` draws no row. The two are mutually exclusive by construction, in both directions ([ADR-0121](../adr/0121-github-as-a-status-only-provider.md) §D2) |
| A **yellow, orange, red, blue or grey header dot** | Same gate: every non-`operational` aggregate yields `nil`. Those five tones belong to the *rows*, and to the menu-bar dot — never to a provider header |
| A **grey header dot before the first poll** | A `nil` aggregate yields no dot at all. Grey would claim we looked and could not tell, which is a different statement from "we have not looked" — the same honesty `ServiceStatus.unknown` exists to protect |
| A **green dot in the menu bar** | Unchanged by #454: silence there is still a complete answer to "can I work" ([ADR-0013](../adr/0013-claude-status-line.md) §8). Green enters the vocabulary in **one** position only — a popup provider header on a calm provider |
| **One provider's incident row under another's header** | Each plate renders only its own list. An incident row deliberately does not name the services it affects ([ADR-0071](../adr/0071-incident-subscriptions.md) §3), so the header above it is the only attribution there is — which is the whole reason the plates are separate |
| **`No ongoing incidents` on a calm satellite plate under ⌥** | Claude's plate says that because its section is on screen *because* something is wrong, so a blank dimension there would read as a glitch. A satellite plate is on screen whenever its provider is monitored, so a calm one under ⌥ shows **nothing** — the header's green dot has already answered it |
| A **subscribe row on a plate with no incident of its own** | The control sits beside its cause. On a healthy provider's plate it would read as an offer to follow that provider's silence |
| A **GitHub plate carrying bars, a percentage, or a `Token limits usage` section** | GitHub is status-only and publishes no subscription limit the bars model. There is no usage half in the app, in the config, or on the Settings page |
| A **5-hour row on the Codex plate** | The server reports one window — a week — and `secondary` is `null`. A 5-hour row would be a bar for a limit Codex does not report, under an invented reset ([ADR-0127](../adr/0127-codex-quota-from-the-app-server.md) §D5). The plate shows one row per **reported** window, so two rows are possible the day the server sends a `secondary`, but a *5-hour* one never appears alongside today's week |
| A **Codex row reading `ready to start` while `spendControlReached` or `rateLimitReachedType` is set** | The encouraging word is gated on the account's reached flags, not on the window alone. A flagged account draws the same idle shape in **grey**, reading `waiting for limit reset`. The reverse pair is possible and ordinary: a flag absent or `null` leaves the row green and encouraging, because `null` means unavailable rather than blocked ([#518](https://github.com/artem-from-ua/tokenpace/issues/518)) |
| A **Codex row reading `0%` beside a reset a full week out** | That pair is the window-not-started state, and it draws no second line at all — the title, `ready to start` and a knobless bar. A `0%` with a `7d` countdown next to it is the sliding value the state exists to suppress |
| A **`resetting…` on a Codex row that has not started** | `resetting…` is what a `nil` reset line renders, and it claims a reset is in progress this second. A window that has not started drops the whole detail line instead, so the fallback is never reached |
| A **red blocking-reset badge on a Codex row** | `blockingReset` answers "which reset unblocks **Claude** work" and is picked from Claude's rows alone. Codex resets render as plain text. This is also why Codex rows live in their own array — appending them to `rows` would renumber the indices that badge is keyed to (ADR-0127 §D7) |
| A **plan word beside the `Codex` wordmark at rest** | The plan rides the ⌥ layer, exactly as Claude's does: at rest the header is the bare wordmark (plus its status dot), and ⌥ restores `Codex ･ Plus`. A screenshot without the plan is the resting state, not a missing label |
| A **Codex plate with bars while `usageEnabled` is off** | The collector is torn down with the switch, not merely ignored, so no bars survive turning it off |
| A **`Login` row on the Codex plate**, in any state | The feed lists `Login` **twice**, under two different ids, so an exact-name match resolves arbitrarily. TokenPace watches neither copy, so no configuration produces this row ([ADR-0125](../adr/0125-codex-as-a-status-provider.md) §D4) |
| A **linked stage word on a Codex incident row** | The proxy incident feed carries no `shortlink`. Claude's and GitHub's stage words are links; Codex's is plain text, because a link there would be an invented URL |
| A **Codex plate with incident rows but no service rows, under ⌥, while everything is `operational`** | Same rule as every plate: a calm provider under ⌥ shows nothing. And in the reverse case — the incident endpoint being unavailable — the rows stay and the incidents are the half that vanishes, never the other way round |
| A **Codex wordmark that differs between light and dark** | Unlike GitHub, Codex has **one** brand role: `ColorRole.codexBrand` (`#5871C0`) is mid-luminance and reads on both materials, so no per-appearance ink companion exists |
| A **GitHub row badge with a branch, an Octocat, or any glyph other than `cloud.fill`** | Every provider badge wears the same glyph: shape is the category, colour is the identity ([ADR-0094](../adr/0094-provider-row-brand-badge.md) §4, [ADR-0121](../adr/0121-github-as-a-status-only-provider.md) §D6) |
| **Pure black GitHub ink in the popup** | The badge is `ColorRole.githubBrand` (`#000000`); the popup header is `ColorRole.githubBrandInk`, which resolves per appearance (`#1F2328` / `#E6EDF3`) because black on the dropdown's dark material is unreadable |
| A **`Monitoring is off` dead end over any live provider plate** | `isMonitoringAnything` spans every provider; a configuration with only GitHub or only Codex enabled is a fully monitored state |

## Impossible combinations

Check before you draw a state.

| Combination | Why it is impossible |
|---|---|
| **Blue 5h while 7d ∈ {yellow, orange, red}** | The weekly-capacity gate ([ADR-0081](../adr/0081-weekly-capacity-gate-for-blue.md)): `blueAllowed == false`, so the "behind" side stays green no matter how much headroom there is. Applies to both the pacing bar and the idle pill |
| **Blue on a per-model / scoped row** — whatever the weekly state | They are slices of the very 7-day limit blue talks about, so the advice would be addressed to itself: `blueAllowed == false` **unconditionally** ([ADR-0115](../adr/0115-no-blue-on-per-model-windows.md)). The rule lives in the model, not just in the renderer, so the journal can never record a blue that was never on screen |
| A `stand by …` line on the **5-hour** row | The gate is `index == PopupViewController.sevenDayRowIndex`: the signal exists **only** on 7d. A five-hour window resets at least twice a day and fixes itself, so the cost of a pause there changes no decision |
| A `stand by …` line on a **non-orange** 7d | `standBySecondsForGreen` returns `nil` for every severity except `.ahead`. On green or blue there is nothing to wait for, on yellow the lead is within norms, and red (`usage >= 1`) is cured **only** by the reset: spending has hit the ceiling, and time will not catch up with it |
| A `stand by …` line **without** ⌥ held | The line is built only under `optionHeld`. At rest the 7d section is two lines + a bar, like any other |
| `Troubleshoot…` or `Development tools…` **without** ⌥ held | Those two are ⌥-gated in every state ([ADR-0117](../adr/0117-dropdown-actions-behind-option.md) D1, kept by [ADR-0127](../adr/0126-settings-and-quit-stay-visible-by-default.md) D2) — specialist entrances, not part of the everyday menu. A mockup showing either of them is drawing the ⌥-**held** state and must show the rest of what ⌥ reveals too, on the widgets as well as in the column |
| `Settings…` or `Quit TokenPace` shown as **⌥-only** | They follow the "Always show action items" switch, **default-on** ([ADR-0127](../adr/0126-settings-and-quit-stay-visible-by-default.md)), so the ordinary menu has both — with Quit's separator, and Quit reading plainly, since its build tag stays ⌥-revealed. Drawing them absent is drawing the non-default state and should say so |
| The `hold ⌥ Option for more` caption **while ⌥ is held** | It stands in for the items ⌥ reveals, so the two are mutually exclusive by construction (`optionHintEnabled && !optionHeld`). It is also absent whenever the Appearance › Dropdown switch is off, and **never** appears in the Settings live preview, which has no menu items to offer |
| The update line hidden under ⌥, or the caption drawn as a menu item | The update row is a notice and stays visible in both ⌥ states ([ADR-0117](../adr/0117-dropdown-actions-behind-option.md)); the caption is the reverse — not an `NSMenuItem` at all but an inert label inside the popup's view, so it never highlights on hover and cannot be drawn with a menu row's selection |
| A **separator above the update line with no items above it** | That separator divides the update line from the action items above it, so it needs something above to divide from — otherwise it is a rule under nothing, sitting between the card and the notice. It is drawn whenever those items are on screen, by ⌥ or by the default-on switch ([ADR-0117](../adr/0117-dropdown-actions-behind-option.md), [ADR-0127](../adr/0126-settings-and-quit-stay-visible-by-default.md)); with them gone the line stays and its divider does not — the two answer different questions |
| The card's **even bottom margin while anything sits under it** | The full margin belongs to a plate with no neighbour at all, and there are three ways to have one: the ⌥ column, the update line, and the pinned `Settings…`/`Quit` ([ADR-0127](../adr/0126-settings-and-quit-stay-visible-by-default.md)). Any of them makes the trimmed inset apply — so on default settings the even margin is not reachable in the menu at all, only with the switch off, the caption off, ⌥ up and no update line |
| `stand by` **shorter than 20 min** | Cut off by `PacingModel.standByFloorSeconds`. The state is almost unreachable: it exists only in the last ~2 hours of a window (remaining < 125 min) **and** within a spending band hundredths of a pp wide (at 120 min remaining — `u ∈ [99.0000%, 99.0079%]`). The minimum orange wait equals `0.16·(1−t)·D` itself, and mid-week that is already ≈13 hours. The threshold is a guard against "stand by 3m", not a working filter |
| `stand by` that runs **right up to the reset** | Cut off even earlier — by the `remainingSeconds − standBy > pacingOrangeOverrideSeconds` check inside the calculation: a green that would arrive in the last 20 minutes of a window would be orange there anyway. There is **no separate "10-minute" rule and no need for one** — it is nested inside this one and would not have rejected a single case |
| **A blue idle pill** — whatever the weekly state | There is no blue idle anywhere: the pill is green (or white under muting), and gray is left only for `isBlocked`. The weekly gate does not enter into it — the fields `LimitRow.weeklyHeadroom` / `BarView.weeklyHeadroom` do not exist |
| The pause glyph **and** the currency symbol together | Guaranteed by [ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md): the credits marker is zeroed out while `blockedPause` |
| An exhausted limit with **neither** of them | The flip side of the same thing: at `mainWindowExhausted` the states are exhaustive — either `creditsCanCover` (the currency symbol) or `isBlocked` (the pause glyph). There is no empty variant |
| Bars under the pause glyph or under the currency symbol | Both "not on a subscription" answers produce `MenuBarMode.iconOnlyReset` — a case with no field for bars ([ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md)), so there is nothing to draw them from. **With no exceptions from [ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md):** the stale phase that used to hold diagnostic bars next to ⚠️ has been cancelled |
| **A countdown next to bars** | `MenuBarMode.expanded(blocks:)` has no field for the number ([ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md), [ADR-0128](../adr/0128-menu-bar-repeats-a-block-per-provider.md)) — the pair is unrepresentable, not merely unreachable. The number lives only in `iconOnlyReset` (glyph + countdown, no bars) |
| **A brand-tinted bar** | A bar's colour **is** the pacing verdict, and there is no second channel on a 5 pt shape ([ADR-0128](../adr/0128-menu-bar-repeats-a-block-per-provider.md)). Providers are separated by a gap and identified by **position** — never by hue, and never by a drawn rule |
| **A block with no bars, or a widget with no blocks** | Both are held by the type: a provider whose only bar is elided is dropped whole, and unticking every provider under "Providers to display" still leaves one block drawn |
| **The status dot anywhere but last** | It is the trailing element, after every block — and it is still absent while everything is green ([ADR-0013](../adr/0013-claude-status-line.md) §8) |
| **Two raised hands** | The awaiting-input hand is drawn once, leftmost, outside every block — it is a fact about Claude Code sessions, not about a quota |
| The pause glyph or the currency symbol next to ⚠️ | `exhaustedUnknownReset` draws ⚠️ **alone** ([ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md)): a glyph would assert a state right next to a sign that disclaims the data. The one place where `isBlocked` is true and there is no pause |
| A red bar at 100% | An exhausted 5h/7d window routes to a bar-less state **before** the bars are built; with a broken `resets_at` it routes to `exhaustedUnknownReset`, also bar-less |
| 100% of credits + "well ahead of pace" | `creditsStatusText` at `usage >= 1` returns `"limit reached"` |
| 100% of credits without the red reset badge | That is the blocked state — the badge is there |
| Idle 5-hour + a second line | `if !row.sessionIdle` — there is no detail line |
| A wall clock (`20:40`) in the **menu bar** | There is one format at any distance ([ADR-0074](../adr/0074-one-reset-format-on-both-surfaces.md)). A clock appears **only** in the popup, as a qualifier on `resetLine` (`5h at 20:40`) |
| A combined label (`1h30m`, `4h41m`) anywhere | `relativeRounded` returns **one** unit; `relativeString` was removed along with the 90-minute threshold |
| A `.pressure` idle bar + a time marker | There is no marker in any Pressure bar; under `.progress` idle **does** have a marker, at zero ([ADR-0078](../adr/0078-idle-drawn-as-zero-in-both-styles.md)) |
| ⚠️ with a **missing** weekly reset | ⚠️ means exactly "the data contradicts itself" ([ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md)). An empty `seven_day.resets_at` at `utilization == 0` is not a contradiction but the truth: there is no weekly window yet until the first token is spent. That state draws the **"no data" symbol** (`MenuBarMode.weeklyResetUnknown`, [ADR-0107](../adr/0107-weekly-reset-reconstructed-from-the-last-known-one.md)) |
| Any limit row at `weeklyResetUnknown` | `PopupLayout.make` returns `rows: []` — **all** of them are hidden, per-model and credits included. Drawing them partially is not allowed: Fable/Opus/Sonnet inherit the weekly date, and `elapsedFraction` returns `1.0` when it is unparsable, so every row would draw its marker near the **right** edge ([ADR-0107](../adr/0107-weekly-reset-reconstructed-from-the-last-known-one.md)) |
| A red banner at `weeklyResetUnknown` | This is not a polling failure: the request returned `200` and a well-formed body. The banner is drawn in the secondary color with the "no data" symbol rather than through `FailureReason` — `.serverProblem` would say "Usage API unavailable" and send the user off to check the network instead of getting to work |
| `weeklyResetUnknown` at a **non-zero** 7d `utilization` | Both surfaces require `resetsAt.isEmpty && utilization == 0`. An empty date next to real usage is a different state: the numbers are known even when the clock is not, so the bars stay and only the countdown disappears |
| An idle bar with a full-width solid fill | Idle draws zero in all three styles — track + pill ([ADR-0078](../adr/0078-idle-drawn-as-zero-in-both-styles.md)); a full-width fill reads as Pressure at full pressure |
| A colored idle pill under **Pressure** in the menu bar | Under Pressure the calm side is muted **unconditionally** (`barStyle == .pressure \|\| colorsTell.mutesCalm`, [#381](https://github.com/artem-from-ua/cc-timer/issues/381)), so the pill there is always white — the "Colors tell me" row is not even shown in Settings under this style |
| `usage > time` + green/blue | That is the `.ahead` branch — yellow or orange |
| `usage <= time` + orange via the "20 min" rule | The override is unreachable from the calm branch |
| A calm 7d window that will be exhausted before the reset | `rate = usage/time <= 1` ⟹ the projection is ≤ 1 |
| A full credit bar next to an idle 5-hour | Credits are only spent once the token limit is exhausted — and then 5h is not idle |
| Bold text in a limit row | Both halves are `NSFont.systemFont`, "neither half is bold" |
| A marker-less bar + any ticks | No marker ⟹ not the window scale ⟹ **no ticks at all**: both marker-less styles are marked only by their own **zero tick** (`0` in Pressure, `0.5` in Balance), labeled under ⌥ ([ADR-0098](../adr/0098-ruler-split-identify-always-explain-on-option.md)). The converse does **not** hold: the credit bar has a marker too, and zero ticks |
| Menu-bar Pressure **without** a zero tick, or with the tick at the very left edge of the track | The tick is present in every Pressure and Balance bar of the menu bar, at the **center of the zero pill** — not at `rect.minX` ([ADR-0096](../adr/0096-zero-tick-on-pressure.md)) |
| A zero tick in a pacing color, as wide as the marker, or **above** the track | 1.5 pt (less than a third of the marker's 5 pt), the neutral `centreTick` under `zeroTickAlpha`, **under** the track — otherwise it is a Progress marker (0089, 0096) |
| Menu-bar Progress with a zero tick | Only a marker-less scale has one: in Progress the position is already carried by the time marker (0096) |
| The credit bar with a Pressure or Balance strip | It is always on the window scale, whatever `dropdownStyle` says ([ADR-0092](../adr/0092-extra-usage-own-ruler.md)) — the style switch does not move it |
| The credit bar with ticks — window fractions or at 0.5 | `tickFractions` returns an empty list for it: the credits ruler is two captions, not ticks (0092) |
| The credit bar without a time marker | The window scale ⟹ the marker is always there, as in any Progress bar |
| The credit bar with a cap and boundary captions **without ⌥** | The captions are the ⌥ half of the ruler: at rest they are absent. With a cap and ⌥ held they are always there; without a cap there is neither bar nor captions |
| Month captions that always agree with the local date | They are in UTC (that is where the limit resets), so at a month boundary they diverge from the local calendar by a few hours — unlike the `resetLine` next to them, which is local (0092) |
| A marker-less bar where the drawn strip is narrower than the pill | Values of `0 < length < 8.1%` are entirely **reachable** (the yellow range starts at zero), but the renderer does not draw them: anything narrower than `minStripWidth` (2.75 pt / 34 pt ≈ 8.1%) is floored to the minimum pill. So on screen there is either a pill or a strip ≥ 8.1% — nothing in between |
| An exhausted (`100%`) Pressure bar filled only partially | `u ≥ 1` ⟹ `pressureLength == 1` for any `t` — red is always full |
| A zero-width Pressure strip with no pill | Zero is floored to a pill on **both** surfaces (0076); an empty track does not occur |
| A Pressure bar at `usage == time` with a **strip** (of any length beyond the pill) | `u == t` is the **zero** of the scale, so the minimum pill is drawn. The same for any `u ≤ t`: the entire calm side is a dot ([ADR-0101](../adr/0101-pressure-is-the-gauge-ahead-half.md)) |
| A Balance bar with a time marker | A marker has a position only on the window scale; Balance is a centered scale ([ADR-0079](../adr/0079-centred-zero-gauge-scale.md)) |
| A Balance bar **without** the centre tick — in any state, idle included | The tick is always drawn: without it there is nothing to measure the direction from |
| "The app's style" as a single value: a mockup where the menu bar and the popup are **required** to match | The surfaces have been independent since #329 — `menuBarStyle` / `dropdownStyle`, nine available pairs ([ADR-0080](../adr/0080-per-surface-bar-style.md)). Different styles on the two surfaces are a **valid** state (it is exactly what migrating the old `.mixed` produces), so labeling a render with a single "Bar style" is not allowed |
| A preset (Chill / Work harder! / Control freak) that gives the surfaces **different** styles | Each preset sets one style on both (Pressure / Balance / Progress respectively); a mixed pair is always **Custom** |
| A Balance centre tick as wide as the marker (5 pt), or in a pacing color | `centreTickWidth` = 1.5 pt, the neutral `centreTick` **in the tone of the calm fill** (`labelColor` via `bright()`), **under** the track — otherwise it is a Progress marker ([ADR-0089](../adr/0089-gauge-centre-tick-calm-tone.md)) |
| A Balance strip that does not touch the centre tick (a sliver of track between them) | The edge at zero overlaps it by half a pill width — toward the side the strip is heading; this holds at any length, not just on the floored pill (#326) |
| A Balance strip that crosses the center | The strip grows **from** the center in one direction; it cannot cross its own zero |
| Balance at `usage == time` with the strip left or right of center | A tie is exactly the center (`balanceOffset == 0`), i.e. a centered pill |
| Balance idle with the pill near the left edge | The zero of this scale is the center, so that is where the pill is ([ADR-0078](../adr/0078-idle-drawn-as-zero-in-both-styles.md)) |
| A menu-bar strip shaped like a capsule (radius = half the height) | The strip takes the **track's** radius — `barCorner` 1.5 pt, not `min(w,h)/2` = 2.5 pt: two shapes in one bar share one corner (#326). In the **popup** the strip is capsule-shaped on the contrary — the bar there is 6 pt and it really is a pill |
| A yellow strip lying on a solid gray track | Under a yellow strip (and **only** a yellow one) a transparent gap is cut out of the track — 1.5 pt in the popup, 1.25 pt in the menu bar on each side, with the same radius the strip has. In the menu bar there is no cut-out when yellow is muted ("Colors tell me" in a muting mode, or Pressure — where it is unconditional): it is already dimmed into `calmWhite` (#326) |
| The same `(u, t)` in a different color in different styles | `BarStyle` is render-only; severity is computed before the style is chosen |

## How to check a state arithmetically

A quick script instead of a guess:

```python
def severity(u, t):
    if u >= 1: return "RED"
    if t >= u: return "green/blue"
    return "yellow" if (u - t) < 0.16 * (1 - t) else "ORANGE"

print(severity(0.78, 0.72))   # ORANGE — not green
print(severity(0.88, 0.93))   # green/blue
```

For widths — measure with the same font:

```swift
let f = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
(s as NSString).size(withAttributes: [.font: f]).width
```

## Every mention is a hyperlink

This applies to all artifacts and documents, not only the ones containing renders. **A bare `#283` in
the text is work handed off to the reader**: to follow it, they have to copy the number, remember the
repository and assemble the URL by hand.

These must be hyperlinks:

| What is mentioned | Where it points |
|---|---|
| An issue or PR — `#283` | `https://github.com/artem-from-ua/tokenpace/issues/283` (GitHub redirects `/issues/` to `/pull/` when needed) |
| A commit — `5ee4820` | `…/commit/5ee4820` |
| A file in the repository | `…/blob/main/Sources/TokenPace/StatusItemView.swift` |
| A line of code | the same URL + `#L936` |
| A project document | a relative path if the artifact lives in the repo; a full URL if it does not |
| An ADR | `…/blob/main/docs/adr/0044-dynamic-pacing-threshold.md` |
| Another artifact | its `claude.ai/code/artifact/…` URL |

### One exception: the closing keyword in a PR body

**`Closes #337` in a pull request body is written as a bare number, without a link.** GitHub triggers
auto-closing only on a bare `#NNN` after the keyword; inside a markdown link
(`Closes [#337](…/issues/337)`) the number is invisible to it, so the issue stays open — and you find
out after the merge.

The exception is narrow — exactly **one line** with a keyword (`Closes` / `Fixes` / `Resolves`). Every
other mention of the same issue — in the same PR body, in comments, commits and docs — stays a hyperlink
under the rule above: that rule is about the readability of mentions, while this line is a service
directive for GitHub that the reader does not click anyway.

```markdown
Closes #337                                    ← bare, otherwise it will not fire

Implemented as in [#337](…/issues/337): …      ← a link, as everywhere else
```

(Found out after [PR #338](https://github.com/artem-from-ua/tokenpace/pull/338): "Закриває [#337](…)"
closed nothing — the issue had to be closed by hand.)

### The check before publishing

Bare mentions are easy to miss — especially the ones sitting immediately after a tag (`<div>#283`),
because they do not turn up in a naive search for "space + hash".

```python
import re
s = open("artifact.html").read()
body = s.split("</style>", 1)[1]                     # do not count CSS colors
parts = re.split(r"(<a\b[^>]*>.*?</a>)", body, flags=re.S)
bare = [m.group() for i, p in enumerate(parts) if i % 2 == 0
        for m in re.finditer(r"#\d{2,4}(?![\da-fA-F])", p)]
print(bare or "every mention is clickable")
```

And check that the number in the `href` matches the visible text — a regex replacement desynchronizes
them easily, and the link then leads somewhere else, silently.
