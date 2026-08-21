---
status: accepted
date: 2026-08-07
supersedes: []
superseded_by: [0078, 0079, 0101]
---

# ADR-0076: A scale for the marker-less bar — against time remaining (Pressure), not against the window

> **Partially superseded by [ADR-0101](0101-pressure-is-the-gauge-ahead-half.md):** the strip's zero
> is no longer offset left of `t` — the `(k − 1)` term and the `pressureScaleCoefficient` constant were
> removed, so `u == t` now draws **zero**, not 20%. No longer in force: the section "Width itself
> encodes severity" together with the width table (`0.20`/`0.328`/`0.992`), the section "Why `k = 1.25`,
> not more," and the section "Zero means 'no pressure,' not 'exactly on pace.'" In particular, the
> Consequences claim "no `.ahead` state falls below the minimum pill" remains formally true (yellow is
> `.calm`) but is now **misleading**: about half of the yellow strip now floors. Still standing: the
> signed rendering in place of `|u − t|`, the edge cases for `u ≥ 1` and `t = 1`, and the rename with
> its `rawValue` migration.

> **Partially superseded by [ADR-0078](0078-idle-drawn-as-zero-in-both-styles.md):** the section "Idle
> distinguishes styles" no longer stands — idle now draws **identically** in both styles (track + a
> pill at zero; Progress adds a marker), with no solid fill anywhere. The rest of this ADR — the
> `pressureLength` scale, the ticks, the rename, the migration — still stands.

> **Partially superseded by [ADR-0079](0079-centred-zero-gauge-scale.md):** in the "Alternatives
> considered" section, the item "A separate, fourth style instead of replacing `Pace`" no longer
> stands — that argument was about `Pace`'s redundancy, and it does not apply to **Gauge** (its left
> half shows a quantity that neither pinned style draws). Also no longer standing: the claim that "no
> marker" ⇒ "the remaining-time scale is one decision" — there are now three scales, and the pair of
> booleans was replaced by `BarScale`. The `pressureLength` scale and the **Pressure** style itself are
> unchanged.

> Partially supersedes [ADR-0062](0062-configurable-bar-presentation.md) (§1 `BarStyle`): a marker-less
> strip no longer equals the width of the pacing gap (`gapEnd − gapStart`) — it is computed on a
> renormalized `[now .. reset]` scale. The rest of 0062 (per-surface choice, `CalmColorMode`,
> `FarBehindInterval`, presets) still stands (§4 `showTicks` was superseded by
> [ADR-0098](0098-ruler-split-identify-always-explain-on-option.md)).

## Context

[ADR-0062](0062-configurable-bar-presentation.md) introduced a marker-less strip whose length is
measured **as a fraction of the window**: `gapEnd − gapStart` = `|u − t|`. Its color, meanwhile, is
graded against a **dynamic** threshold that shrinks as the window elapses —
`PacingModel.aheadThreshold` = `0.16 · (1 − t)`.

The two quantities say different things, and they diverge worst exactly where the cost of being wrong
is highest. At `t = 93%`, `u = 97%` — three points from exhaustion, 7% of the window left — the model
hands the renderer **4%** of the bar's width. That is below `minStripWidth` (3.75 pt ≈ 11% of 34 pt),
so the painter inflates the capsule to the minimum pill: **the sharpest state draws the smallest mark
the widget can produce at all**.

