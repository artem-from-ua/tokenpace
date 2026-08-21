---
status: superseded
date: 2026-07-24
superseded_by: [0029, 0044]
---

> **Superseded by [ADR-0029](0029-reset-countdown-selection-by-severity.md).** The binary
> `showReset:Bool` ("hide when both are calm, show the nearest when noisy") is replaced by a choice
> of *which* window's time to show, per a 5h × 7d table + a radio-group mode. The record is kept as
> historical.
>
> **The yellow→orange threshold is partially superseded by
> [ADR-0044](0044-dynamic-pacing-threshold.md).** The static boundary `(usage − time) < 0.15` in the
> color table below is replaced by a **dynamic** threshold `0.16·(1−timeFraction)` + an override of
> "≤ 20 min to reset → orange." The severity classification (green/yellow/orange/red) still stands;
> only the *number* the yellow→orange transition runs against has changed.

# ADR-0028: Hiding the reset-time label in the menu bar when pacing is calm

## Context

The menu-bar widget always drew a "time to reset" (countdown) text to the right of the bar pair
(5h on top, 7d below). When both windows are running calmly — green or yellow — that text adds only
visual noise: the user doesn't need to watch the clock while everything is fine. The countdown is
useful exactly when pacing needs attention (the bar is orange or red).

### Bar color semantics (source of truth)

The pacing-gap colors are graded by `PopupBarView.aheadColor` (the AppKit layer), shared between
popup and menu bar:

| Color | Condition (fractions [0, 1]) | "calm"? |
|---|---|---|
| green | `pacing == .onPaceOrBehind` (`usage <= time`) | yes |
| yellow | ahead && `usage < 1` && `(usage − time) < threshold` | yes |
| orange | ahead && `usage < 1` && (`(usage − time) >= threshold` **or** reset `≤ 20 min`) | no |
| red | `usage >= 1` | no |

> `threshold = 0.16·(1 − timeFraction)` — a dynamic threshold (ADR-0044). Historically this was a
> static `0.15`.

## Decision

**Hide the reset text in normal `.expanded` mode when BOTH bars are calm (green/yellow); show it as
soon as at least one turns orange or red.**

Implementation:

1. **Classification is pure arithmetic in `TokenPaceKit`.** `BarLayout.isCalm` mirrors the
   `aheadColor` thresholds: `pacing == .onPaceOrBehind || (usageFraction < 1 && (usageFraction −
   timeFraction) < 0.15)`. `aheadColor` lives in the AppKit layer, which `TokenPaceKit` doesn't
   import (ADR-0009), so the thresholds are **deliberately duplicated** here — that's the price of
   testability without AppKit. The `< 0.15` boundary is strict, with no epsilon (the same contract as
   `limitIndicator`).

2. **The decision materializes as `showReset: Bool` in `MenuBarMode.expanded`.** `reset` is always
   computed (as before) — it's just not drawn when `showReset == false`. One source of truth read by
   **both** the render (`StatusItemView.drawBars`) **and** the item width calculation
   (`barsBlockWidth`) — otherwise the label and `itemWidth` would go out of sync. `showReset` is
   tested directly at the `MenuBarLayout` level, without AppKit.

3. **Idle (ADR-0027).** `BarView.isCalm` for the idle bar is always `true` (its `layout` is inert), so
   in the idle state, the decision is made solely by the 7-day bar: `showReset = !seven.isCalm`.

4. **Only the two main windows count.** `five_hour` and `seven_day` are considered. Per-model 7-day
   limits (`weekly_scoped`: Fable, Mythos, Opus, Sonnet) **do not** affect the menu-bar countdown —
   they're model-specific, aren't drawn in the menu bar, and only live in the popup.

5. **The error mode isn't touched.** In the 30–60 minute stale phase (`.error` with bars, issue #12)
   the countdown is part of the diagnostics, so `showReset` is always `true` there.

## Consequences

- Less noise in the menu bar in the typical "everything is fine" state: just two bars.
- The countdown returns automatically as soon as at least one of the two main windows enters the
  orange/red zone — exactly when time-to-reset becomes relevant.
- The item's width dynamically shrinks/expands along with the text's appearance (as with other
  modes).
- The `aheadColor` ↔ `BarLayout.isCalm` threshold duplication — both places need to be kept in sync;
  this is recorded in doc comments in both.

## Verification

`swift build && swift test` (513 tests, including `BarLayout.isCalm` and `MenuBarLayout showReset`),
plus running the app under three stubs (`TOKENPACE_STUB`):

- `screenshot` (5h green + 7d yellow) → text hidden;
- `1` climbing (7d orange) → text shown;
- `idle` (blue 5h + 7d green) → text hidden.
