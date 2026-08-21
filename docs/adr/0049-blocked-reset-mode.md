---
status: superseded
date: 2026-07-31
superseded_by: [0063]
---

# ADR-0049: A separate `MenuBarMode.blockedReset` for the "countdown only" widget

> **Superseded by [ADR-0063](0063-unified-pause-hides-bars.md).** The "Show pacing bars when 5h/7d
> limits reached" toggle (the `hideBarsWhenBlocked` key) was merged into a single `pauseHidesBars`,
> and the hiding predicate narrowed from `mainWindowExhausted` to `isBlocked`. The
> `MenuBarMode.blockedReset` case stays in the model, but is now gated by the new key.

## Context

When a limit is exhausted (blocked), the pacing bar in the menu bar widget shows nothing useful —
it is just red at "100%". The only actionable signal at that point is **time to the nearest
reset**. The "Hide pacing bars when blocked" option (#194, default-on, opt-out) removes **both**
bars in the blocked state and leaves only the countdown.

The "blocked" state here is `CreditsPacing.mainWindowExhausted` (any main 5h/7d window at
`utilization ≥ 100`), **without** accounting for credits: even if paid credits still cover the
work, a bar at 100% carries no pacing information. This is broader than
`CreditsPacing.isBlocked` (which adds `&& !creditsCanCover`), and that is a deliberate choice by
the maintainer.

This ADR's question is **how to express "countdown only, no bars" in the `MenuBarMode` model**.
The existing `.expanded(fiveHour: BarView, sevenDay: BarView?, resetToShow: ResetToShow?)` has a
**mandatory** `fiveHour`; `sevenDay` is already optional (#94). A "no bars at all" state does not
fit into it.

## Alternatives considered

1. **Make `fiveHour` optional in `.expanded`** (`fiveHour: BarView?`) — then `nil/nil +
   resetToShow` would mean countdown-only. But this touches the entire drawing geometry on the hot
   draw path (`StatusItemView.drawExpanded` / `drawBars` / `barsBlockWidth` / vertical centering)
   and **breaks all existing expanded tests**: their helpers destructure a non-optional `five`
   (`MenuBarLayoutTests.swift`, `case let .expanded(five, …)`). Semantically, "no data for 5h" and
   "deliberately not drawing 5h" would collapse into the same `nil`, even though they are different
   things (compare `sevenDay == nil`, which already means "deliberately hidden").

2. **A new case `MenuBarMode.blockedReset(reset:which:)` (chosen).** A local, explicit variant: a
   clean new branch in the `render` switch, `itemWidth`, and no touch to
   `drawExpanded`/`drawBars`. The drawing is nearly identical to the existing "error-glyph alone"
   path — a centered monospace label. Existing expanded tests are untouched (their `.expanded`
   destructuring stays valid).

## Decision

**Added the case `MenuBarMode.blockedReset(reset: TimeToReset, which: LimitWindow)`** — "countdown
only, no bars".

- **Where it's decided (Kit).** In the base `MenuBarLayout.make(from:now:…)`, **before** branching
  into idle/active bars, behind the `hideBarsWhenBlocked` flag (threaded from `PersistedConfig`):
  if `CreditsPacing.mainWindowExhausted(in:)` **and** `BlockingReset.forBlocked(snapshot:now:)`
  yields a reset → return `.blockedReset`. `which`/format is determined by the private
  `blockedResetMode(for:now:)`: the 5h window (`.token(id: 0)`) → a live `H:MM` countdown; 7d /
  per-model / credits → compact-days (`Nd`), exactly as `selectReset` formats it.

- **A forced reset.** The countdown is shown **regardless** of `resetMode` (even `.never`),
  because without bars it is the only useful information. This is the same choice already made by
  the idle-blocked branch and the popup (all three read `BlockingReset.forBlocked`, so they stay
  consistent).

- **Fallback.** If `forBlocked` → `nil` (an exhausted window's `resets_at` fails to parse), we do
  **not** enter `.blockedReset` — we keep the normal path, where `hasBrokenActiveReset`/
  `selectReset` honestly raise a ⚠️ data error (#167, ADR-0043) instead of inventing a countdown.

- **The error path is untouched.** `usageMode` in the stale/error phase (#12) destructures the
  result of `make` as `.expanded`, to show diagnostic stale bars next to ⚠️. So
  `hideBarsWhenBlocked` is **not** threaded there (default `false`) — an exhausted-yet-stale state
  always keeps its bars.

- **Menu bar only.** The popup (`PopupLayout`) is unchanged — clicking still shows the full
  picture with bars.

## Consequences

- **Plus:** a local change, existing tests and `.expanded` geometry untouched; a clean unit-test
  point (a new `@Suite` in `MenuBarLayoutTests.swift`). The distinction between "no data" (`.error`)
  and "deliberately no bars" (`.blockedReset`) is explicit at the type level.
- **Minus:** `MenuBarMode` now has three cases instead of two — every new `switch` on `mode` (the
  view, `itemWidth`) must handle `.blockedReset`. The compiler guarantees this (exhaustiveness).
- **The option's gate** — `PersistedConfig.hideBarsWhenBlocked` (default-on), a toggle in Settings
  → Appearance → Menu Bar Widget; changing it redraws from the last poll
  (`reRenderForCurrentTime`), no restart needed.
