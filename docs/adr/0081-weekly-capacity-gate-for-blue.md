---
status: accepted
date: 2026-08-12
supersedes: []
superseded_by: [0105, 0115]
---

# ADR-0081: Blue is gated by the week's headroom; the far-behind zone's width is fixed

> **§3 (the per-model portion) and §5 were superseded by
> [ADR-0115](0115-no-blue-on-per-model-windows.md)**
> ([#426](https://github.com/artem-from-ua/tokenpace/issues/426)). Per-model rows
> (Opus / Sonnet / scoped) **do not** carry the weekly gate — they have an unconditional
> `blueAllowed: false`, because they are slices of the same week the blue is talking about
> ([ADR-0061 §4](0061-far-behind-blue-pacing-zone.md), never retracted, only moved from render to
> model). §5's claim that the discrepancy with scoped-blue "closes" **was wrong**: `PacingBucket`
> learned to read `blueAllowed`, but `blueAllowed` itself remained `weeklyHasHeadroom`, so with an
> open week, blue still passed through — 2,214 such records in the August journal. **Still standing:
> §3 for the 5-hour bar** (the gate itself, closed-by-default, degradation to green), as well as §1,
> §2, and §6.

> **§4 "The idle pill is three-valued" was superseded by
> [ADR-0105](0105-color-advice-governs-pacing-bars-only.md)**
> ([#381](https://github.com/artem-from-ua/cc-timer/issues/381)): the pill now has **two** states —
> gray `isBlocked` and **green** otherwise; blue no longer appears on either surface. Along with it,
> the `BarView.weeklyHeadroom` / `LimitRow.weeklyHeadroom` fields were removed — they existed only to
> thread the weekly verdict through an inert idle row. **§3 still stands** — the weekly gate itself,
> which continues to gate `blueAllowed` on **active** bars, as do §1, §2, §5, and §6. The option named
> `CalmColorMode` here is called `ColorAdvice`
> ([ADR-0104](0104-appearance-named-for-behaviour-on-three-layers.md)).

> Partially supersedes [ADR-0061](0061-far-behind-blue-pacing-zone.md) (§1 "A behind threshold of
> fixed time width" — the threshold stays fixed, but the multiplier is no longer configurable) and
> [ADR-0062](0062-configurable-bar-presentation.md) (§3 `FarBehindInterval` — the option is removed).
> Still standing: the blue severity case `farBehind`, the 20-min start override, the 5h/7d scope,
> `CalmColorMode`, presets as the single source of defaults.

## Context

Blue (`.farBehind`) means "you're substantially below the spending line — there's room to push." This
is **advice**, not just a color grade: the user sees blue and speeds up.

The advice was computed **strictly within its own window**. This produced a state in which it lied:

- the 7-day limit is exhausted (or close to it), there's nothing left to work with;
- the 5-hour window has just reset and is empty;
- 20 minutes in (after the start override), the 5h bar turns blue — "speed up!" — while the week is
  blocked.

This wasn't a hypothetical state. The repository had a `bar-extremes` stub with a fixture
`(5h: 5%, 7d: 31.25% at t = 30%)` — that is, 5h blue while the week is already ahead of pace.

The same lie was present in the **idle** pill, through different code: it drew blue with the words
"ready to start, full quota available," and turned gray **only** when `CreditsPacing.isBlocked` (7d =
100% *and* credits don't cover it). At 7d = 85%, the pill promised the full quota of a week that's
already burning down.

In parallel, the width of the blue zone was set by the `FarBehindInterval` option (×1/×2/×3/off,
default ×2). It:

- duplicated what the journal already pinned (`PacingBucket` always computed at ×2, ignoring the
  setting);
- had effectively dead values: ×3 gives a 5h threshold of 0.60, and `surplus ≤ timeFraction`, so blue
  there is reachable only in the window's last two hours at near-zero usage;
- created a conflicting UI state (the "+ Blue" segment in the Calm control had to be disabled whenever
  the interval was set to `off`).

## Decision

**The width is fixed at ×2; whether to draw blue at all is decided by the data, not a setting.**

### 1. `FarBehindInterval` removed, multiplier = 2

`PacingModel.farBehindWidthMultiplier = 2` → 5h: 2 h / 5 h = **0.40**, 7d: 2 days / 7 days ≈
**0.2857**. ×2 was chosen because it was already the shipped default and the value the journal was
written against; ×1 was deliberately not made the default when the option was introduced, and ×3 is a
dead zone.

`behindThreshold(windowDurationSeconds:)` lost its `multiplier` parameter and **never returns `+∞`
anymore**: it now only answers "how wide is the zone," not "does it even apply."

### 2. `BarLayout.blueAllowed: Bool` instead of `behindMultiplier: Int`

The `behindMultiplier` field (where `0` meant "no blue") was replaced by `blueAllowed`. Both
mechanisms — the old `off` and the new gate — answer **the same** question, "does this bar have the
right to show blue," so they merge into one field rather than adding a second.

A side benefit: the rename turned "silently diverged" into "won't compile" — four of the five places
that decide blue read the old field explicitly, so the compiler caught every one of them.

### 3. The weekly-capacity gate

```swift
PacingModel.weeklyHasHeadroom(in: snapshot, now: now)
  = d7.pacing == .onPaceOrBehind && d7.usageFraction < 1
```

That is, the d7 bucket ∈ {blue, green}. `blueAllowed` distribution:

| Bar | `blueAllowed` |
|---|---|
| d7 | `true` always — it doesn't gate itself |
| h5 | `weeklyHasHeadroom` |
| ~~Opus / Sonnet / scoped~~ | ~~`weeklyHasHeadroom` — 7d-paced, the same weekly budget~~ → **`false`** ([ADR-0115](0115-no-blue-on-per-model-windows.md)): they **are** that week, so the advice would be addressed to itself |
| credits, idle placeholders | `false` — no pacing advice is given |

**Degrades to green, not yellow.** The 5-hour window's own pace really is calm; only the advice is
withdrawn, not the state assessment.

**Closed by default.** If the week's `resets_at` fails to parse — `false`. Otherwise the `?? now`
fallback in the bar builders would produce `timeFraction = 1.0`, i.e. "maximally behind," and would
falsely **open** the gate. `hasBrokenActiveReset` isn't suitable for this: it ignores a window with
zero usage and an empty date — exactly the cases the gate needs to close for.

The gate is computed **inside** each builder from the snapshot, rather than passed in from outside, so
the shell can't hand it an inconsistent value.

### 4. The idle pill is three-valued

| State | Fill | Label |
|---|---|---|
| `isBlocked` | gray | "waiting for limit reset" |
| has `weeklyHeadroom` | blue | "ready to start" |
| no headroom | **green** | "ready to start" |

The label between blue and green **doesn't change** — work really can start, the only difference is
whether there's anything to push. Only the "full quota available" promise is removed, which is false
when green.

The flag travels as a separate field (`LimitRow.weeklyHeadroom` / `BarView.weeklyHeadroom`): the idle
bar doesn't go through `severity` and can't read `blueAllowed` from its inert `BarLayout`.

### 5. The journal respects the gate

`PacingBucket.of` reads `layout.blueAllowed` instead of its own private constant. Its exception,
"ignore the user's setting," **narrows to `CalmColorMode`**: that's cosmetic, while `blueAllowed` is
an objective fact about the data that the journal is obligated to record.

Consequence: `sev` in the jsonl now **equals the color the user actually saw**.

> ⚠️ **This point's second paragraph was wrong and was corrected by
> [ADR-0115](0115-no-blue-on-per-model-windows.md).** It claimed that "an old discrepancy closes,
> where a scoped row could get `sev: 'blue'` even though the popup gates it via `isBaseLimit`." In
> reality, reading `blueAllowed` was necessary but not sufficient: §3 above left per-model rows with
> `weeklyHasHeadroom`, which is open whenever the week is calm — so blue kept passing through. The
> discrepancy didn't close, it got locked in: **2,214 scoped-blue** records in the August journal
> against zero on screen. Closed in #426 by moving the rule from render into the model.

### 6. Palette roles merged

`ColorRole.paceBlue` was removed — everything blue now takes `.blue`. Both roles defaulted to
`.systemBlue`, meaning they were indistinguishable on screen anyway; the split only let the tuner pull
apart something conceptually singular.

## Consequences

- **Blue became rarer and more honest.** It now means "there's headroom, *both this hour and this
  week*."
- **A gap opened in the journal's semantics.** Old rows could have `h5.sev = blue` while
  `d7.sev = red`; new ones can't. `util` / `timePct` / `gap` are unchanged, so any analysis can be
  recomputed from the row.
- **Chill-preset users** (who had `FarBehindInterval.off`) will see blue in the popup again; in the
  menu bar it's still muted by `CalmColorMode.yellowGreenBlue`.
- **`.workHarder` users** will see that with the gate closed, the bar takes the ordinary calm path and
  dims to white instead of colored blue.
- The `farBehindInterval` key is silently retired (`PersistedConfig.retireFarBehindIntervalIfNeeded`)
  — there's no legacy value to map it onto.
- The `bar-extremes` stub had to be re-fixtured (d7 31.25% → 20%): its 5h-blue is the whole reason the
  frame exists (corner radius on a full fill), and the gate would have taken it away.

## Alternatives considered

- **A dynamic width** (shrinking the threshold over time, like `aheadThreshold`) — already rejected in
  [ADR-0061](0061-far-behind-blue-pacing-zone.md): a moving blue boundary reads worse than "more than
  two hours behind."
- **A gate on the raw quota level** (e.g., "7d > 80%") — fails on the project's cross-cutting
  principle: the level is the model's input, the verdict is its output. The gate reads d7's *pacing
  state*, i.e. the model's output.
- **Smoothly scaling the width by d7's state** instead of a binary gate — unexplainable to the user
  ("blue means more than… behind, depending").
- **Only `isBlocked` as the condition** (gate only when the week is exhausted) — removes the most
  absurd case but leaves the lie in place at 7d = orange, i.e. a typical morning after an intense
  week.
- **Hysteresis at the boundary** — unnecessary: green and blue are both `isCalm`, and a flip changes
  only the color, not the behavior.
