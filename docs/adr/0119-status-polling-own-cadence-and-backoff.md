---
status: accepted
date: 2026-08-22
supersedes: []
superseded_by: []
---

# ADR-0119: Status polling gets its own heartbeat and a per-source 429 backoff

> Revisits §7 of [ADR-0013](0013-claude-status-line.md) (already superseded by
> [0024](0024-configurable-logical-services.md)/[0071](0071-incident-subscriptions.md)): the "separate,
> polite cadence" it decided on still stands, but the *mechanism* — riding the usage tick — does not.
> Also closes the open debt recorded in [ADR-0085](0085-provider-monitoring-model.md) §Consequences
> ("`StatusCadence` loses problem-floor acceleration"). The analogy
> [ADR-0025](0025-check-for-updates.md) draws to the status poll, and the manual-refresh path
> described in [ADR-0020](0020-troubleshoot-window-and-diagnostics-pipeline.md), are both narrowed by
> this record.

## Context

The service-status poll had **no cadence of its own and no backoff at all**. Both gaps were invisible
because exactly one status page was ever polled.

**It rode the usage poll.** `pollStatusIfDue(usageInterval:)` was called from `apply(_ output:)` —
once per usage tick, and from nowhere else. `StatusCadence.isDue` *required* a `usageInterval`
argument, and its docblock said so outright: "The status loop does **not** run its own timer."

