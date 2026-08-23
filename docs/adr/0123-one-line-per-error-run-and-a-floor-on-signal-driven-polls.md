---
status: accepted
date: 2026-08-23
supersedes: [0032, 0067]
---

# ADR-0123: One line per error run, and a wall-clock floor on signal-driven polls

> **Supersedes §D4 of [ADR-0032](0032-simplified-polling-cadence.md) and the `error` line's shape in
> [ADR-0067](0067-local-usage-journal.md).** Everything else in both records **still stands**: the
> 3-minute base, honor-only `Retry-After`, pausing on lock, and the append-only heterogeneous JSONL
> with its tolerant decoding.

## Context

A contributor's journal for August 2026 was 11 MB across 124 788 lines, and **98% of it was one
error repeating**: 122 592 `error` records against 1 290 `usage` ones. 122 408 of them were written
in a single 127-minute stretch on 19 August — roughly 16 lines a second, peaking at 32.

Every one of those lines said `{"kind":"error","code":"notSent","reason":"notSent"}`, and nothing
more. `notSent` means the request was never sent because the Keychain credentials could not be read.

Three independent defects composed into that outcome.

**The reason was produced and then discarded.** `PollingEngine.notSentReason` maps each `TokenError`
to a `.public`-safe string — `"token expired"`, `"keychain access denied"`, and three more — and the
Troubleshoot window renders it verbatim ("Request not sent: token expired"). On the way to the
journal, `errorCodeAndReason` dropped the associated value. The app knew why and showed it on screen
while writing 122 592 lines that could not say whether a token had expired or the Keychain had
refused.

**The `minInterval` floor had one rail where its own documentation claimed two.** The comment on the
constant read "Enforced twice: `effectiveInterval` never returns less, and `run()` re-checks elapsed
wall time after every wait." No such re-check existed. The wake path consulted
`wakeRearmInterval(lastSuccess:interval:now:)`, and a token error never advances `lastSuccess` —
`recordFailure` touches only `failingSince` and `reason`. So for as long as the Keychain stayed
unreadable, every wake signal read as "the cache is stale, poll now".

**The signal sources are undebounced by design.** `ScreenLockObserver` maps `screenIsLocked`,
`screensaver.didstart`, and `screensDidSleep`/`Wake` straight into `.sleep`/`.wake`; `NetworkMonitor`
emits `.networkRestored` on every unsatisfied→satisfied edge. A blinking display or a flapping
network produces these several times a second, which is exactly the ~16 Hz observed.

The cost to the user was not the file size. The last successful poll was 19 August at 17:05 and the
next was 20 August at 16:50 — nearly a day without data, during which the weekly window silently
reset from 19.14% to 0. And across those 18 hours the journal holds **no resume marker at all**: the
gap detector reads `lastWriteInstant`, and 122 408 writes had kept it fresh, so the outage was
invisible in the one record built to make outages visible.

[ADR-0032](0032-simplified-polling-cadence.md) §D4 had decided this area already, and decided it in
the right direction — "so that a flickering screen or a flapping network doesn't hammer the API when
the data on screen is still current". Then it carved out an exception: *"returns `nil` (poll now)
when the cache is stale **or** there hasn't been a single success yet (cold start / failure — a wake
is entitled to a fetch)"*. A broken token lands squarely in that carve-out, and the carve-out has no
bound. This ADR finishes what 0032 started rather than reversing it: a wake is entitled to *a* fetch,
not to one per signal.

## Decision

### D1. The not-sent reason reaches the journal as a new key, never as a value of `reason`

`ErrorSample` gains `detail`. `reason` remains a closed taxonomy —
`clientProblem`/`serverProblem`/`auth`/`decode`/`timeout`/`dns`/`network`/`notSent` — because every
downstream count groups by it, and free text there would split one bucket into six without anything
signalling the split.

The producers are two and their values are six: the five `TokenError` cases and the User-Agent guard
in `UsageClient`. None carries a token or any user data; `notSentReason` is already marked
`.public`-safe.

`errorCodeAndReason` becomes `errorCodeReasonAndDetail`. The rename is part of the decision: a
function that returned two of the three things its name listed is what let the third be dropped
silently for a year.

### D2. Consecutive identical failures are written as one record

A run is identified by `(code, reason, detail, retryAfter)`. `retryAfter` is part of the identity —
two 429s holding different hints are different failures, and merging them would invent a hold neither
server asked for. `ms` is not: it measures one attempt, not the class.

The closed record carries `n` (the count), `t` (the first attempt) and `tEnd` (the last). A run of
one is written as an ordinary error line with neither field, so the common case gains no noise.

**A run is bounded by width — 3 minutes — not by the gap that breaks it.** Bounding by the gap would
let a long outage accumulate behind a single unwritten line: the real incident's largest run spanned
844 minutes, and under a gap bound the journal would have recorded nothing for 14 hours, and nothing
at all if the app had been killed first. Bounded by width, the same outage leaves one line every 3
minutes, each with its own `n`.

The decision lives in `ErrorRunCollapse`, a pure type in the Kit. `UsageJournal` holds only the open
slot and the I/O — the executable target has no test target, and a rule this consequential must be
unit-testable.

### D3. `PollState` gains `lastAttempt`, and signal-driven polls are floored against it

