---
status: accepted
date: 2026-08-18
supersedes: []
superseded_by: []
---

# ADR-0107: The weekly reset is reconstructed from the last known one, not estimated from the clock

> Supersedes decision **D5** from [ADR-0027](0027-session-idle-no-phantom-reset.md) — its
> justification ("the weekly window always exists") is disproven by measurement. The rest of
> ADR-0027 still stands.

> The measured properties of the API itself live in
> [docs/reference/usage-api-quirks.md](../reference/usage-api-quirks.md), in the section on the
> weekly blackout. This ADR records **the decision and why**.

## Context

Every week, at the moment of the weekly reset, the usage API stops returning
`seven_day.resets_at`: the object itself arrives `null`, and the `weekly_all` entry in `limits[]`
also comes back **with no date of its own** — both sources disappear at the same moment. The state
holds until the first token spend materializes a new 5-hour session.

Measured on two independent journals (August 2026):

| Series | `d7` entries | Episodes | Duration |
|---|---:|---:|---|
| Max 5x | 5,029 | 3 | 264, 253, 306 min |
| Pro | 862 | 2 | 611, 54 min |

That's **4–6 hours every week**, ~4% of all entries.

For all of that time, `UsageSnapshot.window(...)` fell back to a local estimate,
`ResetClock.nextReset` = `now + 7d`, rounded up to 10 minutes. The estimate was recomputed **on
every poll**, so it crept forward with the clock:

```
11:32  reset = 2026-08-25T11:40:00   timePct = 0
11:41  reset = 2026-08-25T11:50:00   timePct = 0
11:50  reset = 2026-08-25T12:00:00   timePct = 0
12:17  reset = 2026-08-25T06:59:59.764448+00:00   timePct = 0.0315   ← the real one arrived
```

Consequence: `remaining >= duration` always held, `PacingModel.elapsedFraction` returned exactly
`0.0`, and the time marker sat pinned to the left edge for hours. Then the real value arrived — and
the marker jumped.

**The correct answer was known the whole time.** At 06:59:54 the app was holding the real reset,
`2026-08-18T07:00:00.306761+00:00`, in its hands; at 07:00 it threw it away for an estimate.

### Why the earlier decision didn't work