That was a sound decision for one provider whose status page is a secondary source sitting next to a
usage poll that is always running. It stops working the moment a provider has status and **no** usage
poll — there is no heartbeat to ride. It already misbehaved in a narrower way today: with
`usageApiEnabled` off (`servicesOnly`, #341), the status poll's heartbeat was whatever the usage loop
still happened to tick at, and the 60-s problem floor could never be reached because the interval was
`max`-ed against a cadence that no longer accelerated. ADR-0085 recorded exactly that as debt.

**`Retry-After` was discarded.** `StatusClient.fetchRaw` mapped **every** non-200 to
`StatusFetchError.decode`, 429 included, and never read the header. Downstream, any failure became
`.unknown` without advancing `lastStatusSuccess`, so the next usage tick simply retried — under a fast
usage cadence, a retry roughly every 60 s against a third-party page that is actively asking us to
slow down. `StatusClient`'s docblock claimed it was a source "never sharing the usage 429 backoff",
which was true and misleading in the same sentence: it shared nothing because it had nothing.

This is a prerequisite for [#454](https://github.com/artem-from-ua/tokenpace/issues/454) (a GitHub
status provider), extracted so that ticket does not build this machinery on the side.

## Decision

### D1. `429` becomes its own error case, carrying `Retry-After`

`StatusFetchError` gains `rateLimited(retryAfter: TimeInterval?)`. The header is parsed in the
**delta-seconds form only**; the HTTP-date form maps to `nil`, as does an absent or malformed value.
`nil` is not an error — it means "no usable hint", which `PollingBackoff` already answers with its
180 s default.

**Every other non-200 stays `.decode`.** The client deliberately does not model individual codes: a
status page carries no auth detail and no per-code meaning for us beyond "not 200". `429` earns a case
because it is the only code the *caller* reacts to differently.

The parser is a four-line copy of `UsageClient.retryAfterSeconds` on `StatusClient`, not a shared
helper (internal, so the kit's tests can reach it; not `public` — no caller outside needs it). The
two clients are separate seams over separate services (ADR-0013), and a one-line header read is a poor
reason to couple them — the coupling would be the thing a later provider has to undo.

### D2. One `PollingBackoff` per status source, reused verbatim

`PollingBackoff` is taken **unchanged** from the usage side. Its semantics are already the ones this
needs, and they were argued once in ADR-0008/ADR-0032: hold at exactly the server's `Retry-After` (or
180 s without one), **no escalation** across consecutive 429s, the first 200 clears the hold. Nothing
about a status page justifies a second, subtly different back-pressure rule.

What is new is *plurality*: the hold is **per source**, never shared. A 429 from one status page must
leave every other page's cadence untouched, and neither may touch the usage engine's backoff — nor it
theirs. The type is a value type with one field, so this costs one stored property per source rather
than any machinery. Today that is one property (`App.statusBackoff`); #454 adds a second, and the
shape does not change.

### D3. The hold outranks the floors

`StatusCadence.nextInterval(backoff:usageInterval:hasProblem:)` gives an active hold absolute
priority, mirroring the usage loop's `429 hold > idle > base` ordering. A **short** hold wins too: if
the page says 30 s, the loop waits 30 s even during an incident, because the page's answer outranks
our opinion about how interesting it currently is. Manual refresh (Troubleshoot) clears the status
hold, matching what `.manualRefresh` already means for the usage engine — a deliberate user action,
honoured even mid-rate-limit.

### D4. The status loop runs on its own `LivePollScheduler`

`LivePollScheduler` is reused rather than reinvented: it already lives in the kit, has no
AppKit/Network dependency, is unit-tested, handles `wake`/`networkRestored`, and — the property that
matters most — its deadline always elapses in full, which is what prevents a tight request loop.

The loop is built once at launch, not inside `buildAndRunEngine`, so a live scenario swap (#187)
rebuilds the engine without tearing status polling down; it re-reads `statusTransport` on each poll and
picks up the new transport by itself.

`.sleep` parks it via `waitWhileAsleep()` exactly as `PollingEngine` does, so screen-lock pause
(`pausePollingWhenScreenLocked`, #114), system sleep/wake and network-restored behave as they did
before. `.wake` / `.networkRestored` / `.manualRefresh` cut the wait short and then re-ask `isDue`
rather than fetching unconditionally — a blinking screen must not become a burst of requests at a
third-party page.

**`SignalHub` fans out to two subscribers.** This is the part the loop could not have without a
change elsewhere. `SignalHub.newStream()` finished the previous stream and made the new continuation
the sole `send` target — correct while there was one subscriber, and a trap with two: whichever loop
subscribed second would have silently stolen sleep/wake from the first, with nothing logged. It now
keys continuations by `Subscriber` (`.usage` / `.status`), so a usage-engine rebuild finishes only the
usage stream and `send` reaches both. A signal is a fact about the machine ("we are awake", "we are
online"), not a message addressed to one loop.

### D5. `StatusCadence` keeps the policy, and its docblock is rewritten with the code

`StatusCadence` stays as the single place the frequency decision lives — it was already
provider-agnostic (a 5-min politeness floor, a 60-s floor while a problem is in progress) and is worth
keeping.

Two things change. `usageInterval` becomes **optional**, and it may only ever *slow polling down*: when
the user is idle and the usage cadence has stretched to 30 min, there is no reason to keep asking the
status page at the floor. With no usage tick, `interval` collapses to the floor — which is exactly the
standalone cadence a lone source should have.

And the docblock is rewritten **in the same commit**. It stated the opposite of the new code ("does
**not** run its own timer") and argued its politeness rationale entirely in terms of the usage
cadence's spikes. A docblock that argues against the code beneath it is worse than no docblock: it is
read as authority.

### D6. `hasProblem` is passed in per source, never read from a flattened value

`hasProblem` was computed at the decision site from `StatusHealth.worstProblem`, which flattens every
check. The moment a second source shares that value, one provider's incident accelerates the *other*
provider's poll to the 60-s floor — against a third-party page, which is precisely what the politeness
floor exists to prevent.

So it is now an **argument** to the pure cadence functions, supplied by the caller as *that source's*
problem signal. With one source it is still `lastStatusHealth?.worstProblem != nil`; when #454 adds the
second, each passes its own and there is no shared value to unpick. This ticket builds the seam only —
it does not build the second source.

### D7. `endpoint` and `userAgent` are parameters with defaults

`StatusClient.buildRequest` / `fetch` / `fetchRaw` take `endpoint:` and `userAgent:`, defaulting to
Claude's URL and `claude-code/<version>`. Every existing call site and all of `StatusClientTests` read
unchanged.

The User-Agent is parameterised for a substantive reason, not symmetry: `claude-code/<version>` is the
right thing to send to Anthropic's own status page and the wrong thing to send to anyone else's.

`static let endpoint` stays. It is also the routing key the dev stub transport matches on
(`request.url == StatusClient.endpoint`, **exact** equality); parameterising the request did not make
the constant go away, it made it the default rather than the only option. A test pins that the default
request still carries exactly that URL, since the app-target stub cannot be imported from the kit's
test bundle.

## Consequences

- **A rate-limited status page is now actually respected.** `429` + `Retry-After: 120` holds that
  source for 120 s and no longer; without the header, 180 s. Consecutive 429s re-set the same hold
  rather than escalating, and the first 200 clears it.
- **The `usageApiEnabled: false` mode gains a real heartbeat.** Status polling no longer depends on
  what the usage loop happens to be doing, and the 60-s problem floor is reachable there. This closes
  ADR-0085's open debt.
- **The usage tick still calls `pollStatusIfDue`.** It was left in place deliberately: removing it
  would change behaviour this ticket has no reason to change. Both entrances pass through the same
  `isDue` gate and the same in-flight `statusTask`, so two heartbeats cannot double the request rate;
  what the second buys is that status keeps running when the first is slow, off, or absent.
- **A failed status poll still yields honest grey `unknown`**, never a false `operational`. A `429` is
  a failure like any other in that respect — the only thing it changes is *when* the retry happens.
- **`SignalHub` is no longer a single-slot hub.** Anything else that wants platform signals must add a
  `Subscriber` case rather than calling `newStream()` and hoping. That is a deliberate speed bump.
- **Two more log lines** (`status backoff holding for <n>s`, `status backoff cleared by a successful
  poll`), plus `status rate-limited: HTTP 429 retryAfter=<n>`. A *growing* number in the holding line
  would be a bug, since the hold is re-set and never escalated — worth knowing when reading a capture.

## Alternatives considered

- **Generalise `PollingEngine` to drive both sources.** Rejected, and the ticket names why: the engine
  is saturated with usage concepts — Keychain tokens, the `claude` CLI refresher, the activity probe,
  weekly interpolation, 7-day reset reconstruction — none of which has a status analogue. Borrowing its
  small generic seams (`PollingBackoff`, `PollScheduler`, `PollSignal`) gets the whole benefit at none
  of the cost.
- **A shared backoff for all status sources.** Simpler by one property, and wrong: one page's 429 would
  throttle every other page, which is the exact cross-contamination D6 exists to prevent.
- **Escalating backoff for the status page** (the pre-ADR-0032 `3 → 6 → 12 → 15 min` shape). Rejected
  for the same reason it was rejected for usage: the server states a number, and inventing a curve on
  top of it is guessing where an answer was already given.
- **Parse the HTTP-date form of `Retry-After`.** Rejected as unearned: Statuspage sends
  delta-seconds, and `nil` already routes to a sensible default. The code that is not written cannot
  mis-parse a timezone.
- **Drop `pollStatusIfDue` from the usage tick** now that a real timer exists. Rejected as
  out-of-scope: it is behaviour change the ticket did not ask for, and the `isDue` gate already makes
  the second entrance harmless.
- **A second `SignalHub` for the status loop.** Would have avoided touching the existing hub, at the
  cost of two objects the observers must both be wired into — and a future third subscriber repeating
  the mistake. Keying one hub by subscriber is the smaller total change.

## Related

- [ADR-0013](0013-claude-status-line.md) — the original status line and its "separate, polite cadence"
- [ADR-0008](0008-usageclient-pure-backoff-and-transport-seam.md), [ADR-0032](0032-simplified-polling-cadence.md) — `PollingBackoff`'s semantics, reused verbatim here
- [ADR-0085](0085-provider-monitoring-model.md) — the `servicesOnly` mode whose debt this closes
- [ADR-0020](0020-troubleshoot-window-and-diagnostics-pipeline.md) — the manual-refresh path
- [ADR-0025](0025-check-for-updates.md) — `UpdateCheckCadence`, modelled on the old analogy
- [#455](https://github.com/artem-from-ua/tokenpace/issues/455), [#454](https://github.com/artem-from-ua/tokenpace/issues/454)
