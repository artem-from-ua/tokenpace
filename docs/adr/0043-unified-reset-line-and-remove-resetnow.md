---
status: accepted
date: 2026-07-27
supersedes: [0030]
superseded_by: [0091]
---

# ADR-0043: A unified "time to reset" line in the dropdown, plus removing `.resetNow`

> **Partially superseded by
> [ADR-0091](0091-countdown-only-where-work-is-not-running.md).** The rule "a broken `resets_at` →
> ⚠️ instead of the strips" survives, but the path to it is different: an **exhausted** window with
> a broken date no longer falls through to the strip path but produces a separate case,
> `MenuBarMode.exhaustedUnknownReset` — a **lone ⚠️**; `ResetSelection` was removed along with
> `selectReset`. `ResetClock.resetLine` and the removal of `TimeToReset.resetNow` still stand.

> Replaces decision **D5** of [ADR-0030](0030-optimistic-reset-and-exact-timer.md)
> ("`.resetNow` stays as a safety net"): the case is now **removed**, and its three sources are
> resolved explicitly (see below).

## Context

The dropdown showed "time to reset" **differently** for different limits:

- **Token windows** (5h / 7d / per-model) — `resetText(_ row:)`: `20m at 05:30`, `3d on Monday`. An
  absolute time when `< 24 h`, a weekday when `≥ 24 h` (7d only), a hard 24 h threshold.
- **Extra usage (credits)** — a separate branch: only a relative `6d`, no absolute day/time.

Issue #167 asked for an absolute day/time for credits when the reset is near. In the process, the
maintainer expanded the scope to **one unified format for every dropdown limit** and to removing
the intermediate state `TimeToReset.resetNow`, which masked **two different** situations behind
the same fake `<1m`:

1. the reset **has already passed** (`remaining ≤ 0`) — this should roll forward to the **next**
   reset instead of showing `<1m`;
2. `resets_at` **is missing / doesn't parse** — this is an **API error**, and should be shown as an
   error (⚠️), not a fake countdown.

The credits reset is deterministic — `00:00 UTC on the 1st of next month`
(`CreditsPacing.monthEnd`), so the absolute date is computed locally; the weekday/time are in the
**local** time zone.

## Decision

### D1. A single `ResetClock.resetLine` for the whole dropdown

One pure function assembles the **whole** line from a table of zones (keyed on the actual
`remaining`), used by **both** token windows and credits:

| Remaining | Line | Example |
|---|---|---|
| `> 7 d` | `Nd` | `15d` |
| `6 d < r ≤ 7 d` | `Nd next <weekday>` | `7d next Monday` |
| `24 h < r ≤ 6 d` | `Nd on <weekday>` | `5d on Friday` |
| `r ≤ 24 h` | `Nh at <time>` / `Nm at <time>` | `20h at 03:00` |
| `r ≤ 0` | `nil` (shell → `resetting…`) | — |

- `N` is the rounded number from the existing `relativeRounded` (we don't duplicate the
  arithmetic).
- `<weekday>` is the English name (`Monday`), locale-**independent**, in the **local** time zone.
- `<time>` is a local `HH:MM`, locale-**dependent** 12/24h.
- The thresholds are on `remaining` (seconds); `N` rounds independently, so a slight mismatch at
  the boundaries is possible (e.g. `6d 20h` → the "next" zone, `N` → `7d`) — acceptable.
- `LimitRow`/`CreditsRow` now carry **one** field, `resetLine: String?`, instead of three
  (`resetRelative`/`resetAbsolute`/`resetWeekday`); the shell just falls back to `resetting…` on
  `nil` (with no `resets in` prefix). `absoluteWithin`/`weekdayBeyond` are removed (`resetLine`
  replaces them).

### D2. `remaining ≤ 0` → roll forward to the next reset (not `<1m`)

Rolling forward is already implemented by `ResetClock.optimisticReset` (ADR-0030 D2) plus the exact
`resetTimer`. To close a sub-second **timer race** (a render from `ageTimer`/a poll tick could land
between "the deadline passed" and "the timer rolled forward"), `optimisticReset` is now applied
**on every render** (`AppDelegate.render`), not only when the timer fires. So `remaining ≤ 0` never
reaches the formatter in the normal flow; on purely degenerate input `timeToReset` returns a safe
`.relative("<1m")` with no separate state.

### D3. A broken `resets_at` on an active window → an API error (not `<1m` / not `resetting…`)

A **non-empty but unparseable** `resets_at` on a window with real usage (`utilization > 0`) is a
malformed 200 body, so it's handled like any other API error, **symmetrically in the menu bar and
the popup**:

- **menu bar** → **⚠️ instead of the pacing strips** (the same `.error` mode and
  `exclamationmark.triangle` used for staleness);
- **popup** → **just the red warning banner** (`FailureReason.serverProblem`), with **no** limit /
  credits / blocking-reset rows at all. Unlike a *health* error (where the stale rows from the last
  **good** snapshot are still worth showing), here it's the **current** snapshot itself that's
  malformed, so there's nothing to render — the same shape as a cold-start failure (empty `rows` +
  a banner).

The single source of truth for the check is `UsageSnapshot.hasBrokenActiveReset` (Kit), used by
**both** layouts: `MenuBarLayout.make` promotes to `.error`, `PopupLayout.make` sets `warning =
.serverProblem`. `MenuBarLayout.selectReset` additionally returns a `ResetSelection`
(`.hide` / `.show` / `.dataError(window)`) as a defensive guard.

**What is NOT an error:** (a) an **empty/`null`** date — that's a boundary/synthesis state, not a
malformed value; (b) **zero usage**; (c) **session-idle 5h** (ADR-0027: no active session — its
`resetsAt` is empty). So an error is produced only by a **non-empty, unparseable** date on a
**used** window.

### D4. The `TimeToReset.resetNow` case is removed

`enum TimeToReset` now has only `.absolute` / `.relative`. The old `.resetNow`'s three sources are
resolved above: `remaining ≤ 0` → D2 (roll forward), a broken `resets_at` → D3 (⚠️), the error-branch
fallback → `reset: nil` (no countdown). This **replaces D5 of ADR-0030**, whose justification was
purely "a cheap safety net," with no product rationale.

## Consequences

- The dropdown shows one "time to reset" format for every limit, including credits; the `resets in`
  prefix appears nowhere.
- The menu bar never again shows a fake `<1m` for a past reset (it rolls forward) or for a broken
  date (⚠️, as a genuine error).
- `TimeToReset` simplifies to two cases; `selectReset` explicitly distinguishes "hide" / "show" /
  "data error."
- `optimisticReset` is now a render-time invariant, not just a timer event — no race produces a
  "reset now" placeholder.

Verification — dropdown stubs at various remaining times (credits `>7d`/`7d`/`5d`; token
`<24h`/`<1h`), local day/time (not UTC 00:00), and a menu-bar stub with a broken `resets_at` → ⚠️.

See also: #167, [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) (the pure/shell split
— the line is assembled in kit), [ADR-0006](0006-reset-time-absolute-vs-relative.md)
(`TimeToReset`), [ADR-0027](0027-session-idle-no-phantom-reset.md) (idle-emptiness, reconciled in
D3), [ADR-0029](0029-reset-countdown-selection-by-severity.md) (reset selection, extended by
`ResetSelection`), [ADR-0030](0030-optimistic-reset-and-exact-timer.md) (rolling forward; D5
superseded), [ADR-0037](0037-extra-usage-credits-model.md) (the credits model).