Measured across the grid of reachable states (#307):

- **~21%** of states fall below the minimum pill and render identically — "almost exactly on pace"
  cannot be told apart from "three points from exhaustion";
- the ahead group is **non-monotonic**: as sharpness increases, width goes `8% → 4% → 20% → 8% → 4%`,
  meaning a wider bar does not mean a worse state.

This is the same class of mismatch [#255](https://github.com/artem-from-ua/tokenpace/issues/255)
described for popup color ("the loudest element carried the least information"), only on the width
axis.

## Decision

**Measure the marker-less strip against the time remaining, and offset its zero to the left of `t`**,
so that width itself encodes severity directly:

```
r      = (u − t) / (1 − t)          // signed lead, in units of time remaining
length = (r + k − 1) / k            // k = pressureScaleCoefficient = 1.25
```

The strip's zero sits at `t − (1 − t)·(k − 1)`, and the strip runs from there to `u` — **signed, with
no absolute value**. Clamped to `[0, 1]`.

Lives in Kit as `BarLayout.pressureLength` — one source for both painters (`StatusItemView.drawBar`
and `PopupBarView.draw`), so they cannot drift apart, as 0062 warns against.

### Width itself encodes severity

The expression is linear in `r`, and the color thresholds are conditions on that same `r` (orange:
`(u − t) < 0.16 · (1 − t)`, i.e. `r < 0.16`). So the zones become **fixed positions on the bar,
identical at any point in the window**:

| color | width |
|---|---|
| blue (far behind) | `0` |
| green (on pace or behind) | `0 – 0.20` |
| yellow (mild lead) | `0.208 – 0.328` |
| orange (ahead) | `0.328 – 0.992` |
| red (exhausted) | `1` |

That is, **20% is exactly `u == t`**, and **32.8%** is where yellow turns to orange, at 10:00 just as
much as at 14:00. It explains in one sentence, with no arithmetic about time. The test
`severityThresholdsSitAtFixedWidths` checks this against the live `aheadThreshold`, not a copy of the
constant.

### Why signed, not `|u − t|`

An absolute value cannot tell "ahead" from "behind" apart: it bottoms out at `u == t` and **bounces
back**. Tracing a session with an early burst followed by silence (`u` frozen at 40%):

| t | u | `\|u−t\|/(1−t)` | this ADR |
|---|---|---|---|
| 20% | 40% | 25% | 40% |
| 40% | 40% | **0%** | 20% |
| 60% | 40% | 50% | **0%** |
| 70% | 40% | **100%** | **0%** |

In the absolute-value form, the calmest session state draws the loudest geometry — the same defect the
pre-reform `Pace` had. Here, pressure decays to zero and stays there. Locked in by the test
`pressureDecaysAndDoesNotReboundWhenSpendingStops`.

### Why `k = 1.25`, not more

The coefficient sets how much of the bar goes to the calm side, and therefore the width of the
**yellow strip**. At `k = 1.25` it occupies `(0.16 … 0.328)` of the bar — that is **3.9 pt** on a
34-point menu-bar track — a bit wider than the `minStripWidth` floor (3.75 pt), so it can hold a
position distinct from orange. At `k = 2`, that same strip is 2.4 pt, i.e. **under the floor**: yellow
and orange would render identically, and color would remain the only thing telling them apart —
exactly the flaw this ADR was written against.

A constant, not a setting: this is not a matter of taste but what makes the strips distinguishable at
all, and an arbitrary value from the user could silently merge two of them.

### Edge cases

- **`u ≥ 1` (exhausted) — checked FIRST and always draws a full bar.** Red never dims: a shrinking
  strip would read as "the problem is easing" even though work is equally blocked.
- **`t = 1` (the reset has arrived or passed)** — division by zero. There is no time left to measure
  pressure against, so the bar is full regardless of `u`.
- **`u == t`** — exactly `0.20`, **not zero**. This is the fixed "exactly on plan" landmark, which the
  popup marks with a tick.

### Zero means "no pressure," not "exactly on pace"

Zero goes to everything calmer than `t − (1 − t)·(k − 1)`: **40% of the whole state space, 79% of the
calm states**. Both surfaces floor such a strip to the minimum pill (in the popup this was added by
this same ADR — previously `stripRect` returned `nil` and the row stayed an empty track).

This is a deliberate cost, and it is larger than it looked on a 13-state sample. The justification: on
the calm side there is only one action — "do nothing" (green) or "you can push a bit harder" (blue) —
and color already carries that; grading *within* "do nothing" does not lead to a different action.
What the floor does **not** swallow is any `.ahead` state; locked in by the test
`theFloorOnlySwallowsCalmStates`.

`usage == time == 0` is not a rounding artifact but a regular frame: after every 5-hour window reset,
[ADR-0041](0041-idle-grace-on-reset-boundary.md)/[ADR-0045](0045-honest-reset-boundary-grace.md) hold a
"ready" frame with `0%` against a just-rolled-over `resets_at`.

**Progress is deliberately excluded** from this floor: there, an empty gap means "exactly on pace," and
position is already carried by the marker.

### Idle distinguishes styles

> **Superseded by [ADR-0078](0078-idle-drawn-as-zero-in-both-styles.md).** Idle's shape no longer
> depends on style: both draw a track + a pill at zero, and Progress adds a marker on top. There is no
> solid fill anywhere. What follows is the decision as of the 0076 edit, kept as a record.

The idle branch preceded all pacing logic and drew a solid fill **regardless of style**. Under
Progress this is indistinguishable from a Pressure bar showing "full pressure," so idle is now
style-dependent too:

- **Progress** — a solid fill (quota is free) **plus a time marker at zero**: the window has just
  rolled over, so `timeFraction = 0`. The marker is exactly what identifies the style.
- **Pressure** — **a pill on the gray track**, the same shape as any zero strip: idle simply **is**
  zero pressure, so a full-width fill would be the loudest mark for the calmest state.
- **Menu bar under Calm colours** — idle takes the shared `calmWhite` rather than its own dimmer tone
  (`idleCalmGrey`, `secondaryLabelColor`). Idle, quieter than the neighboring calm bars, read as
  "something's wrong with this bar." The popup has no calm-mute for idle at all, so nothing changes
  there.

### Ticks in the popup — keyed to the bar's scale

`PopupBarView.drawTicks` marked equal fractions of the **window** (`k / subdivisions` — hour
boundaries for 5h, day boundaries for 7d). On the renormalized scale, those boundaries have no fixed
position: an hour does not sit at a fixed fraction of the time remaining. So the set of fractions is
chosen per scale:

- **Progress** — `k / subdivisions`, as before (the time marker sits meaningfully among them);
- **Pressure** — **one** tick, at **20%**, exactly `u == t`. A strip shorter than the tick means
  slack, longer means a lead. The second threshold (32.8%, yellow→orange) is already carried by the
  color change, and a second tick 4 pt from the first would read as noise.

**The menu bar has no tick at all.** A lone vertical mark on a 34-point bar looks exactly like
Progress's time marker — the two styles would stop being distinguishable exactly where that is hardest
to notice.

The choice is keyed on `barStyle`, **not** on the data: `drawTicks` also draws under the idle bar,
where `BarLayout` is absent.

### A time marker is impossible in Pressure

On the `[now .. reset]` track, a marker would sit at zero **always**. That is why "no marker" and "the
remaining-time scale" are one decision, not two; it is named in Kit as `menuBarUsesPressureScale` /
`popupUsesPressureScale` (an inversion of the marker flags), so the painters don't have to re-derive it
from a negation every time.

### Names — changed everywhere, with a real migration

`Pace & Time` → **Progress**, `Pace` → **Pressure**; `Mixed` stayed as is. **Both** the UI names,
**and** the enum cases, **and** the `rawValue`s were renamed: `.pacing` → `.progress` (`"pacing"` →
`"progress"`), `.simple` → `.pressure` (`"simple"` → `"pressure"`).

A mismatch between "case in code" and "name in the UI" is a permanent tax on reading code and logs, so
it is not left in place. But a renamed `rawValue` on its own **silently resets** the setting: both
`PersistedConfig.barStyle` and `BarStyle.init(from:)` resolve an unknown raw value to the default with
no error. So the rename ships paired with two safeguards:

- **`PersistedConfig.migrateBarStyleIfNeeded()`** — rewrites the stored value at launch, **before**
  the first read. Idempotent, and leaves a missing key alone (so the fallback to a preset keeps
  working).
- **`BarStyle.legacyRawValues`** + a legacy branch in `init(from:)` — so that a config
  **exported** by an older build ([#257](https://github.com/artem-from-ua/tokenpace/issues/257))
  imports correctly, rather than being silently swallowed by the forward-compatible fallback.

Both read from **one** table, so they cannot disagree about what `"simple"` used to mean.

**Progress is named that way because it matches how the bar is already read.**
[#254](https://github.com/artem-from-ua/tokenpace/issues/254) §3 documented that a horizontal bar next
to "78%" reads as a progress bar to almost everyone — and that reading is **not wrong**: the capsule's
far edge really does equal `usageFraction`. What was missing was that the near edge is meaningful too.
So the name stops fighting that reading and starts confirming it, and the hint adds the second label.

## Consequences

- **The ahead group becomes strictly monotonic**: `11% → 22% → 40% → 44% → 57%`. Width can be trusted
  at a glance.
- **Width itself orders severity** — blue narrower than green, green than yellow, yellow than orange,
  orange than red, with no overlaps. No `.ahead` state falls below the minimum pill (versus ~21%
  before, where the sharpest state drew the smallest mark).
- **Thresholds read without arithmetic**: 20% is exactly on plan, 33% is where orange begins, 100% is
  exhausted — the same positions at any point in the window.
- **Red is always full.** It used to shrink (90% early, 30% late) — and that was a **flaw, not a
  feature**: a shrinking strip reads as "the problem is easing," even though work is equally blocked.
  Time to reset is carried by the countdown (`MenuBarLayout.selectReset` keys on `.ahead`/`.exhausted`),
  the pause glyph, and `pauseHidesBars`.
- **79% of calm states (40% of the whole space) collapse into one pill.** Anyone pacing below the
  linear rate will almost always see an empty bar, and "how much slack do I have" no longer reads from
  geometry — only from color, blue versus green. This is the decision's biggest cost and the main thing
  someone could reasonably disagree with.
- **The track is no longer fixed in time.** 100% means "until the reset," so an identical capsule at
  10:00 and at 14:00 describes different absolute quantities. Reading "exactly how much" without the
  reset label is impossible.
- **Existing users will see noticeably wider strips** with no action on their part — this deserves a
  line in the release notes, not a silent switch.
- **Progress is unaffected**: it still draws `gapStart..gapEnd` on the window scale.

## Alternatives considered

- **Keep the window scale, raise `minStripWidth`.** Does not treat the cause: ~21% of states would
  still fall below the floor, and the ahead group's non-monotonicity is a property of `|u − t|` itself,
  not of the floor.
- **A fill from zero at the `usage` level.** Proposed regularly and rejected regularly: the level is
  the model's input, and the bar shows its **output** (the verdict). See the cross-cutting principle in
  [CLAUDE.md](../../CLAUDE.md) and [ui-state-truth.md](../reference/ui-state-truth.md).
- **A separate, fourth style instead of replacing `Pace`.** Rejected in #307: `Pace` is a strict subset
  case of `Progress` (the same length, just without labels), so it carried no information the other
  two didn't have. The `Pace → Pressure` migration is natural: both are left-anchored and marker-less,
  and only the scale changes.

  > ⚠️ **Superseded by [ADR-0079](0079-centred-zero-gauge-scale.md)** (#326). The argument above is
  > about **`Pace`**'s redundancy, and it remains correct for that case. It does not apply to
  > **Gauge**: that one is not a subset, because its left half draws a quantity (unspent budget against
  > time remaining) that neither pinned style draws — exactly the quantity its `max(0, …)` discards
  > here.
