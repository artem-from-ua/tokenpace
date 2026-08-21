---
status: accepted
date: 2026-08-15
supersedes: []
superseded_by: []
---

# ADR-0101: Pressure is the right half of Gauge, and the scale coefficient is gone

> **Style renamed: `Gauge` → `Balance`** ([ADR-0109](0109-centred-style-renamed-to-balance.md),
> #388). This ADR's thesis still stands word for word — only the names changed:
> `BarLayout.gaugeOffset` became `balanceOffset`, and the title should now read "Pressure is the
> right half of **Balance**." The test named in this document's prose as
> `pressureIsTheGaugeAheadHalf` is now called `pressureIsTheBalanceAheadHalf`.

> Partially supersedes [ADR-0076](0076-pressure-scale-for-marker-less-bar.md): the strip's zero is no
> longer shifted left of `t` — the `(k − 1)` term is removed, so "exactly on pace" now draws
> **zero**, not 20% of the bar. Along with it go the fixed-width table (§"Width alone encodes
> severity") and §"Zero means 'no pressure,' not 'exactly on plan.'" The rest of 0076 —
> sign instead of `|u − t|`, the edge cases `u ≥ 1` and `t = 1`, the `Pace → Pressure` rename with its
> `rawValue` migration — still stands.

> Partially supersedes [ADR-0079](0079-centred-zero-gauge-scale.md): §"Why `k` is applied only on the
> right" disappears along with `k` itself; the identity `pressureLength − gaugeOffset ≡ 0.20` no
> longer holds (the difference is now zero); Gauge's halves become **symmetric**. The style itself,
> `BarScale`, the center tick, and the role of `centreTick` are unchanged.

> Refines [ADR-0098](0098-ruler-split-identify-always-explain-on-option.md): its claim that "styles
> differ at rest" still stands, but now rests **solely** on the position of the zero tick — Pressure's
> ahead side has become numerically identical to Gauge's ahead half.

## Context

[ADR-0076](0076-pressure-scale-for-marker-less-bar.md) gave Pressure a scale with zero **left** of
`t`:

```
r      = (u − t) / (1 − t)
length = (r + k − 1) / k            // k = pressureScaleCoefficient = 1.25
```

The `(k − 1)` term gave away part of the bar to the calm side: the "exactly on pace" state
(`u == t`) drew the strip at **20%** of the width, and true zero was reached only by being calmer
than `t − (1 − t)·0.25`. The `k` coefficient existed exactly to control this split and keep the
yellow band above the minimum pill.

The maintainer asked that **the whole** calm side (both green `.calm` and blue `.farBehind`) draw as
a dot — that is, that Pressure show **only the right part of Gauge** — and that the code producing
that 20% go away. The color computation was to stay untouched.

On review it turned out that once the shift is removed, the `k` coefficient doesn't just become
unnecessary — it starts **hurting**. Measured across a grid of reachable states (`t = 1…98`,
`u = 0…99`):

| | `k = 1.25` | without `k` |
|---|---|---|
| yellow band on a 34 pt track | 4.35 pt | **5.44 pt** |
| yellow buried under a 2.75 pt floor | 63.2% | **50.6%** |
| orange→red jump | **6.8 pt** dead zone | **0** |
| states that draw a bare pill | 55.1% | **54.1%** |

In other words, `k` was **narrowing** the yellow band, not widening it — its justification in 0076
only worked paired with the shift. Worse: as long as `u < 1`, `r < 1` always held, so `r/k < 0.8`,
meaning the top 20% of the bar corresponded to **no** reachable state before exhaustion. The bar only
landed there via a jump, when the `u ≥ 1` guard threw it to full. **The same jump existed in Gauge**
too — for the same reason, just half as noticeable, since it landed on half the bar.

## Decision

**Both scales are derived from a single quantity, with no coefficients at all:**

```
r              = (u − t) / (1 − t)      // signed lead, in units of remaining time
gaugeOffset    = clamp(r, −1, +1)       // from center: left / right
pressureLength = max(0, gaugeOffset)    // the right half, stretched across the full track
```

`PacingModel.pressureScaleCoefficient` is **removed from the code**. The shared edge cases are
factored into a private `BarLayout.signedLead`, which returns `nil` for "saturated" — so the order of
checks ("exhausted comes first, so `t == 1` never divides by zero") became a property of one
function, instead of a comment repeated twice.

### Pressure is defined **in terms of** Gauge, not in parallel with it

`pressureLength` is literally `max(0, gaugeOffset)`, one line. The claim "Pressure is the right half
of Gauge" stopped being an agreement between two formulas that had to be kept in sync by hand, and
became a property of the code. The cost: Pressure inherits Gauge's clamp (`max(-1, …)`), which is
unreachable on this side; the benefit: the two scales can no longer diverge, and a test pins this
with **exact** equality across the whole grid (`pressureIsTheGaugeAheadHalf`), no epsilon.

Previously this role was played by a drift guard on the difference
`pressureLength − gaugeOffset ≡ 0.20`, which only held on the ahead group.

### Zero sits at `t`, and the threshold lands on the bar with no rescaling

Severity bands:

| color | width |
|---|---|
| blue (far behind) | `0` |
| green (on pace or behind) | `0` |
| yellow (mild lead) | `0 – 0.16` |
| orange (ahead) | `0.16 – 1` |
| red (exhausted) | `1` |

`0.16` is **`aheadThreshold` itself** — the drawn width is now the same number the model compares
against, not a rescaled version of it. There's no gap between the orange ceiling and red — the scale
reaches `1` continuously.

### Gauge changes on screen too

This is **not** a render-only change to a single style. Gauge's left half doesn't move at all (`k`
was never applied there); the right half stretches by exactly 25%:

| state | before | after |
|---|---|---|
| Mild lead, early | +0.0914 | **+0.1143** |
| Mild lead, late | +0.1778 | **+0.2222** |
| Ahead, mid-window | +0.3200 | **+0.4000** |
| Ahead, late | +0.3556 | **+0.4444** |
| Ahead, very late | +0.4571 | **+0.5714** |

### Color is untouched

`BarLayout.severity`, `PopupBarView.aheadColor`, and `behindColor` read fractions and thresholds —
never the strip's length. The same `(u, t)` yields the same `PacingSeverity` across all three
styles, as before. This is geometry, not a verdict.

## Consequences

- **The entire calm side is one dot.** `u ≤ t` yields exactly zero, and both surfaces floor it to
  the minimum pill. Combined with the floor, that's **54.1%** of the state space (was 43.3%). Anyone
  pacing below the line now sees an empty bar always, not almost always.
- **Half of the yellow band drowns in the floor** — 50.6% of the range, whereas 0076 kept yellow
  entirely above it. This is the largest cost of the decision. Mitigation: in **measurable** states
  there's still headroom — at `t = 30%, u = 38%` yellow draws 3.9 pt against a 2.75 pt floor, so "mild
  lead" is still a shorter strip, not a dot.
- **Under Calm colours, yellow and green merge completely.** `mutesCalm` folds both into
  `calmWhite` (`PacingSeverity.calm` covers both green and yellow), and now part of yellow coincides
  with them geometrically too. Orange — "action needed" — stays colored always, so the channel that
  carries action is unaffected. This is a deliberate acceptance, and here's why: choosing Pressure
  sets the `.chill` preset, which by that same choice enables the fullest muting — that is, it's the
  choice of someone who has already said "don't show me gradations within calm." The factory default
  is Gauge (`.workHarder`), and that's the one that draws the calm side.
  [ADR-0079](0079-centred-zero-gauge-scale.md) anticipated this: "Pressure remains a separate style
  with its own scale. It is quieter in calm states **by construction**, and some users will choose
  exactly that."
- **Two defects nobody was looking for are gone.** The orange→red jump (in both scales) and the
  yellow band narrowed by `k`.
- **Existing users will see noticeably different bars** with no action on their part — in both
  Pressure and Gauge. Worth a line in the release notes.
- **`u == t` is now zero identically in both scales**, so the impossible-combinations table in
  [ui-state-truth.md](../reference/ui-state-truth.md) flips sign on the corresponding row: a Pressure
  bar at `usage == time` draws a **pill**, not a 20% strip.

## Alternatives considered

- **Keep the shift, change only the renderers.** Rejected: the model would keep carrying a 20% that
  nobody reads, and the mismatch between "what's in the number" and "what's on screen" is exactly
  where the next round of bugs starts.
- **Remove the shift but keep `k = 1.25`.** Considered first and rejected by measurement: `k` without
  the shift narrows the yellow band (5.44 → 4.35 pt), buries more of it under the floor
  (50.6% → 63.2%), and preserves the dead zone with its 6.8 pt jump. No measurement in which it comes
  out ahead.
- **Derive `pressureLength` from its own formula, `clamp(r, 0, 1)`, not from `gaugeOffset`.**
  Numerically identical (checked against every edge case). Rejected: "Pressure is the right half of
  Gauge" would remain an agreement held together only by a test — exactly the construction whose
  drift guard this ADR is removing.
- **Give yellow its own pedestal so it doesn't drown in the floor.** Rejected **for now**: this would
  bring the shift back under a different name, applied to just one band. If a live review shows
  yellow is unreadable, the more honest fix is to exempt it from `mutesCalm` under Pressure — that
  is, fix the color channel rather than mixing the shift back into the geometry.
