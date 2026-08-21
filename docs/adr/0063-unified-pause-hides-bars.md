---
status: superseded
date: 2026-08-02
superseded_by: [0090]
---

# ADR-0063: A single "Pause icon hides bars" toggle instead of two independent blocking options

> **Superseded by [ADR-0090](0090-menu-bar-answers-can-we-work.md).** The toggle is gone: hiding the
> strips under the pause icon became the single behavior, and the narrowing of the predicate to
> `isBlocked` (section "The toggle governs only the bars") was rolled back — the state "subscription
> exhausted, credits cover it" now also has no strips, with a currency glyph instead of pause. What
> still stands is the description of the pause icon itself: it is always on under `isBlocked` and
> red.

## Context

The **fully stopped** state (`CreditsPacing.isBlocked` — every main 5h/7d window exhausted **and**
paid credits do not cover it) was served by **two independent** Appearance toggles:

- **"Show pacing bars when 5h/7d limits reached"** (#194, ADR-0049) — stored inverted as
  `hideBarsWhenBlocked`; decided whether to remove both bars and leave only the countdown.
- **"Show pause icon when fully blocked"** (#199, ADR-0051) — the `showBlockedPause` gate; decided
  whether to draw the orange `pause.fill` as the leading glyph.

Two flags produced 2×2 = four combinations, of which two made sense and two were confusing: "bars
hidden, but pause off" left the widget under full stoppage showing **the countdown alone, with no
stoppage marker at all**; "pause on, bars on" duplicated the signal. There is really only one
choice a user makes under blocking: **"icon only"** versus **"icon + bars."** On top of that, the
two toggles had two **different predicates** for hide/show — hide-bars gated on the wider
`mainWindowExhausted`, while pause gated on the narrower `isBlocked` — so in the zone "window
exhausted, but credits cover it," bars were hidden even though there was no stoppage.

## Decision

**Merge into a single "Pause icon hides bars" toggle**, stored as a new key
`PersistedConfig.pauseHidesBars`.

### The pause icon — always, and **red**

When `CreditsPacing.isBlocked`, `pause.fill` is drawn **always** (no longer optional) — a full
stoppage gets an unambiguous marker. The color changed from orange to **red**: the glyph moved from
the `.orange` role to the unified `.red` role (the Palette accessor was renamed `pauseOrange` →
`pauseRed`), shared with exhausted bars and the blocking-reset pill — to distinguish "stoppage" from
the orange "ahead of plan" and to align with the red "Effective blocker" badge in the popup. The
`MenuBarLayout.blockedPause` flag remains (computed at the health-aware `make` seam: `true` when
`isBlocked` **and** `mode ∈ {.expanded, .blockedReset}`; never for `.error`), but its gating role is
removed — it is now a pure function of `isBlocked`.

### The toggle governs only the bars, on a **single** `isBlocked` predicate

`pauseHidesBars` decides only whether to hide the bars alongside the always-visible pause icon:

- **ON** → `make` returns `MenuBarMode.blockedReset(reset:which:)` — pause icon + countdown, no
  bars (the countdown is forced regardless of `resetMode`, `BlockingReset.forBlocked`, as before).
- **OFF** → `.expanded` — pause icon + bars.

The bar-hiding predicate is narrowed from `mainWindowExhausted` (ADR-0049) to `isBlocked` — the same
one that governs the icon. Consequence: while credits still cover an exhausted window
(`subscriptionExhaustedWhileCovered`), the bars are **not** hidden — work continues on the paid
tier, this is not a stoppage. Now both behaviors read the same predicate and never diverge.

### The paid-credits icon — moved to the leading position

The currency glyph (¤/€/$…) is moved from the trailing position (right of the bars, left of the
service dot) to the **leading** one: between the pause icon and the bars, in `.expanded` and
`.blockedReset` modes. It stays trailing in the diagnostic `.error` mode. Left-to-right order in the
bar modes: pause → credits → bars → countdown → (service dot rightmost). This groups all "service
state" markers on the left, and the icon no longer breaks up the bars.

### Defaults by preset + a one-time migration

Per-preset defaults for `pauseHidesBars`: **Chill** = `true` (icon only), **Work harder!** =
`false`, **Control freak** = `false`. Factory fallback (key not set) = the `.workHarder` default =
`false`.

A one-time migration, `PersistedConfig.migratePauseKeysIfNeeded()` (called from
`App.runConfigMigrationsIfNeeded`), reads the legacy `hideBarsWhenBlocked` value into the new
`pauseHidesBars` key and **clears both** legacy keys (`hideBarsWhenBlocked`, `showBlockedPause`).

## Consequences

- One meaningful choice under blocking instead of four combinations; it is no longer possible to
  land in "full stoppage with no marker at all."
- Bars are now **not** hidden while credits cover an exhausted window (the predicate narrowed from
  `mainWindowExhausted` to `isBlocked`) — a deliberate behavior change from ADR-0049.
- The pause icon is now always on under `isBlocked` and **red** (the unified `.red` role, accessor
  `Palette.pauseRed`).
- The legacy keys `hideBarsWhenBlocked` and `showBlockedPause` are removed from the config (migrated
  and cleared).
- ADR-0049 and ADR-0051 are both fully superseded by this decision.
- Menu bar only; the popup is untouched. #227
