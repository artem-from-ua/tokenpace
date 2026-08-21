---
status: accepted
date: 2026-08-11
supersedes: []
superseded_by: [0080, 0101]
---

# ADR-0079: Gauge — a fourth style with zero in the middle, showing unspent budget

> **The style was renamed: `Gauge` → `Balance`** ([ADR-0109](0109-centred-style-renamed-to-balance.md),
> #388). Only the **name** and the `rawValue` changed (`"gauge"` → `"balance"`); the scale, the center
> tick, the role of `centreTick`, and `BarScale.centred` are exactly as described below. When reading
> "Gauge" in this document, take it to mean today's **Balance**; `BarLayout.gaugeOffset` is now called
> `balanceOffset`.
>
> ⚠️ **One point below is retracted.** The "What stayed unchanged" section says: "`"gauge"` is a new
> raw value, **not a rename**, so `legacyRawValues` is left alone." After #388 that is no longer true —
> `"gauge"` **is** in `BarStyle.legacyRawValues` and maps to `.balance`; otherwise the rename would have
> reset the setting for everyone who never touched the style (it was the shipped default).

> **Partially superseded by [ADR-0101](0101-pressure-is-the-gauge-ahead-half.md):** the coefficient `k`
> no longer exists on either scale, so the section "Why `k` only on the right" falls away entirely,
> and with it the claim that Pressure's landmarks land "exactly halfway along their distance," and the
> identity `pressureLength − gaugeOffset ≡ 0.20` (the difference is now zero: Pressure **is**
> `max(0, gaugeOffset)`). The two halves became symmetric — both take `r` raw — so **Gauge's ahead-half
> stretched by 25%** relative to this ADR's original edit. Still standing: the style itself, `BarScale`,
> the center tick, the role of `centreTick`, the left half unchanged, and the argument against an
> absolute-value quantity.

> **Partially superseded by [ADR-0080](0080-per-surface-bar-style.md)** (#329): in the "What stayed
> unchanged" section, the **Presets** point no longer stands — `.workHarder` is now **Gauge** on both
> surfaces rather than Mixed, and Gauge is no longer "manual-selection only." There is no `.mixed` case
> at all anymore: the style is now chosen separately for the menu bar and the popup, so "four segments
> in Settings" became two rows of three. The `gaugeOffset` scale, `BarScale`, the center tick, and the
> role of `centreTick` still stand unchanged.

> **Refined by [ADR-0089](0089-gauge-centre-tick-calm-tone.md)**: the default role for `centreTick` is
> no longer `secondaryLabelColor`, but the tone of the **calm fill** (`labelColor` through `bright()` —
> white on a dark bar, black on a light one), and the tick's height is decoupled from the marker's own
> metric, via its own `centreTickHeight` = **10** (it used to borrow `tickHeight` = 9). So read the
> "width × height" row of the table below as **1 × 10**, and the "color" row as "neutral `centreTick`
> (tone of the calm fill)." Everything else — a dedicated role, menu bar only, drawn under the track,
> present in every state — still stands.

> **Refined by [ADR-0096](0096-zero-tick-on-pressure.md)**: the center tick **no longer** belongs to Gauge
> alone — Pressure draws the same mark at its own zero (the center of the zero pill), and
> `drawCentreTick` became `drawZeroTick`, branching on `BarScale`. The objection "the menu bar has no
> tick under Pressure" (`tickFractions`) is withdrawn: it was about a tooth resembling Progress's
> marker, and this tick does not resemble it by construction — the same 1 pt, neutral tone, and
> under-the-track drawing that 0079 set in the first place. Both ticks are additionally dimmed by the
> `zeroTickAlpha` = 0.55 multiplier. Gauge's geometry, its center position, and the role of
> `centreTick` are unchanged.

> Partially supersedes [ADR-0076](0076-pressure-scale-for-marker-less-bar.md) (§"Alternatives
> considered," the item "A separate, fourth style instead of replacing `Pace`"): that item rejected a
> fourth style on grounds that applied specifically to `Pace`, and it does not apply to Gauge. The
> rest of 0076 — the `pressureLength` scale, the tick at 20%, the rename, the `rawValue` migration —
> still stands; **Pressure keeps its scale unchanged**.

## Context

[ADR-0076](0076-pressure-scale-for-marker-less-bar.md) made the strip's width carry urgency — and did
it well, but **only on one side**. The length of the Pressure strip:

```
r      = (u − t) / (1 − t)          // signed lead, in units of time remaining
length = min(1, max(0, (r + k − 1) / k))        // k = 1.25
```

This `max(0, …)` does not "compress" the under-spending half — it **destroys it before rendering**.
0076 itself records this: ~40% of the reachable state space, or 79% of the calm states, land on `0`
and render as the same minimum pill. A user with a large unspent budget sees exactly the same thing as
a user exactly on plan. A wider bar cannot help here — the quantity is already gone from the number.

0076 called this a deliberate trade-off: "on the calm side, the action is already carried by color
(green 'do nothing' versus blue 'you can push'), and grading *within* 'do nothing' maps to that same
action." The argument holds for **Pressure** and still stands — but it assumes there really is no
action to be had inside the calm zone. [#278](https://github.com/artem-from-ua/tokenpace/issues/278)
shows there is one: "'calm' is a relative judgment with no notion of an absolute remainder," and a
high-but-behind bar cannot be told apart from a low-but-behind one. The quantity "how much quota I
won't manage to spend before the reset" passes the check from
[users-and-goals.md](../reference/users-and-goals.md) — it changes an action: it's exactly what
nudges someone to start that refactor they've been putting off.

Why this doesn't contradict 0076's rejection of a fourth style. That item rejected `Pace` as "a strict
subset case of `Progress` (the same length, just without labels), so it carried no information the
other two didn't have." The argument was about **redundancy**, and it's correct for `Pace`. Gauge is
the opposite case: its left half shows a quantity that **neither pinned style draws**. Progress does
have a left side geometrically, but it measures it against the window, not against time remaining: at
`t = 90%, u = 70%` it gives 20% of the bar, and "behind" only reads from the marker's position, with
no sense of whether that slack is still realistically spendable.

## Decision

**Add a fourth `BarStyle` — `gauge` — with zero in the middle of the bar. The same numerator and the
same denominator as `pressureLength`; only what it's measured from changes:**

```
r      = (u − t) / (1 − t)
offset = clamp(r / k, −1, +1)       // k = 1.25 only on the right half; the left half takes r raw
```

The strip runs from the center to `centre + offset · (width/2)`: **rightward** when ahead,
**leftward** when behind. Lives in Kit as `BarLayout.gaugeOffset`, alongside `pressureLength`.

### Why `k` only on the right

`k` exists for one purpose — keeping the *ahead* bands wide enough to distinguish on a 34 pt track
(0076: at `k = 2`, the yellow band is 2.4 pt, under the 3.75 pt minimum pill). Dividing the right half
by that same `k` reproduces **every** Pressure landmark at exactly half of its original distance:
20%, 32.8%, and 100% of the Pressure bar become 0%, 10%, and 80% of the right half. So switching
Pressure ↔ Gauge changes nothing about what the ahead side says — locked in by the test
`aheadHalfMatchesPressureOrdering` (the difference `pressureLength − gaugeOffset` is constant and
equals 0.20).

The left half has no such bands — it's one continuous green-to-blue range in which color already
carries the verdict. Applying `k` there too would spend resolution pushing apart boundaries that don't
exist, instead of the quantity that actually varies there: the size of the slack. So the left half
takes `r` raw.

### Both halves are measured against the same thing — time remaining

`offset = −1` means "the slack equals the entire time remaining": it cannot be spent even if you try.
At `t = 90%, u = 70%`, the slack (20 pp) is twice the time remaining (10 pp) — the left half is
**full**. Algebraically the left half saturates at `u ≤ 2t − 1`.

### The left half's saturation — a deliberate trade-off

`u ≤ 2t − 1` is impossible before `t = 50%`, and grows past that: at `t = 70%` it covers 57% of the
then-current under-spending states, at `t = 90%` it covers 89%. So late in the window, the left half
is flat. This mirrors — from the other side — the flatness Pressure has **early** in the window, and
it tells the truth: late in the window, most surpluses really are larger than the time remaining, and
"you're not going to spend this" is an honest answer. The test `deepSurplusFillsTheLeftHalf` pins the
boundary from both sides.

### `u == t` is zero, not 20%

Pressure gives an on-plan state 20% flat, because its zero is offset left of `t`. On the centered
scale, `t` **is** zero, so on-plan sits at exactly the center. No contradiction: these are different
scales, and each names its own zero. A degenerate strip floors to a **centered pill**
(`floorEmptyToPill` in the menu bar, `pillRect` in the popup) — under the same rule as Pressure, and
for the same reason: an empty track would read as "no data," not as "exactly on plan."

### The center tick — on both surfaces, and why it isn't a marker

Zero has to be findable, or direction has nothing to be measured from. So the tick is drawn in
**every** state, idle included.

0076 left the menu bar without ticks, with a specific objection: "a lone vertical tick on a 34 pt bar
looks exactly like Progress's time marker, so the two styles would stop being distinguishable." The
objection still holds — but it's about *that specific* tick, not about ticks in general. The risk is
resolved by construction:

| | Progress marker | Gauge center tick |
|---|---|---|
| width × height | 5 × 9 pt | **1** × 9 pt |
| color | pacing color (green/yellow/…) | neutral `centreTick` (`secondaryLabelColor`) |
| draw order | **over** the track, with a stroke | **under** the track, no stroke |
| position | `timeFraction` — moves | center — fixed |

A fifth of the width, a neutral tone, and only the tips peek out from under the track. The popup needs
no separate tick — the tick ruler already sits under the bar, so `tickFractions` simply returns
`[0.5]` instead of `[0.20]`.

**Color is its own role, `centreTick`, defaulting to `secondaryLabelColor`, menu bar only.** The tick
originally took `indicatorRing` (the marker's stroke color, `quaternaryLabelColor`) — the dimmest of
the available neutral roles; on a live bar, zero turned out to be hard to find. The popup's `tick`
role (`tertiaryLabelColor`) is also dim, and its semantics differ anyway: that ruler **annotates** a
bar that already reads fine without it, whereas here the tick is the sole landmark the entire style's
message is relative to. Hence a dedicated role, one notch brighter, tunable in the color tuner; the
popup's tick stays on its own `tick` role. Ticks at ±50% of each half were considered and rejected:
they would mark something the scale doesn't define — what reads here is the **direction** away from
center, not a distance along a ruler.

### The pair of booleans became `BarScale`

Before Gauge there were two scales, distinguished by exactly one bit: 0076 called this one decision —
`menuBarUsesPressureScale == !menuBarShowsTimeMarker`, "'no marker' and 'the remaining-time scale' are
one decision, not two that could drift apart." A third marker-less scale breaks the **reverse**
direction of that equivalence: Gauge is also marker-less, but it isn't Pressure.

Adding a third negation flag would mean encoding three states in two booleans, with one unreachable
combination. Instead, `BarScale { window, remaining, centred }` is introduced, and the marker flags
are **derived** from the scale: `showsTimeMarker == (scale == .window)`. This keeps the implication
that survived the change — a marker only has a position on the window scale — but now as a one-way
rule rather than an identity. Renderers branch on the scale itself.

### What stayed unchanged

- **Color.** The same `(u, t)` produce the same `PacingSeverity` in all four styles. Gauge is
  render-only, like the entire `BarStyle` line
  ([ADR-0062](0062-configurable-bar-presentation.md), [ADR-0078](0078-idle-drawn-as-zero-in-both-styles.md)).
- **Idle.** Per [ADR-0078](0078-idle-drawn-as-zero-in-both-styles.md): a gray track + a pill at zero.
  Gauge's zero is the center, so the pill sits there; there is no marker.
- **Pressure.** Stays a separate style with its own scale. It is quieter in calm states by
  construction, and some users will prefer exactly that.
- **Presets.** `.chill` → Pressure, `.workHarder` → Mixed, `.controlFreak` → Progress — unchanged.
  Gauge is available only by manual selection.
- **Migration.** `"gauge"` is a new raw value, not a rename, so `legacyRawValues` is left alone. An
  older build reading `"gauge"` falls back to `.progress` through the existing forward-compatible
  decode.

## Consequences

- **The calm side finally has resolution.** Of six surveyed calm states, five become distinguishable
  (3.2 / 4.3 / 5.1 pt for different slack amounts) where Pressure draws one pill for all of them. Only
  "exactly on plan" collapses — and that is exactly the one that **should** be zero.
- **The ahead side did not change anywhere.** Locked in by a test, not by intent: switching
  Pressure ↔ Gauge does not move the right half.
- **The side has to be read separately from the length.** In Pressure, length means exactly one thing.
  In Gauge, the same length means opposite states depending on the side. Two ways to tell them apart:
  **direction** from the center tick (always available — the tick is present in every state) and
  **color**. Under **calm colours**, the color cue disappears: `CalmColorMode.mutesCalm` collapses
  green and yellow into `calmWhite`, and the default `.yellowGreenBlue` mutes blue too — the entire
  calm range on both sides becomes one tone. Direction remains and is sufficient, but it's one extra
  eye movement. This exact case is checked live on the `gauge-sweep` stub.
- **Half the bar per direction means half the resolution per side.** A 34 pt menu-bar bar → 17 pt per
  half → roughly 4–5 distinguishable steps in each direction. In the popup, where the bar is much
  wider, this isn't a problem.
- **Inherited from Pressure:** the bar can't be read without the reset label — 100% means "until the
  reset," not "the whole window." The same strip at 10:00 and at 14:00 describes different absolute
  quantities.
- **Four segments in Settings.** The order `Pressure · Mixed · Gauge · Progress` reads as a gradient of
  how much positional information the bar carries: length only → length in the bar, positions in the
  popup → length plus direction → two positions on the window.
- **`BarScale` is now a public Kit type.** Renderers branch on it; a fifth scale (if one ever comes)
  gets added as a case, not one more boolean.

## Alternatives considered

- **Gauge instead of Pressure, rather than alongside it.** Gauge is a strict superset case on the
  ahead side and adds a behind side, so replacing Pressure looks natural. Rejected: Pressure is
  quieter in calm states by construction (everything calm is one pill), and that is a genuine
  difference, not a defect. Replacing it would also cost a `"pressure" → "gauge"` migration for a
  choice some users made deliberately.
- **An absolute-value quantity instead of a signed one.** The same trap 0076 already worked through
  for `pressureLength`: `|u − t|` cannot tell "ahead" from "behind" apart, bottoms out at on-plan, and
  climbs back up. On a centered scale, the sign *is* half the message, so an absolute-value form would
  destroy the style completely.
- **Fill the left half with the unspent level (`t − u` against the window).** A recurring proposal
  that fails for the same recurring reason: the level is the model's **input**, and the bar shows its
  **output** (the verdict). Against the window, "20 pp of slack" at 10:00 and at 14:00 is the same
  number with opposite meaning; against time remaining, it means one thing.
- **Ticks at ±50% of each half.** Would mark something the scale doesn't define. What reads here is
  the direction out from the center, not a distance along a ruler; a second pair of teeth 4 pt from
  the center would read as noise (the same argument 0076 used to stop at one tick).
- **A menu-bar tick drawn over the track rather than under it.** Simpler, but the tick would slice the
  strip in half when it passes through the center, and would look like a marker. Under the track, only
  the tips show — enough to find zero, and not enough to be confused with data.
