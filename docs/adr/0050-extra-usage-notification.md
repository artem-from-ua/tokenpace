---
status: accepted
date: 2026-07-31
---

# ADR-0050: The "Now using Extra Usage Credit" notification — the not-spending→spending front, shared infrastructure with ADR-0039

> ⚠️ **This ADR's decision still stands in full** — the `isOnCredits` predicate, a separate
> `extraUsageWasOnCredits` key, shared authorization and quiet hours, a body with amount+limit, the
> "Try" button. Only the section **"Coexistence with 'Back to work!'"** below is stale: it
> describes the neighboring notification's signal, which
> [ADR-0113](0113-back-to-work-tracks-the-subscription-quota.md) replaced (`canWork` →
> `subscriptionAvailable`). The current coexistence story is in that section's postscript.

## Context

When Claude Code's base limit is exhausted and the user has enabled Extra Usage Credit, work
**silently** spills over onto the paid credit — real money is spent with no signal at all.
TokenPace should send its own system banner at the exact moment of that switch, with the
**current amount spent** and the **limit** (if set) in the body.

This mirrors the "Back to work!" notification ([ADR-0039](0039-back-to-work-notification.md)): the
same pattern of "a front between polls + a persisted edge-state + quiet hours + opt-in +
`.app`-only authorization", but a **different** transition. The key question is which signal
exactly, and how it coexists with `WorkAvailability`.

## Decision

### The `not-on-credits → on-credits` front, not "balance crossed a threshold"

A pure predicate `ExtraUsageOnset.isOnCredits(_ snapshot:)` (`TokenPaceKit`):

```
isOnCredits = spend != nil
           && mainWindowExhausted(snapshot)
           && isSpending(spend, baseLimitExhausted: true)   // enabled && !spend_limit_reached
```

