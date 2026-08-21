---
status: accepted
date: 2026-07-26
supersedes: []
superseded_by: [0113]
---

# ADR-0039: "Back to work!" notification — the blocked→unblocked edge, quiet hours, opt-in

> Implemented in [#160](https://github.com/artem-from-ua/tokenpace/issues/160).
>
> ⚠️ **The signal choice was superseded by
> [ADR-0113](0113-back-to-work-tracks-the-subscription-quota.md)**
> ([#161](https://github.com/artem-from-ua/tokenpace/issues/161)): the edge is now
> `subscriptionAvailable` (5h/7d only, credits out of the signal in both directions), not
> `canWork`. Everything else below — the persisted edge state and the "track on every poll / post
> behind the toggle" split, quiet hours with Rule A, lazy `.app`-only authorization, the pure/shell
> split — **still stands unchanged**.

## Context

When Claude Code limits are exhausted, work is blocked — and there is no signal that it is safe to
come back. The user has to open the dropdown themselves and check whether it has reset yet.

TokenPace should **itself** send a system notification, "Back to work!", at the exact moment work
becomes possible again — without being annoying (in the spirit of
[#130](https://github.com/artem-from-ua/tokenpace/issues/130)/#134, which **removed** the
auto-update notifications).

The key difficulty is defining "when work is possible again": it is **not** "some timer hit zero",
but a transition from a "blocked" state into a "can work" state. Unblocking = both baseline windows
(5h + 7d + per-model + weekly_scoped) are no longer exhausted, **OR** they are exhausted but
money credits (extra usage, [ADR-0037](0037-extra-usage-credits-model.md)) are actively covering
work / have just reset.

Additionally, the user wants a "quiet hours" gate: an allowed hour window (respecting 12h/24h
locale and time zone) plus optional weekend suppression.

## Decision

### The `blocked → unblocked` edge, not a "timer"

A pure predicate `WorkAvailability.canWork(_ snapshot:)` (`TokenPaceKit`):

```
canWork = !anyBaseLimitExhausted(snapshot)
          || (spend != nil && isSpending(spend, baseLimitExhausted: true))
```

Reuses the existing predicates `CreditsPacing.anyBaseLimitExhausted` and `isSpending` — we don't
invent a new exhaustion check. The consequences follow from the model with no special-casing:
`spend == nil` + exhausted → `false`; `sessionIdle` (5h util 0) → not exhausted;
`spend_limit_reached` (credits at the ceiling, `enabled=false`) → `false`, and a later credits
reset → a legitimate unblock edge that `isSpending` catches.

Edge detection lives in `AppDelegate.apply`, before `lastOutput` is overwritten, by comparing the
previous and current `canWork`.

### The persisted "blocked" state

The "was blocked" state is **persisted** (`PersistedConfig.backToWorkWasBlocked`), not kept in
memory — so the edge survives an app restart (or the Mac sleeping/rebooting) between the block and
the reset, and a toggle off→on. Tracking and posting sit behind different guards:

- **Tracking happens on every successful poll, regardless of the toggle.** This keeps the state
  always current: a toggle off→on never forgets a pending edge, and never fires a false edge for a
  reset that happened while the feature was off.
- **Posting only happens when the feature is enabled**, and only when the previous successful read
  was truly blocked and the current one is workable.

Only genuine successful polls update the state: a failing/stale poll carries the last-known
snapshot (`health.failingSince != nil`), and the optimistic-reset overlay bypasses `apply` (it
calls `render`), so neither produces a false "unblocked."

### Quiet hours — an AND of two guards, Rule A for the wrap

A pure `NotificationSchedule.isAllowed(...)` (`TokenPaceKit`, with Calendar/timeZone injected). A
notification is allowed only when (the time is inside the hour window) **AND** (the day is not in
the suppress pair).

- **The hour window** is `[startMinute, endMinute)` in minutes-of-day. Non-wrap (`start < end`):
  `start ≤ m < end`. **A midnight wrap** (`start > end`, e.g. 17:00–08:00): `m ≥ start || m < end`.
  `start == end` → **the whole day is allowed** (a misconfigured picker never silently kills every
  notification).
- **Suppress days are anchored to the day the current window opened (Rule A)**, not the calendar
  day of `now`. Example — a 13:00–01:00 window, Sat-Sun suppressed: the night of Fri 13:00 → Sat
  01:00 belongs to **Friday**, so Sat 00:30 **is allowed**; Sat 14:00 and Sun 00:30 (Saturday's
  window) are suppressed; Mon 00:30 (still Sunday's window) is suppressed. This keeps the AND
  meaningful for a wrap window: a naive `weekday(now)` would suppress Sat 00:30, contradicting the
  intent. The anchor logic is isolated in one private helper.

The window's length (`windowLengthMinutes`) is a live "Nh window" hint in Settings.

### Off-by-default opt-in, lazy authorization

`backToWorkEnabled` defaults to OFF. `UNUserNotificationCenter` is a new capability (the project
had no `UserNotifications` code at all); local notifications do **not** need an entitlement or an
Info.plist key, only a valid bundle id (already present). Authorization is requested **lazily, on
first enabling** the toggle — not at launch, so users who never enable the feature are never
prompted.

### Pure/impure split

All the testable logic lives in Kit (`WorkAvailability`, `NotificationSchedule`, `SuppressDays`);
the impure `UNUserNotificationCenter` side is thin (`BackToWorkNotifier`) and is verified by hand
(ADR-0009/0023). A dev build (`swift run`, no real bundle) does not authorize — every call degrades
without crashing, and Settings shows a hint (as with launch-at-login and auto-update).

## Consequences

- The notification arrives exactly at the "can work" edge, once per cycle, and survives a restart.
- New UI controls: a Settings → Notifications section (a master switch, time pickers, a suppress
  radio group).
- Verification happens only in a real `.app`, via the `just-unblocked` stub (see
  [guides/ui-verification.md](../guides/ui-verification.md)).

## Open questions

**DND / Focus (needs verification).** Not claiming this from memory — verify against the official
macOS 15 docs before relying on it:

1. Whether macOS itself holds back delivery of a local `UNNotificationRequest` during Focus/Do Not
   Disturb (expected — yes, the banner lands in Notification Center). If so — we rely on the
   system and add nothing.
2. Whether macOS 15 has a supported public API to detect the active Focus from an app (historically
   there has been no reliable public one). If there is no detection — our hour window remains the
   only app-level guard, and DND is left to the system's delivery.

For now, only app-level quiet hours are implemented; DND is delegated to system delivery.