[#100](https://github.com/artem-from-ua/tokenpace/issues/100) describes **exactly this same**
defect — a synthesized time that "creeps," and a false "on pace" at 0%. But the fix only covered
`five_hour`; the `seven_day` branch was left deliberately, by decision **D5** of ADR-0027, on the
grounds that "the weekly window always exists."

The data disprove this: in terms of the API response, it does **not** always exist — exactly like
the 5-hour one. But even if it did exist, the conclusion should have been the opposite: if a window
always exists, its boundary should be **remembered**, not re-estimated every time.

### The reset grid is regular

| Series | Day of week | Time UTC | Intervals |
|---|---|---|---|
| Max 5x | Tuesday | 07:00:00 (jitter ±1 s) | exactly 7 days |
| Pro | Wednesday | 21:00:00 (jitter ±1 s) | exactly 7 days |

Different plan tiers have **different** grids, but each is stable. So "the last real reset + N
weeks" isn't a guess — it's reproducing that same grid.

## Decision

### 1. Reconstruct from an anchor, not estimate from the clock

`ResetClock.rollForward(anchor:by:until:)` rolls the last **server** reset forward by a whole number
of periods until it lands in the future. The error on live data is **±0.25 s** (versus minutes for
the old estimate).

Measured by replaying both journals:

| Series | Reconstructible | Max error |
|---|---:|---:|
| Max 5x | 199 of 199 | 0.249 s |
| Pro | 56 of 56 | 0.246 s |

### 2. Arithmetic on `TimeInterval`, never `Calendar`

A `Date` is an absolute instant with no time zone, and UTC has no transitions, so `+604,800 s` added
to `Tuesday 07:00:00 UTC` always gives `Tuesday 07:00:00 UTC`.

`Calendar.date(byAdding:)` respects `timeZone` (defaulting to `.current`), and on the night of a
DST transition a day lasts 23 or 25 hours — which would introduce an hour's shift. The test
`wholeWeeksAreUnaffectedByADaylightSavingTransition` pins this decision explicitly, because the
difference isn't visible at a glance.

The step is computed with a **closed-form formula**, not a loop: a month-long vacation and a
two-year one cost the same single multiplication, and a broken anchor can't cause an infinite loop.

### 3. A 60 s `resetGrace` tolerance — not cosmetic

The server reports the reset with microsecond precision, and the first poll after it regularly lands
**within the same second**. At that point the anchor is formally still in the future (by 0.31 s),
the "hasn't happened yet" branch returns it as is, and the bar shows "reset in 0.3 s" — the marker
pinned to **one**, worse than today's zero.

| Tolerance | Max error |
|---|---:|
| `0` | **604,800 s** (exactly a week) |
| `1 s` | 0.249 s |
| `60 s` | 0.249 s |

The trap fired in **two of three episodes** on Max, and in both on Pro — a pattern, not a
coincidence.

### 4. The anchor is never taken from its own output

It's written only from a snapshot whose `sevenDayResetSource.isUnrolledServerFact` — that is,
`server` or `limits`. A reconstructed or locally rolled-forward value never **becomes** an anchor:
otherwise every poll during a blackout would build on an estimate of the previous one, and the error
would accumulate over hours.

This is exactly why the anchor lives in `PollState` rather than being read from `lastSnapshot` —
which may contain our own reconstruction.

### 5. Persisted under its own key

`PersistedConfig.lastSevenDayReset`, as an ISO-8601 string. A blackout lasts 4–6 hours, and the app
restarts during it: the August 4th journal shows **five polling pauses**, the longest 104 minutes.
An in-memory-only anchor would vanish exactly when it's needed.

A string, not an epoch or a blob: one date format for the whole app (`ResetClock.parse` /
`isoString`), and the value stays readable in `defaults read` — which matters for what gets
inspected during a live episode.

### 6. With no anchor — nothing is invented

A cold start (a fresh install, no spend yet) gives `resets_at: ""` and `ResetSource.unknown`. Both
surfaces show this directly: the menu bar shows a "no data" symbol, the popup shows **no limit** at
all plus two lines of explanation.

The rows are hidden rather than drawn partially, because emptiness **cascades**: per-model windows
(Fable, Opus, Sonnet) inherit the weekly reset, and `elapsedFraction` on an unparseable date returns
`1.0` — every row would draw a marker pinned to the right edge. Four confident "the week is spent"
claims from a snapshot that says nothing has been spent.

**Not `FailureReason`.** That enum is a taxonomy of polling failures, and here polling succeeded:
`200` and a well-formed body. The `.serverProblem` label would show "Usage API unavailable" and send
the user off to check their network, when the actual fix is to start working.

**Not ⚠️.** Per [ADR-0091](0091-countdown-only-where-work-is-not-running.md) that symbol means
exactly "the data contradicts itself." There's no contradiction here: the server consistently says
the weekly window doesn't exist yet, and that's true until the first spend.

### 7. Two source axes in the journal, not one

`src` is renamed to `utilSrc`; `resetSrc` appears alongside it. "Source" stopped being a single
answer the moment the **date** started being reconstructed too.

The axes are orthogonal — proven by the data, not by reasoning. Across 5,029 entries, **six of
eight** intersections are populated:

| `utilSrc` \ `resetSrc` | server | estimate → `reconstructed` |
|---|---:|---:|
| `interpolated` | 4,510 | **193** |
| `clipped` | 220 | 0 |
| `degraded` | 84 | **6** |
| `inherited` | 16 | 0 |

The most telling one is `degraded × reconstructed` (6 entries, August 4th): the percentage degraded
because of a 104-minute gap in polling, while the date was invented because the API stayed silent.
**Two different causes on the same row** — one field would have had to choose which story to tell.

The `resetSrc` value is composite: a base plus an optional `-rolled` suffix
(`reconstructed-rolled` = we derived the date, and it has already elapsed). `rolled` is always the
last link in the pipeline, so there's no combinatorial explosion.

### 8. `optimisticReset` moved onto the same arithmetic

`ResetClock.optimisticReset` was substituting `nextReset` for 7d too — the same defect through a
different path. The weekly branch now rolls forward the instant that just elapsed (which is itself
the last known fact).

**The five-hour branch stays on `nextReset`** — this is a deliberate divergence noted in
[ADR-0030](0030-optimistic-reset-and-exact-timer.md): the 5-hour window starts on the first spend
rather than sitting on a grid, so there's nothing to roll forward.

### 9. Journal migration v2 → v3

Archival rows written during a blackout carry an estimate and `timePct = 0` — meaning any analysis
of those hours read a flat line that never actually happened. The migration rolls them onto the real
grid from the preceding anchor and **recomputes** `timePct`.

Estimates differ from real resets by an exact signature: an estimate is rounded to a 10-minute
boundary, a real reset **always has fractional seconds**. The check runs on the **raw string**, not
on the parsed date — `ResetClock.parse` drops the fractional part, so after parsing they're
indistinguishable. (The migration's first version tripped on exactly this: it treated **every**
reset as synthesized.)

A run against the live journals: 199 and 56 entries reconstructed, 0.000 s error, no row lost,
idempotent. After reconstruction, each episode has at most **one** zero `timePct` left — the first
poll made in the exact second of the reset, where zero is simply true.

## Consequences

- **The time marker on 7d moves from the first minute of the window** instead of sitting at zero for
  4–6 hours and then jumping.
- **[#389](https://github.com/artem-from-ua/tokenpace/issues/389) simplifies substantially.** That
  ticket treats the 10-minute "drift" as server behavior and names it the main trap for the
  detector — 35 of 37 `resets_at` changes on Max. In fact `ceilTo10Minutes` is **our** code, and it's
  only ever called from `nextReset`. This change removes ~95% of the noise that detector would
  otherwise have had to filter.
- **A grid shift by the server** (documented in #389 as −10.33 h on Pro) will make the
  reconstruction wrong by that amount during the *next* blackout. The error is **bounded and
  self-correcting**: the very next real reset overwrites the anchor. The new persistent anchor is
  exactly the input the #389 detector needs.
- **Local clock drift** shifts the reconstruction. Beyond that we don't guard against
  `maxRollForwardSteps` (10 years of weeks): the app already trusts the local clock everywhere else.
- **An empty 7d reset is a new state** that didn't exist before (previously only the 5-hour one could
  be empty). Consumers have been audited; `weeklyHasHeadroom` closes the blue gate in this state —
  consistent with its doc comment ("without a reliable weekly clock, the advice is withdrawn rather
  than guessed at"), and rows simply don't draw at all on a cold start anyway.
- **A state with an empty date but real usage** is deliberately **not** captured by the new state:
  the numbers are known even when the clock isn't, and hiding them would be a loss. Such a snapshot
  still draws the bars — just without a countdown.

## Verification

- `swift test` — 1,410 tests, including a replay of all three Max blackouts and the DST transition.
- A migration run against both live journals (opt-in `LiveJournalMigrationCheck`, read-only).
- Live stubs `weekly-reset-blackout` and `weekly-reset-unknown`, confirmed by the maintainer.
