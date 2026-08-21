---
status: accepted
date: 2026-08-11
supersedes: []
---

# ADR-0078: Idle draws as zero in both styles — track + pill, marker only in Progress

> Partially supersedes [ADR-0076](0076-pressure-scale-for-marker-less-bar.md) (§"Idle distinguishes
> styles"): the idle bar **no longer** fills to full width under Progress. The rest of 0076 (the
> `pressureLength` scale, the ticks, the `Progress`/`Pressure` rename, the `rawValue` migration) still
> stands.

## Context

[ADR-0076](0076-pressure-scale-for-marker-less-bar.md) made idle style-dependent: under **Pressure**
— a minimum pill on a gray track (idle simply is zero pressure); under **Progress** — a solid,
full-width fill **plus** a time marker at zero. The argument was that the marker identifies the style,
so the fill stops being ambiguous.

In practice it stayed ambiguous. A Progress bar filled to full width visually coincides with a
Pressure bar at **full pressure** — meaning the loudest possible mark sits on the calmest state. A
marker at zero does not resolve this confusion: it is 7 pt wide and sits at the very left edge, while
what actually drives perception is the colored area — 34 pt of solid color in the menu bar. A reader
sees "the bar is full" before noticing that it has a marker at all.

The deeper problem is **consistency between styles**. `BarStyle` was designed as a render-only choice
of presentation: both styles carry the **same** state, so switching style should never change *what*
the bar says — only *how* it shows it. Idle was the one state where the styles diverged not in a
label but in the amount of ink: empty in one, a solid fill in the other. The same state read as
opposite things depending on a setting the user set for entirely unrelated reasons.

This is the same input-weight mistake CLAUDE.md warns against ("the level is the model's input, color
and the verdict are its output"): idle has zero usage, yet it drew the most ink of any state.

## Decision

**Draw idle identically in both styles — as zero.** The styles differ by the same thing they differ
by on every other bar — the presence of a marker — not by the amount of color:

- **Shared base (both styles)** — a gray track (`unusedGrey` / `monochromeGrey`), with a **minimum
  pill at zero** on top: the same shape any zero strip produces
  (`fillZone(floorEmptyToPill:)` / `pillRect(at: 0)`).
- **Progress** adds a **time marker at zero** (`timeFraction = 0` — the window has just rolled over).
  It covers the pill, so in effect Progress-idle reads as "track + a marker on the left."
- **Pressure** keeps just the pill — unchanged from 0076.

Zero is the same on both scales: `usage = 0` is zero both as a fraction of the window and on the
renormalized `[now .. reset]` track. So the shared shape here is not a compromise — it's what both
scales already produce.

The rest of idle's behavior is unchanged: color choice (`blocked` → base gray, calm → `calmWhite`,
otherwise the "ready to start" blue), the idle→active animation via `animated(…)`, the popup's ambient
glow, the ticks under the bar.

## Consequences

- **Switching `BarStyle` no longer changes how much color idle carries** — both styles show the same
  amount, differing only by the marker. This is the same rule every other bar already lives by.
- Idle can no longer be confused with Pressure at its maximum — a state that used to be the easiest
  one to misread backwards.
- `blocked` idle in Progress now draws a gray pill on a gray track, i.e. it reads as an empty track
  with a gray marker — exactly how `blocked` already behaved under Pressure. "No way to start" stays
  marked by the pause glyph and the countdown, not by the bar's color.
- The two drawing branches (`StatusItemView.drawBar`, `PopupBarView.draw`) got simpler: the branching
  on `popupUsesPressureScale` / `menuBarUsesPressureScale` is gone from the idle path, leaving a
  single marker flag.
- Kit did not change at all — `MenuBarLayout`, `BarView.idle`, `BarStyle` are the same. This is a
  render-only change, like the entire `BarStyle` line.
