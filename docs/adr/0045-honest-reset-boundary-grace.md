---
status: accepted
date: 2026-07-28
---

# ADR-0045: An honest reset boundary — a rolled-forward grace plus an activity-based trigger

> Refines [ADR-0041](0041-idle-grace-on-reset-boundary.md): changes **D3** (how to suppress) and
> **D5** (when to arm) and adds a guard against re-arming. The grace mechanism from 0041 stays; this
> ADR fixes two of its defects. Builds on
> [ADR-0030](0030-optimistic-reset-and-exact-timer.md) (a rolled-forward `resets_at`) and
> [ADR-0027](0027-session-idle-no-phantom-reset.md) (honest idle).

## Context

ADR-0041 added a grace period so the 5h bar wouldn't flicker into "no active session" right after a
reset. The implementation (D3) suppressed idle via `suppress()`, which set `sessionIdle: false`
while **leaving `resets_at: ""`**. D3's assumption — "an empty `resets_at` → a calm 'ready' bar, the
countdown falls back to the 7-day one" — turned out to be **wrong** for the current renderer:

- an empty `resets_at` in the pacing branch → `PacingModel.elapsedFraction == 1.0` → a **full-width
  green bar + "on pace"**;
- the 5h row's reset line is formatted separately (it does not fall back to 7d) → `resetLine ==
  nil` → the text reads **"resetting…"** (`PopupViewController.resetText`).

So the grace traded one visual artifact ("no session") for another ("resetting…" plus a false
100% bar). Observed live: the state persisted **longer** than 5 minutes, because on real API
`active↔idle` flicker around the reset the grace kept **re-arming** — the arming condition (0041,
D5) relied on `previous.lastSnapshot.sessionIdle`, and `advance` writes the already-suppressed
(`sessionIdle:false`) snapshot into it, so every short active blip reset the deadline and started a
fresh 5-minute grace.

Additionally: the grace armed **every time** after an active window — even when the pause was
genuine (the user had actually stepped away). This delayed the honest "ready to start" by 5 minutes
for no reason.

## Decision

### D3′ (replaces D3). `suppress()` synthesizes a rolled-forward `resets_at`, not an empty one

`suppress(_:now:)` rebuilds the 5h window with
`resetsAt = ResetClock.isoString(from: ResetClock.nextReset(now:window:.fiveHour))` — the **same**
rolled-forward `now + 5h` that `ResetClock.optimisticReset` synthesizes for the shell overlay
(ADR-0030). Consequence: during the grace, 5h shows a calm "ready" bar at 0% with an **honest
countdown** to the next reset and a natural "on pace" status (0% util at low elapsed time — the
existing pacing logic). "resetting…" is impossible, since `resets_at` is always valid and in the
future. `ResetClock.isoString` is raised to `internal`: the optimistic path and the grace now
serialize the synthesized `resets_at` the same way.

This also defuses a conflict between two layers: previously the optimistic overlay (t0) drew the
correct rolled-forward frame, which was immediately overwritten by the forced poll's result (t1)
with an empty `resets_at` (`App.apply` → `lastOutput = output`). Now both frames carry the same
rolled-forward `resets_at`, so the overwrite is seamless.

### D5′ (replaces D5). The grace arms only on a sign of recent work

The arming criterion: `prevActive && claudeActive && utilFresh`, where

- `prevActive` — the previous window was genuinely active (as in 0041);
- `claudeActive` — the `claude` CLI process is alive (already in `PollState`, ADR-0011/0032);
- `utilFresh` — the 5h `utilization` **increased** within the last `utilFreshnessWindow` (15 min).

Freshness of util is tracked by a new **in-memory** field, `PollState.lastUtilizationChange: Date?`:
`advance` stamps it to `now` on `.success` whenever util increased versus the previous poll (the
first nonzero util from a cold state counts as an increase; a reset zeroes util — that's not an
increase, so the mark survives the boundary). Not persistent: after a restart the grace has no
context anyway.

Both conditions (a conjunction): an open but idle `claude` process (no spend for > 15 min) does
**not** hold the bar — a genuine pause gets an honest "ready to start" right away. This is a
deliberate **reintroduction** of the "data-anchored" check that 0041's D5 rejected as unnecessary
complexity: practice showed that a simple boolean `prevActive` held the grace through genuine pauses
too, and the "resetting…" regression made the cost of a false grace visible.

### D-rearm (new). An active blip within the deadline does not re-arm the grace

In `applyIdleGrace`, when `decoded` is active and the grace is still within its deadline
(`now < deadline`), it now **carries the same deadline forward** instead of clearing it
(`(decoded, deadline)`). So `active↔idle` flicker can never extend the window: once the original
deadline expires, the next idle shows the honest state. The render during the blip is the active
snapshot as-is (the window really did come back) — only the deadline's persistence changes.

## Consequences

- Right after a reset, 5h never shows "resetting…" / a false 100% bar: active work → a calm
  "ready" bar at 0% with a rolled-forward countdown; a genuine pause → a blue "ready to start"
  right away.
- The grace never sticks around longer than `idleGraceWindow`, even through flicker.
- A new in-memory field, `PollState.lastUtilizationChange`, plus a wider `applyIdleGrace` signature
  (`claudeActive`, `lastUtilizationChange`); `suppress` now takes `now`. All the logic stays a pure
  function, covered by unit tests (`ApplyIdleGraceTests`).

See also: [ADR-0041](0041-idle-grace-on-reset-boundary.md) (the base grace),
[ADR-0030](0030-optimistic-reset-and-exact-timer.md) (the rolled-forward overlay),
[ADR-0027](0027-session-idle-no-phantom-reset.md) (honest idle).