`lastAttempt` is stamped once at the top of `advance`, before the outcome switch, so every branch
gets it. Not inside `recordFailure`: the 429 path returns before calling it, so a stamp living there
would leave rate-limited polls invisible to the floor — the same split that made `lastSuccess`
unusable as a bound.

`canPollNow(lastAttempt:now:)` and `rearmDelay(lastAttempt:now:)` are pure, modelled on
`RefreshGate.allows(now:)` — a deadline with a predicate, not a duration. Both wake paths and the
post-park `.sleep` path consult it; a refusal re-arms the wait for the remainder instead of fetching.

`.manualRefresh` is exempt. A person pressing Refresh is not a signal source, and the floor exists to
bound signal sources.

### D4. The signal sources are not debounced

The floor belongs where the cost is — the request — not where the event is. A debounce at the source
would be a second cadence parameter to keep consistent with `minInterval` by hand, and it would be
lossy for the other consumers of those edges, which legitimately want every one.

### D5. The gap clock measures polls, not writes

`lastWriteInstant` becomes `lastPollInstant` and advances on every attempt, written or not. The
rename is load-bearing: the field's job is to answer "were we polling", and during a collapsed run we
were. Stamping only on writes would emit a resume marker across time spent polling hard — the mirror
of the bug that erased 18 hours of real downtime.

### D6. Accumulated runs are collapsed by a launch migration, grouped by adjacency in the file

The migration shares `ErrorRunCollapse` with the writer, so both group by identical rules by
construction rather than by two implementations agreeing.

Grouping is by adjacency, not a time window: journals hold genuinely out-of-order timestamps (two
processes appending under `flock`), which a window would handle erratically.

Two things the pass does not do. A run of one is passed through as its **original bytes**, and so is
an already-collapsed line — re-encoding what cannot be improved would make every journal a changed
file and every launch a rewrite. Backups keep the existing `.v<n>.bak` convention.

## Consequences

- **Individual attempt instants inside a run are gone.** Only the endpoints and the count survive,
  and for already-written history the `.v<n>.bak` is the only remaining record. A reader asking "when
  exactly was the third failure" will not find an answer.
- **Every count over errors must read `n ?? 1`.** A tool that counts lines now undercounts, silently,
  by up to three orders of magnitude. The journal has no in-app consumer of `error` records to
  soften this, so external `jq` and skill tooling is where it lands; the trap is written into
  [journal-analysis.md](../reference/journal-analysis.md).
- **A wake during a token error can be delayed by up to 60 s.** Acceptable: the poll it delays would
  have failed.
- **`lastPollInstant` no longer means what its old name said**, deliberately. The rename is what
  stops the next editor from restoring the old semantics as a "fix".
- **An error run open at a hard kill is lost.** `applicationWillTerminate` flushes best-effort, but it
  is synchronous and cannot await an actor. Acceptable: a run still open describes a failure that has
  not been fixed, and the next launch records it again within one cadence.
- **The error-only migration names its backup `.v4.bak`** for a file whose usage lines were already
  v4 — the imprecision already accepted for the colour-only pass, not a new one.
- **The pass makes every later launch cheaper.** The affected journal drops from 11 MB to 1.3 MB, so
  the migration that runs before every first poll has 98% less to read.

## Alternatives considered

- **Plain throttling — write at most one error line per 3 minutes, drop the rest.** Simpler, and it
  loses the count: the journal could no longer tell a storm from a lull, which is the single most
  useful thing about the record. Rejected in favour of collapsing, which keeps the number.
- **Debouncing the signal sources.** See D4.
- **A `RefreshGate`-shaped gate type for the floor.** The right template but the wrong size — its
  escalating cooldown ladder answers a question this problem does not ask. What was missing was not a
  gate object but the fact that an attempt happened.
- **Grouping the migration by a time window rather than file adjacency.** Breaks on the out-of-order
  timestamps that real journals contain.
- **Closing a run only when it breaks, with no width bound.** See D2.

## Verification

Three tests carry the incident by name:

- `aTokenErrorStormPollsAtMostOncePerMinute` — measures signals-per-poll, not wall time, because a
  storm cuts every wait short and leaves the clock nearly still. Verified by mutation: with the floor
  removed it reads 9 signals for 10 Keychain reads; with it, hundreds of signals cost single-digit
  reads.
- `theStormCollapsesToOneLinePerThreeMinutes` — the writer's side, at unit scale.
- `theStormFileCollapsesAndLosesNoAttempt` — the migration's side.

The live-journal check's line-count invariant is narrowed into two stronger ones: non-error lines are
conserved exactly, and error attempts are conserved via `sum(n ?? 1)` — which also catches a
miscomputed count that a line count never could.

Run end to end against the affected journal (on a copy): 124 788 → 2 328 lines, 11 MB → 1.3 MB, all
1 290 `usage` / 861 `status` / 45 `resume` records untouched, all 122 592 error attempts preserved,
second pass a no-op.

## Related

- [ADR-0032](0032-simplified-polling-cadence.md) — the cadence this floor completes.
- [ADR-0067](0067-local-usage-journal.md) — the journal whose `error` line this reshapes.
- [ADR-0017](0017-delegated-token-refresh.md) — the delegated refresh that recovers the token a
  `notSent` is reporting on.