Reuses the existing predicates `CreditsPacing.isSpending` + `CreditsPacing.mainWindowExhausted` —
no new check is invented. **`mainWindowExhausted`** is deliberately chosen (only 5h/7d, which
actually gate work) over `anyBaseLimitExhausted` (which counts per-model sub-windows, for the
**icon**): a per-model cap by itself does not spill over onto credits (#177), so taking the
broader exhaustion would produce a false onset.

### Coexistence with "Back to work!"

The two fronts **do not** collide: `WorkAvailability.canWork` fires on `blocked → workable`, while
`isOnCredits` fires on `not-spending → spending-on-credits` (a state that is already "workable",
because `isSpending` is part of `canWork`). These are different transitions of different states —
one banner describes "the limit reset", the other "started paying". At the ceiling
(`spend_limit_reached`), `isSpending` = false → that is the "Back to work" domain (blocking), not
this one.

> **Postscript (#161, [ADR-0113](0113-back-to-work-tracks-the-subscription-quota.md)).** The
> paragraph above describes a signal that no longer exists: "Back to work!" now watches
> `subscriptionAvailable` (`!mainWindowExhausted`), not `canWork`. What's substantively changed:
>
> - **The "different states" argument is no longer needed, because the states no longer overlap by
>   construction.** Previously the non-collision was proven by `isOnCredits` living inside
>   "workable"; now the signals simply read different things — one the subscription, the other
>   credits.
> - **Both banners can concern the same stretch of time — and that's fine.** 5h/7d at 100% with
>   active credits: `isOnCredits` gives "started paying" on entry, `subscriptionAvailable` gives
>   "quota is back" on exit. They describe the beginning and end of the same episode, not a
>   duplicate of each other.
> - **The last sentence of the paragraph is now false.** The credits ceiling
>   (`spend_limit_reached`) no longer belongs to the "Back to work" domain: neither it nor the next
>   credits reset moves `subscriptionAvailable`.
>
> A separate edge-state (`extraUsageWasOnCredits` versus `backToWorkWasBlocked`) remains the right
> decision — now for an even clearer reason.

### Shared infrastructure, separate edge-state

- **Authorization** `UNUserNotificationCenter` — **one** `[.alert, .sound]` permission for both
  notifications; requested lazily on first enabling of **either** one (a shared
  `onBackToWorkEnabled` callback).
- **Quiet hours** — the same `NotificationSchedule.isAllowed` (an hours window + suppress days),
  factored into a shared `AppDelegate.notificationsAllowedNow()`. The Settings rows "Allowed
  hours" / "Suppress on weekends" moved into a **separate "Schedule" section**, which is **always
  visible and active** (even when both notifications are disabled) — the schedule can be
  configured ahead of time; it gates both notifications the same way.
- **Posting** — a generalized `BackToWorkNotifier.post(kind:idPrefix:title:body:)`;
  `postBackToWork()` and a new `postExtraUsage(body:)` are thin wrappers. The extra-usage body
  carries amount+limit, so posting accepts a dynamic `body` (unlike the fixed back-to-work one).
- **The "Try" button** (as in back-to-work, #193) — next to the toggle, **always active** (even
  when the feature is disabled): forces the banner immediately, bypassing edge detection and quiet
  hours; the body takes amount/limit from the latest snapshot (`onTryExtraUsage` in the shell reads
  `lastOutput.spend`), or a generic string if `spend` is absent. Posting itself gates on
  support+authorization, so without permission it's a silent no-op. The Settings toggle is called
  **"Switching to Extra Usage"**; the banner title is **"Now using Extra Usage Credit"**.
- **Edge-state** — a **separate** persisted key `PersistedConfig.extraUsageWasOnCredits` (not
  shared with `backToWorkWasBlocked`, because these are different states). As with that one: it
  updates on every poll independently of the toggle (off→on doesn't forget a pending edge and
  doesn't fire stale), and posting is gated by `extraUsageNotifyEnabled`.

### The banner body — exact money, the same format as the dropdown

`ExtraUsageOnset.bannerBody(for:)` (Kit) formats amount+limit from **whole** `Money`
(`amount_minor / 10^exponent`), falling back to `extra_usage.used_credits` when `spend.used` is
absent. Currency symbol rules mirror `PopupViewController.moneyText` (known currencies — symbol in
its position; unknown ones — ISO code). The formatter is **duplicated** in Kit deliberately: the
popup version is `static` on the AppKit view controller (the executable target), not importable;
the maintainer's rule is to keep a clean copy in Kit for unit tests. Both copies must stay in sync
(a shared known-currency set).

### The pure/shell split ([ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md))

All the logic (the signal + the text) lives in `TokenPaceKit` (`ExtraUsageOnset`), fully unit
covered (`ExtraUsageOnsetTests`: 7 signal cases + 6 format cases). Side effects
(`UNUserNotificationCenter`, edge detection in `AppDelegate.detectExtraUsageEdge`) live in the
executable target, verified by hand.

## Consequences

- Default-OFF (opt-in), like back-to-work — no banner at all until the user enables it (and grants
  permission). On a dev build (`swift run`) the toggle is disabled and forced off (authorization is
  not possible).
- Verification — the `TOKENPACE_STUB=credits-onset` stub (first poll not on credits → 7d=100% with
  credits enabled) on the installed `.app`; details in
  [docs/guides/ui-verification.md](../guides/ui-verification.md).
- DND is delegated to the system (as in ADR-0039).

## Alternatives considered

- **Extend ADR-0039 instead of a new ADR** — rejected: ADRs are immutable, and this contains
  genuinely new decisions (choosing `mainWindowExhausted`, a separate edge-state, generalizing the
  notifier).
- **Notify on every change in amount** — rejected: annoying; the signal is specifically the
  **moment of the switch**, one banner per front (the current amount lives permanently in the
  dropdown, ADR-0037).
- **A shared edge-state with back-to-work** — rejected: different states; merging them would
  produce false or missed fronts.
