---
status: accepted
superseded_by: [0045]
date: 2026-07-27
---

# ADR-0041: A grace period at the reset boundary — suppress the false 5h idle right after a reset

> **Partially superseded by [ADR-0045](0045-honest-reset-boundary-grace.md).** The grace mechanism
> (a gate in `PollingEngine.advance`, pure `applyIdleGrace`, `idleGraceWindow=300 s`) still stands.
> But **D3** (suppression via `sessionIdle:false` with `resets_at:""`) and **D5** (arming only on a
> `previous active`) are revised: D3 produced a "resetting…" regression plus a false 100% bar, and D5
> held the grace through real pauses and re-armed on flicker. D3′/D5′/D-rearm in 0045 are the current
> versions.

> Complements [ADR-0027](0027-session-idle-no-phantom-reset.md) (honest idle detection) and
> [ADR-0030](0030-optimistic-reset-and-exact-timer.md) (the optimistic reset). Idle detection still
> stands — this ADR only adds a short time gate on top of it.

## Context

Per [ADR-0027](0027-session-idle-no-phantom-reset.md), the 5-hour window is **created by the first
token spend**: before that, the server returns `five_hour` with no `resets_at`, and the decoder
honestly sets `sessionIdle: true`. This is correct for a genuine pause, but has a false side at the
**reset boundary**.

Observed live (logs from `process == "TokenPace"`, real data):

```
17:38:43  five_hour: utilization 71, resets_at 2026-07-27T15:40:00Z        ← active window
17:40:00  optimistic reset applied, forcing refresh                        ← the reset happened (ADR-0030)
17:40:00  five_hour: {utilization:0, resets_at:null}  → sessionIdle=true    ← the bar flickered into idle
          "five_hour idle — no active session (resets_at absent)"
17:43:12  five_hour: {utilization:14, resets_at:20:40} → active again       ← the idle disappeared on its own
```

Right after the reset, the old window is gone and the new one hasn't been created yet (no token
spend at all in the first minute or two). For about 3 minutes (≈ one poll) the server returns
`five_hour` with no `resets_at`, so the decoder — by design — reports idle. The menu bar and popup
show "waiting for limit reset" / an empty 5h bar for those ~3 minutes, even though the window was
active right up to the reset. This looks like a glitch, not a "no session" state.

The key point: idle detection is **stateless** — `UsageSnapshot.window(...)` only sees the current
body plus the injected `now`. It has no memory that the previous poll had an active window, so it
cannot distinguish a reset blip from a genuine pause.

## Decision

Add a short **grace period** (hysteresis): don't switch to idle immediately after an **active**
window; hold the "ready" bar for a while and show a genuine idle only if the window never
reappears.

- **D1. The gate lives in `PollingEngine.advance` (`.success`), not the decoder.** This is the only
  seam that has both `previous.lastSnapshot` (the pre-reset window) and the new snapshot in scope —
  the same point where `sessionIdleTransition` (ADR-0027, D6) compares the two. The decoder stays
  stateless.
- **D2. A pure helper, `applyIdleGrace(decoded:previous:activeUntil:now:)`.** Returns
  `(snapshotToRender, newDeadline)`:
  - `decoded` is not idle → `(decoded, nil)`: a stable state, any active grace is cleared;
  - `decoded` is idle, grace is armed, `now < deadline` → `(suppress(decoded), deadline)`: hold;
  - `decoded` is idle, `now ≥ deadline` → `(decoded, nil)`: the window never came back, show the
    **genuine** idle;
  - `decoded` is idle, no grace armed yet, the previous window was **active** (not idle, `resets_at`
    present) → `(suppress(decoded), now + idleGraceWindow)`: arm the grace (this is a reset blip);
  - `decoded` is idle, no grace, previous absent/idle → `(decoded, nil)`: a genuine idle from a
    cold start or an established pause is **not** suppressed.
- **D3. Suppression at the snapshot level.** `suppress(_:)` rebuilds the snapshot with
  `sessionIdle: false`, leaving the other fields as they are. Since all three render branches read
  `snapshot.sessionIdle` (menu bar, popup, coloring), one fix heals all of them. The suppressed
  window already has `utilization: 0, resets_at: ""` → it renders as an ordinary calm "ready" bar at
  0%; the empty `resets_at` parses to `nil`, so the countdown falls back to the 7-day reset — no
  phantom `resetNow`/`<1m`.
- **D4. Duration — `idleGraceWindow = 300 s` (5 min), a time deadline, not a poll counter.** Polling
  at the boundary is uneven (an optimistic reset forces an immediate `manualRefresh`, then the base
  3 min cadence resumes), so time is more reliable than "N polls." 5 minutes comfortably covers
  1–2 base polls; the maximum delay for a genuine idle is 5 minutes.
- **D5. The "reset boundary vs. genuine idle" criterion is a simple "previous active → current
  idle."** Anchoring to the exact time of `previous.resets_at` was deliberately rejected as
  unnecessary complexity: an active window that suddenly goes idle has, almost by definition, just
  passed its reset. A genuine idle typically arrives when the previous poll was **already** idle →
  the gate never arms.
- **D6. Logged once per transition.** `"five_hour idle suppressed — within reset grace"`
  (`AppLogger.network.notice`), only when `idleSuppressedUntil` transitions `nil → non-nil` — the
  same "only on change" discipline as `intervalDecision` / `sessionIdleTransition`.

## Interaction with the optimistic reset (ADR-0030)

These are two **independent** layers, not duplicates of one another:

- `fireOptimisticReset` operates at the **shell** level (it only writes to
  `AppDelegate.lastOutput`), lays an overlay over the old window (`util 0` + a synthetic `now+5h`),
  and renders immediately at the moment `t0` (when the timer fires). It does **not** touch the
  engine state (`PollState`).
- The false idle blip arrives via the next **real** poll through `advance` (moment `t1`, over the
  network). There, `previous.lastSnapshot` is the pre-reset active window (the overlay is invisible
  to the engine) → the gate arms and suppresses the blip.

So the overlay patches `t0` (the timer), and the grace patches `t1` (the poll).
`ResetClock.optimisticReset` (its idle special case) is unchanged.

## Why the log and `sessionIdleTransition` don't conflict

Since the **suppressed** snapshot (`sessionIdle=false`) is what gets written into
`next.lastSnapshot`, `sessionIdleTransition` (ADR-0027, D6) never sees an active→idle transition
during the grace period → no false active→idle→active triple happens. Once the grace expires and we
show a genuine idle, the transition honestly logs one active→idle. No change to
`sessionIdleTransition` is needed.

## Consequences

- Right after a reset, the 5h menu bar/popup no longer flicker into idle: for up to 5 minutes the
  ordinary "ready" bar at 0% is held, with the 7-day countdown.
- Genuine idle (cold start, an established pause > 5 hours) is unaffected — it arrives when the
  previous poll was already idle, so the gate never arms; the maximum delay for a true idle after an
  active window is 5 minutes.
- All of the gate's logic is a pure function (`applyIdleGrace`), covered by unit tests; the shell
  only threads the previous state through via a new field, `PollState.idleSuppressedUntil`.

See also: [ADR-0027](0027-session-idle-no-phantom-reset.md) (idle detection),
[ADR-0030](0030-optimistic-reset-and-exact-timer.md) (the optimistic reset),
[ADR-0032](0032-simplified-polling-cadence.md) (polling cadence).
