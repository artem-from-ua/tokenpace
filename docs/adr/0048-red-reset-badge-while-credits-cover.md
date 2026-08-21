---
status: accepted
date: 2026-07-31
---

# ADR-0048: A red reset badge when the subscription limit is exhausted but credits are covering it

> Refines [ADR-0038](0038-idle-blocked-status.md) §D3 (the red blocking badge). That ADR showed the
> badge **only** when `isBlocked` (no path to work); here it also appears in a **non-blocked**
> state. Implemented in [#193](https://github.com/artem-from-ua/tokenpace/issues/193).

## Context

[ADR-0037](0037-extra-usage-credits-model.md) introduced extra-usage credits as the "last line of
defense": once 5h/7d is exhausted, paid credits keep covering work.
[ADR-0038](0038-idle-blocked-status.md) added a **single red badge** on the popup's reset time — but
**only** when `isBlocked`, i.e. when there is no longer any path to work
(`mainWindowExhausted AND NOT creditsCanCover`).

An in-between state went unsignaled: **5h or 7d is exhausted, but credits are actively covering
it** (`enabled`, the money cap not yet reached). Formally this is **not** blocked — work continues,
so `WorkAvailability.canWork` is `true` here, and there was no badge. But at this moment the user
**is spending money**: the subscription no longer covers the work, and they want to see **when**
the subscription limit will reset and credits will stop being drawn on.

## Decision

### D1. A new predicate, `subscriptionExhaustedWhileCovered` (Kit)

A deliberate **complement** to `isBlocked` on an exhausted main window — both start from
`mainWindowExhausted`, then diverge on credit coverage:

```
subscriptionExhaustedWhileCovered = mainWindowExhausted  AND  creditsCanCover(spend)
isBlocked                         = mainWindowExhausted  AND NOT creditsCanCover(spend)
```

Mutually exclusive — never both `true` at once. `isBlocked` is **not** widened: it stays the
inverse of `WorkAvailability.canWork` (at the time, the "Back to work!" signal had to fire
`false→true` only on a **real** unblock, not whenever credits started/stopped covering — as of #161
the notification reads a different predicate, see the postscript in "Consequences"). So the new
state is a separate predicate, not an extension of blocking.

### D2. The red badge points at the **token** limit's reset, not the credits'

When credits are covering, the credits (monthly) reset is **not** what the user is waiting for —
work keeps running on credits regardless. What unblocks the subscription is the reset of the
**exhausted token window** (5h/7d) — the moment quota returns and credit draw-down stops.

So `BlockingReset.forSubscriptionExhausted(snapshot:now:)` takes the same candidates as
`forBlocked` (every window with `utilization ≥ 100`, keyed by the popup row's index), but passes
`creditsReset: nil` — the `select` rule then collapses to "the latest exhausted token reset" (the
same choice as when credits aren't in play at all). The credits section is **never** highlighted in
this state.

### D3. Popup only; not a blocked state

- `PopupLayout.blockingReset` is now set in **two** cases: `isBlocked` → `forBlocked` (as before,
  possibly a credits reset); otherwise `subscriptionExhaustedWhileCovered` → `forSubscriptionExhausted`
  (token only).
- The view is **unchanged**: `isBlockingRow`/`makeResetBadge` already draw the red badge on
  whichever row `blockingReset` points at. The new state simply fills that field where it used to
  be `nil`.
- This is **not** blocked: the idle row doesn't turn gray, the status stays the ordinary "limit
  reached" (not "waiting for limit reset"), and the menu bar is untouched (per the maintainer's
  decision, the signal lives in the popup only).

## Consequences

- The red badge no longer equals `isBlocked`: it also appears while work continues on credits,
  marking the subscription limit's reset. This **refines** §D3 of
  [ADR-0038](0038-idle-blocked-status.md).
- `isBlocked` and "Back to work!" stay untouched — no false edge on credit draw-down.

> **Postscript (#161, [ADR-0113](0113-back-to-work-tracks-the-subscription-quota.md)).** The
> guarantee "`isBlocked` and 'Back to work!' stay untouched" is no longer a single guarantee: the
> notification detached from `isBlocked`/`canWork` and now watches `subscriptionAvailable`.
> `isBlocked` is indeed untouched (as is this ADR's decision), but "Back to work!" now fires
> **exactly** on the subscription limit's reset — the same one this ADR marks with the red badge.
> In other words, `subscriptionExhaustedWhileCovered`, introduced here, describes exactly the state
> ADR-0113 reads as "quota unavailable": the badge and the notification converged on the same
> concept from two different directions.
- Reset selection stays a single choice in Kit; the credits reset is deliberately excluded from this
  state.
- Verification: stub `TOKENPACE_STUB=credits-active` (5h 18%, 7d @100%, credits enabled/not capped)
  — in the popup, the 7-day reset row now shows a **red badge**, "5d," on an otherwise ordinary
  (not gray) row.
