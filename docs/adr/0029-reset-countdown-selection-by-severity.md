---
status: superseded
date: 2026-07-24
supersedes: [0028]
superseded_by: [0042, 0043, 0044, 0091]
---

# ADR-0029: Selecting the reset time in the menu bar by 5h × 7d states + a radio-group mode

> **Superseded by [ADR-0091](0091-countdown-only-where-work-is-not-running.md).** The countdown now
> lives only in barless states, so there's nothing left for the 5h × 7d selection table to choose
> from: `MenuBarLayout.selectReset`, `ResetSelection`, `ResetToShow`, the
> `MenuBarMode.expanded.resetToShow` field, and the mode itself, `ResetCountdownMode` (along with the
> Settings option "Show reset countdown"), are removed.

> **The yellow→orange threshold is partially superseded by
> [ADR-0044](0044-dynamic-pacing-threshold.md).** The severity legend below (ahead `< 15` pts / ahead
> `>= 15` pts) described a static threshold of `0.15`; it's now a **dynamic**
> `0.16·(1−timeFraction)` + an override of "≤ 20 min to reset → orange." The reset-time selection
> table by severity still stands — only the *gap* at which a bar becomes orange has changed.

> **Partially revised by [ADR-0042](0042-settings-swiftui-form.md) (#168):** the `hideDistant7d` mode
> is removed, along with the "Include distant 7-day limit reset" checkbox. `ResetCountdownMode` now
> has three variants — `always` / `smart` (formerly `showDistant7d`, in Settings "When pacing well
> ahead or limit reached") / `never`; the days-away ahead-of-pace 7d countdown is shown whenever the
> countdown is shown at all (`showsSevenDayAheadWhenFar`). The severity-based selection table (below)
> still stands; mentions of `showDistant7d`/`hideDistant7d`/`showsDistantAhead7d` in the body are
> historical.

> **Postscript (2026-07-27, [ADR-0043](0043-unified-reset-line-and-remove-resetnow.md), #167):**
> `selectReset` now returns a `ResetSelection` (`.hide`/`.show`/`.dataError`), not a `ResetToShow?`.
> The implementation item "a broken/nil `resets_at` on the selected noisy bar → ⏰ (`.resetNow`)" is
> replaced: that case now becomes `.dataError`, and the menu bar is promoted to the ⚠️ error state
> (like any other API error), rather than showing a fake countdown. "Both calm with no valid dates →
> nothing" still stands (`.hide`). The 5h×7d selection table is unchanged.

Supersedes [ADR-0028](0028-hide-reset-label-when-pacing-is-calm.md), which only made the binary
decision "hide when both bars are calm."

## Context

ADR-0028 hid the countdown when both bars were calm, and showed the **nearest** reset as soon as at
least one turned orange/red. This answered "whether to show," but not "**which** time exactly to
show." The nearest reset isn't always useful: if 5h is exhausted (red) and resets in an hour, but 7d
is also exhausted and resets in two hours, showing "1h" is misleading, because the service stays
blocked until the second one anyway.

We need to choose the time that corresponds to the **next real relief from being blocked**, and give
the user a mode to control showing the distant 7d time and to restore the classic "always show."

### Bar severity semantics (source of truth)

Inherited from ADR-0028; now codified in `BarLayout.severity` (Kit, AppKit-free), mirroring
`PopupBarView.aheadColor`:

| severity | Color | Condition | blocked? |
|---|---|---|---|
| `.calm` | green / yellow | `usage <= time`, or ahead `< 15` pts (`usage < 1`) | no |
| `.ahead` | orange | ahead `>= 15` pts, `usage < 1` | no (ahead of plan) |
| `.exhausted` | red | `usage >= 1` | yes (limit exhausted) |

## Decision

**Choose which window's time (5h or 7d) to show — or hide it — via a 5h × 7d state table, controlled
by the `ResetCountdownMode` mode.** Principle: show the time of the *next real relief from being
blocked*.

### The table (Show/Hide modes)

| 5h \ 7d | 7d calm | 7d orange | 7d red |
|---|---|---|---|
| **5h calm/idle** | nothing | 7d time ⃰ | 7d time (always) |
| **5h orange** | 5h time | earlier one (both orange) | 7d time (red blocks) |
| **5h red** | 5h time | 5h time (red blocks) | later one (both red) |

⃰ the gate applies only to **orange-7d**: mode `showDistant7d` shows it; `hideDistant7d` only shows
it if the 7d reset is `< 24 h` away. 7d **red** is always shown. (In practice, orange-7d with a reset
`< 24 h` away is nearly unreachable — with the 7d reset close, the window has almost elapsed, so
`usage > elapsed + 0.15` would require `usage ≈ 1` → red. So `hideDistant7d` effectively hides all
orange-7d.)

### Modes (`ResetCountdownMode`, a radio group under Settings → "Menu bar widget")

| Mode | "both calm" | "orange-7d distant, 5h calm" | rest of the table |
|---|---|---|---|
| `always` | **nearest** | shown | as the table |
| `showDistant7d` *(default)* | nothing | shown | as the table |
| `hideDistant7d` | nothing | hidden | as the table |
| `never` | nothing | nothing | **nothing everywhere** |

`always` = default + "both calm" shows the nearest (⇒ never empty); `never` = always empty.
Parameterized by two mode flags (`showsWhenBothCalm`, `showsDistantAhead7d`).

### Implementation

1. **`BarLayout.severity`** (`PacingModel.swift`, Kit) — a three-state calm/ahead/exhausted;
   `isCalm` is derived. `BarView.severity` threads through idle (idle → `.calm`).
2. **`ResetCountdownMode`** (Kit, raw-`String`, forward-compatible like `WebDesktopMode`).
3. **`ResetClock.latestReset`** — the mirror of `nearestReset` for "both red → the later one."
4. **`MenuBarLayout.selectReset`** — the pure function that is the source of the table; format: 5h →
   `timeToReset`, 7d → `timeToResetCompactDays` (compact days). A broken/nil `resets_at` on the
   selected noisy bar → ⏰ (`.resetNow`); both calm with no valid dates → nothing.
5. **`MenuBarMode.expanded`** carries `resetToShow: ResetToShow?` (nil = hide), instead of
   `reset`/`which`/`showReset`. `make(…:resetMode:)` calls `selectReset` (active + idle).
6. **Shell.** `PersistedConfig.resetCountdownModeMenuBar` (default `.showDistant7d`) + a 4-way radio
   group; `StatusItemView` draws `resetToShow` (nil → no label/width).
7. **Error mode** (30–60 min stale) — the countdown is always the **nearest** (diagnostics); the mode
   has no effect.

## Consequences

- The countdown answers "when will it ease up next," not just "the nearest reset."
- The user controls showing the distant 7d time and can restore "always"/turn it off entirely.
- `MenuBarMode.expanded` gets simpler (one optional field instead of three).
- The `aheadColor` ↔ `severity` threshold duplication remains (the same reason as in ADR-0028) — now
  in one place (`BarLayout.severity`), from which `isCalm` is derived.

## Verification

`swift build && swift test` (`BarLayout.severity`, `MenuBarLayout.selectReset` across every cell ×
4 modes). Live (`TOKENPACE_STUB`): new frames `both-red` (→ the later one = 7d "4d"),
`red-orange` (→ the red bar's time = 5h), `5h-orange`, `both-orange`; the existing
`screenshot`/`idle` (both calm → empty in default, nearest in `always`); toggling all 4 modes in
Settings.
