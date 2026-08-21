---
status: accepted
date: 2026-08-02
supersedes: []
superseded_by: [0062, 0081, 0115]
---

# ADR-0061: The "far behind" blue pacing zone + the "Work harder" option

> **§4 "Scope — base 5h/7d only" reaffirmed and moved to
> [ADR-0115](0115-no-blue-on-per-model-windows.md)** ([#426](https://github.com/artem-from-ua/tokenpace/issues/426)).
> The decision itself still stands and was never reversed — only the **mechanism** is superseded:
> the `PopupBarView.isBaseLimit` flag is gone; the rule now lives on `BarLayout.blueAllowed`, where
> every surface can see it. The gate living only in rendering turned out to be the reason the model
> (and hence the journal) didn't know about this restriction for years and recorded blue for scoped
> windows that were never shown on screen.

> **Partially superseded by [ADR-0081](0081-weekly-capacity-gate-for-blue.md).** The behind
> threshold is fixed again (the multiplier is a ×2 constant, the option is gone), but a new
> condition was added: blue only shows while the **weekly window itself has headroom**
> (`BarLayout.blueAllowed` / `PacingModel.weeklyHasHeadroom`). The `ColorRole.paceBlue` role is
> merged into `.blue`.
>
> **Partially superseded by [ADR-0062](0062-configurable-bar-presentation.md) (#224).** The behind
> threshold is no longer a **fixed** width — it is now configurable via `FarBehindInterval`
> (multiplier ×1/×2/×3, or off), defaulting to 2h/2d. The boolean "Work harder" option (section 5)
> is replaced by the three-state `CalmColorMode` (`.off` / `.yellowGreen` / `.yellowGreenBlue`).
> What still stands: the blue severity case `farBehind` (section 3), the 20-minute start override
> (section 2), the 5h/7d scope (section 4), the `ColorRole.paceBlue` role, and the
> `BarLayout.windowDurationSeconds` field.

## Context

The color of the pacing gap on the "on pace / behind plan" side (`usage <= time`,
`PacingState.onPaceOrBehind`) has so far been **uniformly green** — no internal threshold at all.
That mirroring is incomplete: the "ahead of plan" side is already split into yellow+orange by the
dynamic threshold `aheadThreshold = 0.16·(1 − timeFraction)` ([ADR-0044](0044-dynamic-pacing-threshold.md)),
while the "behind" side stayed flat.

**The problem.** "Slightly behind pace" and "deeply behind with a large surplus" are different
states, and a uniform green blends them together. When you are meaningfully below the spending
line, you have real limit headroom, and that's worth showing with its own, calmest tone.

## Decision

**Split the green zone into blue (`farBehind`) + green (`calm`) with a threshold of fixed time
width; blue applies only to base 5h/7d bars; add a "Work harder" option.**

### 1. A behind threshold of fixed time width

Unlike the dynamic `aheadThreshold`, the green→blue transition is a **fixed span of wall-clock
time**, different for each window:

- **5h: 60 min** → `behindThreshold = 3600/18000 = 0.20`
- **7d: 24 h** → `behindThreshold = 86400/604800 ≈ 0.1429`

```
behindThreshold = LimitWindow.blueBehindWidthSeconds / windowDurationSeconds
```

`surplus = timeFraction − usageFraction`:

- `surplus > behindThreshold` → **blue** (`.farBehind`);
- otherwise → **green** (`.calm`).

The comparison is strict (`>`): a surplus exactly at the threshold stays green (the louder of the
two calm tones).

**Why a fixed width rather than a dynamic mirror of ahead.** "More than an hour behind (5h) / a day
behind (7d)" is a stable, legible surplus that doesn't depend on how much of the window has already
elapsed. A dynamic threshold (as on the ahead side) would make the blue boundary a moving target,
which reads worse for "there's room to coast." The width is stored as absolute seconds on
`LimitWindow.blueBehindWidthSeconds` and divided by `windowDurationSeconds` (carried by
`BarLayout`) in `PacingModel.behindThreshold(windowDurationSeconds:)`.

### 2. The 20-minute blue **start** override

In the **first 20 min** of a window (`elapsed-since-start ≤ 1200 s`), the "on pace/behind" side is
**always green**, regardless of the threshold. Right at the start, almost any usage reads as a large
surplus, so blue would flash on immediately. This is the symmetric twin of the orange override from
ADR-0044 (which guards the **end** of the window): `elapsed = windowDurationSeconds −
remainingSeconds`, so unlike the orange override, which works purely off `remainingSeconds`, this
one needs the **window's length**. The constant is
`PacingModel.pacingBlueStartOverrideSeconds` (1200 s).

### 3. `farBehind` — a separate severity case, **calmer** than green

`PacingSeverity` is now a four-beat progression: `farBehind` (blue) → `calm` (green/yellow) →
`ahead` (orange) → `exhausted` (red). The order runs from calmest to loudest.

Critically: `farBehind` is a **subtype of calm**, not of loudness. It must not trigger the
reset countdown or otherwise behave as "noisy." Hence:

- `BarLayout.isCalm` (and `BarView.isCalm`) = `severity == .calm || severity == .farBehind` — both
  are "not worth a flag";
- **but** `MenuBarLayout.selectReset` tests "noisy" **explicitly** as `severity == .ahead ||
  severity == .exhausted` (instead of the former `!= .calm`). Without this fix, adding `farBehind`
  to `isCalm` would have made a deeply-behind window "noisy" and started forcing the countdown — a
  regression. The explicit test keeps countdown behavior **identical** to what it was before
  `farBehind` existed.

### 4. Scope — base 5h/7d only

Blue shows **only** for the base 5-hour and 7-day bars. **Not** for model-specific (per-model /
per-service) rows, and **not** for extra-usage (credits) — those stay green, as before. The
distinction across surfaces:

- The **menu bar** already carries only 5h/7d (no per-model there; credits get their own
  `creditsIconColor`), so `calmedGapColor` lets the blue logic through with no gate, and
  `creditsIconColor` is left untouched.
- The **popup** shares one `PopupBarView` across the base, per-model, and credits, so a
  `PopupBarView.isBaseLimit` flag was added — `true` only for rows 0/1 (`PopupLayout.rows` always
  starts with 5h, 7d), `false` for per-model; credits go through the raw `addBar(bar:…)` and never
  get the flag.

  > ⚠️ **The flag was removed in [ADR-0115](0115-no-blue-on-per-model-windows.md).** The rule is
  > the same, but now lives on `BarLayout.blueAllowed`, which both rendering and `PacingBucket`
  > read. A gate visible only to rendering was the very flaw that made the journal diverge from the
  > screen: the model had no idea about it and recorded blue where the popup was drawing green.

### 5. The "Work harder" option (non-calm blue)

A new appearance option (second in the *Menu Bar Widget* section, right after "Calm non-critical
colors"). When enabled, the blue (`farBehind`) zone is treated as **non-calm**: it does **not** mute
to white under Calm colors, i.e. blue always stays colored (a reminder that "there's room to
coast"). The rest of the calm states (green/yellow) mute as before. The effect is visible only when
Calm colors is on.

- Default is **off** (opt-in), key `PersistedConfig.workHarderColors`
  (`object(forKey:) as? Bool ?? false`).
- In the presets (#215): **Chill — off**, **Control freak — on**.

### Color and plumbing

- A new `ColorRole.paceBlue` (default `.systemBlue`) — a separate semantic role, so as not to
  overload the existing `.blue` (the idle bar / maintenance dot).
- `BarLayout` gets a new stored field `windowDurationSeconds: Int`, filled in
  `PacingModel.barLayout(...)` from `window.durationSeconds`. Both the Kit's `severity` and
  AppKit's `behindColor` read the same field, so color and severity never diverge.
- The formula is a single one: `PacingModel.behindThreshold(...)`, shared by `BarLayout.severity`
  (Kit) and `PopupBarView.behindColor(_ l: BarLayout)` (AppKit). `behindColor` takes the whole
  `BarLayout` (which carries `windowDurationSeconds`), so the start override is computed the same
  way in both layers.

## Consequences

- **A new calmest tone.** Deeply-behind now reads as blue on the base bars of both surfaces.
- **Hiding the calm strip now also hides blue.** Since `farBehind ⊂ isCalm`, a deeply-behind bar
  hides under the same choice as a green one — **regardless of which window is chosen**
  ([ADR-0086](0086-tri-state-calm-bar-hiding.md); at the time of this ADR it was a boolean
  `hide-calm-7d` that could only hide the 7-day strip). This is deliberate: blue is calmer than
  green, so if green hides, blue hides even more so.
- **No change to the reset countdown.** `selectReset` computes "noisy" via `.ahead`/`.exhausted`,
  so `farBehind` never forces the countdown — behavior is identical to before the reform.
- **The severity rung order on the ahead side is unchanged.** Only the `.onPaceOrBehind` branch
  changed: first the 20-minute start override → green, then the behind threshold → blue/green.
- **Credits and per-model are out of scope.** Blue does not apply to them; their behavior
  (including credits-icon muting) is unchanged.
- **ADR-0044 still stands** for the ahead side — this entry only adds the behind side (with its own,
  fixed threshold) and doesn't revoke any of its clauses.
