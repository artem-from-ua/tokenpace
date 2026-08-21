---
status: accepted
date: 2026-08-15
supersedes: []
superseded_by: []
---

# ADR-0102: A "stand by … for green" line — the cost of waiting out the 7-day bar

> **Refined by [ADR-0103](0103-weekly-utilization-reconstructed-from-the-five-hour-counter.md).**
> The decision still stands in full; one **prediction** in §Consequences is now outdated — that
> `standByFloorSeconds` would come into play once the quantization step dropped to ~10 min. The
> threshold did come into play, but through a different mechanism: `standBy` and the time to reset
> grow together, so the 20-minute override eats frames with a small lead, and what survives is the
> narrow band `u` 99.15–99.40%. The measurement and stub are unchanged.

## Context

The orange bar answers the question "what's wrong": more has been spent than is warranted at this
point in the window. It doesn't answer the user's next question — **what does it cost to fix this**.

The difference matters most on the weekly window. Orange on 7d lives for days, and waiting there is
a real strategy, not an abstraction. But without a number, the user either guesses the duration
blindly or ignores the signal: "slow down" without a measure isn't an action.

The check from [users-and-goals](../reference/users-and-goals.md) ("is there an action the user
would take differently") passes in **both** directions, and that matters: `stand by 40m` says
"waiting is cheap, take a break," while `stand by 2d` says "waiting it out won't work, accept orange
and plan the week." The second is an answer too, and it stops futile attempts at "slowing down a
little."

## Decision

### 1. Green is `u ≤ t`, and no threshold coefficient enters the computation

Spend only grows, and elapsed time grows on its own, so waiting gives time a chance to catch up to
frozen `u`:

```
standBy = windowDurationSeconds · (usageFraction − timeFraction)
```

**`aheadThreshold` (`0.16·(1 − t)`) plays no part here — and that's the crux of this decision.** It
is the **yellow↔orange** boundary and lives entirely on the ahead side, where
`PopupBarView.aheadColor` picks the color. Green is decided by a **different** function —
`behindColor`, on the `u ≤ t` branch — which knows nothing about `0.16` at all.

The temptation to solve the equation "wait for `severity == .calm`" is natural and **wrong**:
`PacingSeverity.calm` covers **two** colors — green (the `.onPaceOrBehind` branch) and **yellow**
(the `.ahead` branch with a lead below the threshold). That computation would land in yellow and
**understate** the advice — the line would promise green noticeably earlier than it actually arrives.

The `waitingExactlyThatLongReachesGreen` test deliberately checks `pacing == .onPaceOrBehind`, not
`severity == .calm`: the latter would pass even on an understated value.

### 2. Only the 7-day window

The 5-hour window resets at least twice in a working day — it corrects itself with no user decision
needed. The cost of waiting doesn't change anything there, so the line is limited to
`index == PopupViewController.sevenDayRowIndex`.

### 3. Only under ⌥, only on orange, and never shorter than 20 minutes

Three layers of silence, because the line is expensive: it's third in the section and shifts the
bar (§"Why silence is a valid state").

- **⌥** — an on-demand detail; at rest the section looks the way it always did.
- **Orange** — on green/blue there's nothing to wait for, on yellow the lead is within normal range,
  and on red (`usage >= 1`) waiting doesn't help at all: spend has hit the ceiling, and time can't
  catch up to it.
- **≥ 20 min** (`standByFloorSeconds`) — a shorter wait would pass before the user finishes reading
  the popup.

### 4. There's no separate "don't show near a reset" rule — it's nested inside an existing one

The requirement sounded natural: don't duplicate the reset line when green would arrive at roughly
the same time. But the computation **already** declines if green would fall within the last
`pacingOrangeOverrideSeconds` (20 min) of the window — there, the bar would still be orange because
of the override, so the promise would be false.

Since 20 min is **strictly greater** than any shorter interval, an additional 10-minute rule near the
reset wouldn't rule out **any** case: it would sit entirely inside the exclusion that already exists.
If implemented, it would be dead code.

This is a general trap, and it's worth recording: two thresholds that look independent but are
actually one nested inside the other. The `survivingWaitsAreAlwaysWellClearOfTheReset` test pins
exactly this property by exhaustively checking states, so the rule doesn't get "brought back" later
as forgotten.

### 5. The duration format is the same one used for the reset

`ResetClock.relativeRounded` was split: the band table moved into `rounded(duration:)`, which takes
a bare duration, and `relativeRounded` became a one-line wrapper. This way the line gets `45m` /
`3h` / `2d` from **the same** formatter as the reset line next to it, and the popup doesn't grow a
second time format ([ADR-0074](0074-one-reset-format-on-both-surfaces.md)).

Rounding stays **to the nearest**, as everywhere else: 36 hours reads as `2d`. This is deliberate —
a separate rounding rule just for this line would introduce a second time behavior in the same
popup.

### 6. The line carries no color

The tone is `dimmedLabel`, the same one used in the details line. The bar carries the verdict;
tinting the text would put a second, competing verdict carrier on the same line — exactly the
"raise the weight of an input" pattern the bar's rules stand against.

## Consequences

- Orange 7d under ⌥ gives **a number you can act on**, not just a verdict.
- The line stays silent in the vast majority of states — by design, not as an oversight.
- **The 20-minute floor almost never fires in practice** — and that's fine for a safeguard. The
  minimum wait consistent with orange equals the color threshold itself, `0.16·(1 − t)·D`, so it
  drops below 20 min only when the reset is under **125 min** away. And even there, the state has to
  land spend in a band **hundredths of a percentage point** wide (at 120 min remaining,
  `u ∈ [99.0000%, 99.0079%]`, i.e. 0.008 pp; at 60 min, 0.10 pp). At mid-week (`t = 50%`), even the
  faintest orange is already ≈13 hours of waiting. So the floor is a safeguard against an absurd
  "stand by 3m," not a working filter: in a typical orange state it affects nothing.
- Because of this, the stub for "the floor hides the line" (`standby-floor`) holds a **fractional**
  spend percentage: a whole percentage point of the 7-day window is **1 hour 40 minutes** of
  waiting, so states with a sub-20-minute wait simply don't exist at round numbers. This isn't a
  quirk of the fixture but a property of the source: the API returns token-window `utilization`
  **rounded to a whole number** ([usage-api-quirks](../reference/usage-api-quirks.md)), so the
  quantization step on 7d is 101 minutes of real work. A floor smaller than the step catches an
  empty set.
- `ResetClock.rounded(duration:)` is now available to any caller with a bare number of seconds — for
  future work this removes the motive to "fabricate a `Date`" just to reach the formatter.

## Alternatives considered

| Option | Why not |
|---|---|
| Solve for `severity == .calm` | Lands in **yellow**: `.calm` is green *and* yellow. The advice would understate the wait |
| Show it on 5h too | The window resets twice a day and self-corrects — the cost of waiting doesn't change the decision |
| Always show it (no ⌥) | A third line in every section costs popup height every minute, but is useful only in a narrow state |
| A separate 10-minute threshold near the reset | Nested inside the existing 20-minute check — dead code (§4) |
| A dedicated rounding rule for the wait line | A second time format in the same popup, against [ADR-0074](0074-one-reset-format-on-both-surfaces.md) |
| Color the line by severity | A second verdict carrier on the same line |
