---
status: accepted
date: 2026-07-28
supersedes: [0028, 0029]
---

# ADR-0044: A dynamic yellow→orange pacing threshold, plus a 20-minute orange override

## Context

The pacing-gap color ("ahead of plan" / ahead-of-pace) is graded by **how far** usage is ahead of
the window's elapsed time: `delta = usageFraction − timeFraction`. Until now the yellow→orange
boundary was **static** — `delta < 0.15` → yellow (a mild lead), `delta >= 0.15` → orange. This
threshold was set in [ADR-0028](0028-hide-reset-label-when-pacing-is-calm.md) (the color table) and
[ADR-0029](0029-reset-countdown-selection-by-severity.md) (the `BarLayout.severity` legend), and was
duplicated across two layers: `PopupBarView.aheadColor` (AppKit, produces an `NSColor`) and
`BarLayout.severity` (Kit, produces a `PacingSeverity`).

**The problem.** A fixed 15 points treats a lead at the start of a window the same as one near its
end. But the two situations differ: at the start of a 5-hour window, a 12-point lead is still
safe — there are hours ahead to ease off and get back on pace. The same lead 20 minutes before a
reset is already critical — there's no time left to catch up, the window is about to reset (and
you're either pinned against the limit or you've wasted quota by underusing it). A static threshold
paints both cases the same yellow, hiding the signal exactly where it matters most.

## Decision

**Make the yellow→orange boundary dynamic — it narrows as the window's time elapses — plus add an
absolute override: "≤ 20 min to reset → always orange."**

### 1. The dynamic threshold

```
threshold(timeFraction) = 0.16 · (1 − timeFraction),  clamped to [0, 0.16]
```

| Window time elapsed (`timeFraction`) | Threshold |
|---|---|
| 0% (just started) | 16% |
| 50% | 8% |
| 75% | 4% |
| 100% (the end) | 0% |

`delta < threshold` → yellow (`.calm`); `delta >= threshold` → orange (`.ahead`). The comparison is
strict (`<`, no epsilon): a lead exactly at the threshold is orange. 16 points of slack at the start
gradually shrink to zero by the end of the window.

### 2. The 20-minute orange override

If **≤ 20 min** (`1200 s`) remain until this limit's reset, and the bar is "ahead of plan"
(`usage > time`, `usage < 1`), the color is **always orange**, regardless of the formula. The
override is held in **absolute seconds**, not a time fraction: 20 min is 6.7% of a 5-hour window
but only 0.2% of a 7-day one, so it can't be derived from `timeFraction`. The rule is the same for
every window — 5h, 7d, **and** the monthly credits window (whose calendar-month end can also be
< 20 min away).

### One source for the formula

The formula lives in `PacingModel.aheadThreshold(timeFraction:)` (Kit, AppKit-free), and the
override constant is `PacingModel.pacingOrangeOverrideSeconds`. Both layers
(`BarLayout.severity` and `PopupBarView.aheadColor`) call this same helper, so color and severity
never diverge. The deliberate duplication from ADR-0028/0009 shrinks down to the comparison plus
override itself; the curve is no longer duplicated.

### The ⚠ warning band removed (the statusline is no longer the reference)

Along with the dynamic threshold, the middle rung `LimitIndicator.warning` is removed — the `⚠`
glyph that `statusText` appended to "(well) ahead of pace" when usage was > 90% and time elapsed
was ≤ 90%. This was a port of the statusline's `get_limit_indicator`; TokenPace has outgrown it —
"how far ahead of plan" is now fully carried by the bar's color (green→yellow→orange→red), so a
separate triangle duplicated the signal. `LimitIndicator` is now binary (`.critical` = limit
exhausted → "limit reached", otherwise `.neutral`), and `PacingModel.limitIndicator` no longer takes
`timePercent`. **Not to be confused** with the `⚠️` error state (a broken `resets_at` / an API
error, #167/ADR-0043) — that one stays.

### Plumbing "seconds to reset"

`BarLayout` gets a new stored field, `remainingSeconds: TimeInterval` (`resetsAt − now`), populated
in `PacingModel.barLayout(...)` and `CreditsPacing.barLayout(...)`. Inert placeholders (idle 5h)
pass `0` — their `severity` is forced to `.calm` via `.onPaceOrBehind` before the field is ever
read. The AppKit call sites (`aheadColor`, `indicatorColor`) get `remainingSeconds` from the
`BarLayout` already at hand.

## Consequences

- **A sharper signal near the end of the window.** A moderate lead turns orange earlier, when
  there's little time left to catch up — and it's always orange in the last 20 minutes.
- **The word and the color stay in sync.** "well ahead of pace" / "ahead of pace" in the popup
  (`aheadPhrase`, `creditsStatusText`) are computed via `isWellAhead`, the exact complement of `<`
  in `aheadColor`.
- **Reset-countdown visibility shifts.** `MenuBarLayout.selectReset` reads the same severity, so a
  bar that used to be yellow (calm) near the end of the window can now turn orange — and the
  countdown appears where it used to hide. This is intentional (ADR-0028/0029 hid the countdown
  precisely for "calm" bars; now "calm" itself narrows over time).
- **The `severity` rungs are unchanged in order:** `.onPaceOrBehind` → calm; `usage >= 1` →
  exhausted; then the override; then the dynamic threshold. The override never overrides "behind
  plan" or "exhausted."
- The classification tables in ADR-0028/0029 (the static `< 0.15`) no longer describe current
  behavior — see the postscripts in those entries.
