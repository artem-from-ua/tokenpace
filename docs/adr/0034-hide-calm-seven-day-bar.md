---
status: superseded
superseded_by: [0086]
date: 2026-07-25
---

# ADR-0034: Hiding the calm 7d strip in the menu bar (an option, default-on)

> **Replaced by [ADR-0086](0086-tri-state-calm-bar-hiding.md).** The boolean option became a
> three-way one ("Hide the calm bar": `5-hour` / `7-day` / `Never`), so **either** of the two strips
> can be hidden, not only the 7-day one; the factory default now hides the **5-hour** one. What's
> described below still stands as a description of the `.sevenDay` mode and as decision context.

> Continues the "less noise" thread in the menu-bar widget — the same one as
> [ADR-0028](0028-hide-reset-label-when-pacing-is-calm.md) /
> [ADR-0029](0029-reset-countdown-selection-by-severity.md) (hiding the reset time) and
> [#105](https://github.com/artem-from-ua/tokenpace/issues/105) (calm colors). Reuses the same
> `BarView.isCalm` predicate.

## Context

The menu-bar widget always draws **two** stacked strips: 5h on top, 7d below
(`MenuBarMode.expanded(fiveHour:sevenDay:…)`). When the 7-day window is calm (within pace — green
on-pace/behind or mildly ahead yellow), the bottom strip doesn't carry useful signal: on a tiny icon,
two strips compete for attention even though only 5h is interesting. The "remove noise from the menu
bar" theme runs through the de-noise session
([#94](https://github.com/artem-from-ua/tokenpace/issues/94)).

`#94` proposed a broader mechanism — "show only the most important bar" (a dynamic auto-select of the
dominant window: 5h **or** 7d). We deliberately took a **narrower** approach: hide **specifically 7d**
when it's calm, leaving 5h as the always-present anchor strip. 5h is the window that bites most
often (the 5-hour cycle), so keeping it stable in place, and showing 7d only when it's genuinely
noisy (orange/red), gives "less noise" without the cognitive jump of "which of the two strips is in
front of me right now."

## Decision

### What and when we hide

- A new option `PersistedConfig.hideCalmSevenDayBar`, **default-on** (opt-out, like
  `showServiceStatusDot`): `object(forKey:) as? Bool ?? true`.
- When enabled and the 7d bar `isCalm` (`severity == .calm` — green/mild-yellow, the same predicate
  feeding ADR-0028/0029 and #105) → the 7d strip is **fully hidden**, 5h becomes the sole,
  **vertically centered** strip.
- **Orange (`.ahead`) / red (`.exhausted`) 7d is always shown** — that's precisely the noise worth
  looking at.

### Where the logic lives: Kit, not the view

`MenuBarMode.expanded.sevenDay` becomes **optional** (`BarView?`); the "hide or not" decision is made
by `MenuBarLayout.make(...hideCalmSevenDay:)` — a pure, tested function. The view (`StatusItemView`)
stays a thin shell: it sees `sevenDay == nil` → draws a single strip centered on `rect.midY`.

The motivation is consistency with ADR-0009/0028/0029: every decision about **what** to show in the
menu bar by severity already lives in Kit as pure logic (`selectReset` decides whether to show/hide
the reset label via `ResetToShow?`). Hiding a strip is a decision of the same class, and it's tested
as `#expect(seven == nil)` with no AppKit or render geometry. The alternative (a flag read by the
view directly from `PersistedConfig`) would split one family of decisions into two layers and make
the logic untestable (`PersistedConfig` is a `@MainActor` UserDefaults shell). Delivering the flag
mirrors `showServiceStatusDot`: `App.render` reads `PersistedConfig.hideCalmSevenDayBar` every time
and passes it into `make`.

### Independence from reset-time selection

`selectReset` sees the **real** severity of both windows regardless of strip hiding, so the reset
countdown doesn't change: a calm 7d that got hidden never controlled the countdown anyway (per the
ADR-0029 table, a lone calm 7d doesn't show a time). We hide only the **strip**, not the time
decision.

### Edge cases

- **Session idle** (#100, ADR-0027): a calm 7d hides the same way → only idle-5h remains, centered. A
  noisy 7d in idle is shown, with idle-5h above it.
- **Error state** (#12, ⚠️ + stale strips, 30–60 min): hiding **doesn't apply** — 7d is diagnostic
  there, so it's always shown (the error branch calls `make` with `hideCalmSevenDay: false`).
- **The item width doesn't change** — the same `barWidth`; hiding 7d only changes the vertical layout.

## Consequences

- **+** A quieter widget out of the box: a single strip when the week is on pace; 7d comes back on
  its own as soon as it turns orange/red — zero signal loss.
- **+** Pure, tested logic (the `MenuBarLayout hide calm 7d (#94)` suite, 8 cases), the view stays
  thin.
- **−** `expanded.sevenDay: BarView?` touched several pattern matches on `.expanded` (view + tests) —
  a one-time cost. The error case already had `BarView?`, so the types lined up.
- Anyone who wants both strips always visible unchecks "Hide 7-day bar when calm" (Settings → Menu
  bar widget). The `TOKENPACE_STUB=calm-both` stub demonstrates a lone centered green 5h.

## Related

- [ADR-0028](0028-hide-reset-label-when-pacing-is-calm.md), [ADR-0029](0029-reset-countdown-selection-by-severity.md)
  — the same de-noise thread, the same `isCalm`.
- [ADR-0015](0015-no-idle-mode.md) — "strips don't collapse into a glyph" still stands: here only
  **one** strip collapses (a calm 7d), 5h is always in place; this isn't an idle glyph.
- [ADR-0027](0027-session-idle-no-phantom-reset.md) — the session-idle interplay.
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — the pure/shell split (the decision
  is in Kit, drawing is in the view).
