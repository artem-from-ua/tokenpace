---
status: accepted
date: 2026-08-19
supersedes: [0039]
superseded_by: []
---

# ADR-0113: "Back to work!" tracks the subscription quota, not the ability to work

> **Postscript (#416).** The strings this ADR quotes changed spelling: every surface now writes
> **`Extra usage`**, and `credits` is lowercase and plural
> ([ADR-0114](0114-extra-usage-is-one-name.md)). So the hint below reads "…get back to work. Extra
> usage credits don't count.", and the banner reads "Now using Extra usage credits." This ADR's
> decision — which predicate drives the front — is unaffected.
>
> Supersedes **the choice of signal** from [ADR-0039](0039-back-to-work-notification.md): the front
> is now `subscriptionAvailable`, not `canWork`. The rest of that ADR still stands and is
> unchanged: the persisted edge state with its "track per poll / post per toggle" split,
> quiet hours (`NotificationSchedule`, Rule A), lazy `.app`-only authorization, the pure/shell
> split. Nothing changes in [ADR-0050](0050-extra-usage-notification.md): the "Now using Extra
> Usage Credit" notification remains a separate front with a separate key.

## Context

[ADR-0039](0039-back-to-work-notification.md) chose `WorkAvailability.canWork` as the signal — a
predicate for "can I work **right now**," which counts active money credits as a path to working.
That answers the question *"am I blocked?"*

But the toggle promises something else. The maintainer stated the intent directly
([#161](https://github.com/artem-from-ua/tokenpace/issues/161)): the notification should be
**specifically about the subscription token limit resetting**, and should **not** react to the
Extra usage limit. That's the question *"has my quota come back?"* — a different one.

While Extra usage is off, both questions give the same answer. As soon as credits are enabled, they
diverge — and wrongly in both directions:

| Scenario | `canWork` | User's expectation |
|---|---|---|
| 5h/7d at 100%, credits cover the work, then the 5h resets | state was **never** blocked → no banner | banner **should** fire: the quota came back |
| Credits hit their ceiling (`spend_limit_reached`), then the credits reset | front `false → true` → banner **fires** | banner **should not** fire: the subscription is still exhausted |

The first row is silence exactly when the notification is most useful: the user is paying per
token and wants to know the moment they can stop. The second is a "Back to work!" banner in a
state where working on the subscription is exactly what you **can't** do.

The cause in both cases isn't a bug in `canWork` — it's that its question doesn't match the
toggle's promise.

## Decision

### A separate predicate, not a `canWork` edit

A new pure `WorkAvailability.subscriptionAvailable(_:)` (`TokenPaceKit`):

```
subscriptionAvailable = !CreditsPacing.mainWindowExhausted(snapshot)
```

`canWork` **stays untouched** — its question is the right one for its own consumer (the popup-badge
block, `CreditsPacing.isBlocked`). Two different questions get two different predicates, instead of
one overloaded with both meanings.

It reuses `CreditsPacing.mainWindowExhausted(in:)` — the same exhaustion predicate already behind
`isBlocked` and `canWork` itself, not a fresh check. So the red block badge and this notification
can never disagree about what counts as "exhausted": the only thing that differs is what each of
them does next with credits.

The edge cases fall out of the reuse with no special-casing — and all are covered by unit tests
(`SubscriptionAvailabilityTests`):

- **per-model / `weekly_scoped` at 100%** while the main windows are below 100% → available:
  sub-windows don't gate work ([#177](https://github.com/artem-from-ua/tokenpace/issues/177)), so
  they don't produce a false front either;
- **`sessionIdle`** (5h with `utilization: 0`) → available, an idle window means "ready to start,"
  not exhausted;
- **`spend` is never read at all** — neither `nil`, nor `enabled`, nor `spend_limit_reached`
  influence it.

### Credits stay off the signal in both directions

This consequence deserves its own mention because it's symmetric and deliberate:

- 5h/7d at 100% reads as **unavailable even while credits are actively covering the work**. Work
  doesn't actually stop — but the quota is spent, so the next reset is a genuine front.
- The credit ceiling and the credit reset **don't move the signal**, so a credit reset by itself
  announces nothing while the subscription is exhausted.

The moment of switching to paid credit has its own banner
([ADR-0050](0050-extra-usage-notification.md)), with a separate predicate
`ExtraUsageOnset.isOnCredits` and a separate key `extraUsageWasOnCredits`. The two fronts still
don't collide — they just no longer share the concept of "unblocked."

### The `backToWorkWasBlocked` key is reused without migration

A persisted `Bool` defaulting to `false`; the very first successful poll after the update
overwrites it with the new signal's value. The worst that can happen at the upgrade boundary is
**one** missed or **one** extra banner. A second key plus migration code would cost more than it
prevents.

The key name stays historical (`wasBlocked`, even though the signal is no longer about blocking) —
renaming a persisted key would require exactly the migration we're avoiding. The doc comment on
`detectBackToWorkEdge` names the mismatch explicitly.

### The Settings text

The toggle's description had to change along with the semantics: the old "If you hit a Claude
usage limit…" was too general — Extra usage is also a "usage limit," so the text was describing
something the notification no longer does.

New wording: **"If you hit your 5-hour or weekly subscription limit, notifies you when it resets so
you can get back to work. Extra Usage Credit doesn't count."** The name `Back to work` stays — it's
accurate for the new semantics too.

Along with this, the second hint line ("It best suits the *Work harder!* and *Control freak*
presets…") was removed: advice about Appearance presets doesn't explain what the toggle does, and
the three-description section read unbalanced because of it.

## Consequences

- A subscription reset is announced **always**, regardless of whether credits covered the gap.
- A credit reset is **never again** announced as "Back to work!"
- For users without Extra usage, behavior doesn't change at all — both predicates agree there.
- A new stub, `subscription-reset-on-credits` (7d at 100% with active credits → 40%), is exactly the
  front the old signal couldn't see, so it's the proof of the change. `just-unblocked` remains the
  regression stub for the base case without credits.

## Alternatives considered

- **Edit `canWork` instead of adding a new predicate** — rejected: its question is the right one for
  the popup-badge block; changing it there would break `isBlocked` and make the badge disagree with
  reality.
- **A second toggle next to the existing one** — rejected: two nearly identical switches in one
  section would force the user to tell "can I work" apart from "has my quota come back" — a
  distinction the app should make, not the person.
- **A new persisted key with migration** — rejected as an unjustified cost for preventing one
  possible extra banner at an upgrade boundary.
- **Implement [#161](https://github.com/artem-from-ua/tokenpace/issues/161) as a one-shot button in
  the dropdown** (as the issue originally phrased it) — rejected by the maintainer in session: what
  was needed wasn't a new control, but the correct semantics for the existing toggle.
