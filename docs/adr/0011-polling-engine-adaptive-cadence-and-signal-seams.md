---
status: superseded
superseded_by: [0032]
date: 2026-06-22
---

# ADR-0011: PollingEngine — an async loop, an adaptive interval, and sleep/wake/network seams

> **Superseded by [ADR-0032](0032-simplified-polling-cadence.md).** The interval model was
> simplified: `AdaptiveCadence` is gone, the base became a flat 3 minutes, the idle override is 15
> minutes (rather than 30), and the 429 backoff no longer escalates `3→6→12→15 min` — it only honors
> `Retry-After`. The async loop, the seams (`PollScheduler`, `ClaudeActivityProbe`, `NWPathMonitor`,
> `NSWorkspace`), the `minInterval` floor and the "log only on change" principle from this ADR all
> still stand — what was replaced is the *cadence rules*, not the loop's architecture.

## Context

Issue #13 ("Sleep/wake + network") replaces the temporary mock in `AppDelegate`
([ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) §"Consequences") with live polling of
the usage API. The ticket's scope requires: an out-of-band poll immediately after the Mac wakes, a
pause during sleep, a stale state without crashes when the network drops, with automatic recovery, and
logging for all of those events. The user added requirements about **cadence**: when no Claude Code
sessions are running — poll rarely (30 minutes); with an active session — adapt to whether the data is
**changing** (no changes → slow down, changes → poll more often); and **a separate log message for
every decision to change the interval**.

The same class of module-boundary decision arises as in
[ADR-0008](0008-usageclient-pure-backoff-and-transport-seam.md),
[ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) and
[ADR-0010](0010-usage-health-and-error-states.md): where the loop's logic lives, how to make it
testable without live time, network or sleep, and how to layer several cadence rules without tangling
them into a knot.

1. **A loop versus a timer.** `Timer`/`DispatchSourceTimer` drag in a callback world and complicate
   `@MainActor` isolation; the codebase is already fully `async` (`UsageClient.fetch`,
   `UsageTransport`).
2. **Where the loop lives.** If the loop sits in `AppDelegate`, the acceptance criteria ("immediately
   after wake", "offline → stale plus automatic recovery") can only be checked by eye under
   `swift run`.
3. **Two cadence axes plus an override.** The 429 backoff (#9) already exists; content-driven
   adaptation and the 30-minute override for an inactive Claude are new, independent rules. An explicit
   priority model is needed.
4. **Network detection.** The SPEC mentions only `NSWorkspace` for sleep/wake, but "recover
   immediately" when connectivity returns requires a signal of its own — otherwise going offline (which
   is not a 429) does not escalate the backoff and the user waits out the full interval.

## Decision

1. **An async loop, `PollingEngine.run() -> AsyncStream<PollOutput>`, not a timer.** The wait between
   polls is an injected `PollScheduler` seam that races `Task.sleep(interval)` against the next
   `PollSignal`. `.wake`/`.networkRestored` cut the sleep short (an out-of-band poll); `.sleep` parks
   the loop (`waitWhileAsleep`) — no fetch runs while the machine is asleep. The stream is consumed by
   the shell on `@MainActor`; the engine itself is **not** `@MainActor`, so the tests do not drag in the
   main actor.

2. **`PollingEngine` lives in `CCTimerKit`, with a pure core plus seams — like `PollingBackoff` in
   ADR-0008.** All of the decision logic is pure, deterministic (injected `now`) functions:
   `advance(previous:outcome:claudeActive:now:)` (the health/backoff/adaptive state transition),
   `effectiveInterval(_:)` (computing the interval), `intervalDecision(previous:next:)` (the reason for
   the change, for the log). The dependencies are seam protocols: `PollScheduler`, `TokenProviding`
   (plus `KeychainTokenProvider`), `ClaudeActivityProbe`, and the existing `UsageTransport`. Tests
   substitute `ManualScheduler`/`StubProbe`/`StubTokenProvider`/`StubTransport` and exercise both
   acceptance criteria in isolation. The thin shell (`cc-timer`) keeps the platform side effects.

3. **Two independent cadence axes plus a hard override, with an explicit priority.**
   `effectiveInterval`: `429 backoff (PollingBackoff) > the Claude-inactive 30-minute override > the
   adaptive one (AdaptiveCadence)`.
   - **`PollingBackoff`** (#9, unchanged) — reacts to 429; it overrides everything, because it is the
     server's instruction.
   - **`AdaptiveCadence`** (a new pure type) — reacts to **content**: `unchanged()` doubles the
     interval `3→6→12→15 min` (the same progression as the backoff — one gentle rhythm when things are
     calm), and `changed()` instantly resets to 3 minutes. A "change" means `utilization` differs for
     the 5h **or** the 7d window (the user's decision); the first success (with no previous snapshot)
     counts as a change, so we start on the fast floor.
   - **The 30-minute override** — no Claude Code session → poll rarely, regardless of the adaptive
     state.

4. **Claude Code is detected through the `ClaudeActivityProbe` seam; in production that is
   `sysctl(KERN_PROC_ALL)`.** It matches the executable's **exact name**, `claude` (the CLI that
   consumes the subscription's limits), not a substring — so it does not produce a false positive on
   Claude Desktop (whose helpers are named "Claude Helper" and only surface with a `-f` match on the
   command line). No spawning of `pgrep` (no dependency on a path). Any sysctl failure → an empty set →
   "inactive" → the conservative 30-minute interval.

5. **The network gets a separate `NWPathMonitor` for the signal, not a second source of truth.** The
   `.unsatisfied → .satisfied` transition yields `.networkRestored` → an out-of-band poll (recovery in
   seconds rather than after a full interval). The monitor does **not** build health and does **not**
   decide staleness — that still derives solely from the result of `fetch` (`UsageError.transport →
   FailureReason.network → failingSince` → the 30/60-minute menu bar phases from ADR-0010). An offline
   poll does not crash: `fetch` returns a typed `UsageError`, `advance` keeps `lastSnapshot` (stale),
   and the backoff does **not** escalate (this is not a 429).

6. **A token error never goes to the network and never touches the intervals.** An expired or missing
   token ([ADR-0007](0007-token-provider-throws-and-scope-split.md): a stale token means a guaranteed
   401 plus burned rate limit) → `pollOnce` skips the fetch, and `advance` only records the failure
   (`FailureReason(TokenError)`) without escalating either the backoff or the adaptive cadence — so
   that as soon as Claude Code writes a fresh token, the next poll picks it up.

7. **Every interval change is logged with its reason, and only when it actually changes.**
   `intervalDecision` returns `nil` when the interval did not move — the same "log/redraw only on
   change" principle as `StatusItemView.layout` (ADR-0009 §8), without the spam. `AppLogger.lifecycle`
   carries a `.public` string (`interval 3m→6m: usage unchanged …`); no token touches this layer.

8. **The sleep/wake/network logs are a shell side effect and are not unit-tested** — like drawing in
   ADR-0009. OSLog is hard to assert on; what is tested instead is the pure `intervalDecision` (that
   the reason is right and that it fires only on change), while the sleep/wake/network logs themselves
   are verified by hand (`log stream`).

9. **Two independent safeguards against a tight request loop — `LivePollScheduler` in `CCTimerKit`
   (testable) plus a hard `minInterval` floor.** The scheduler is the only thing holding back the
   request rate, so it does **not** live in the shell target (out of reach of tests) but in
   `CCTimerKit`: it depends only on `AsyncStream<PollSignal>` and `Task.sleep`, with no AppKit or
   Network. The invariant: `waitForNextPoll` waits out the **whole** interval unless a real signal
   arrives — an empty or finished stream never returns instantly (thanks to `SignalGate`, which
   demultiplexes the stream and resumes the waiter exactly once: on a signal, on the deadline, or on
   finish). The independent second line of defense is that `effectiveInterval` never returns less than
   `minInterval = 60 s` (below the 180 s base, so it does not slow down normal operation): even a broken
   scheduler cannot make us send more often. Covered by `LivePollSchedulerTests`
   (`emptyStreamWaitsTheFullInterval`, `engineWithRealSchedulerStaysBounded`) and `MinIntervalFloorTests`
   (`everyIntervalCombinationRespectsFloor`).

   **The lesson (a regression that happened once):** the first implementation of the scheduler lived in
   the shell target **without tests** and raced `Task.sleep` against a raw `AsyncStream` iterator,
   which on a finished stream returned `nil → .elapsed` instantly — `waitForNextPoll` came back with no
   pause at all, and the loop sent ~50 requests per second, ignoring even `Retry-After: 145s`, until it
   hit a 429. The conclusion was recorded constructively: the component most critical to safety
   **must** live in the tested core, and cadence invariants must have an independent hard floor
   (`minInterval`) rather than relying on the scheduler being correct.

## Consequences

- Both acceptance criteria are covered by unit tests without live time, network or sleep: `wake → an
  immediate poll`, `sleep → park`, `offline → stale without crashing`, `networkRestored → an immediate
  poll`, `recovery → failingSince=nil`. `AdaptiveCadence` and `intervalDecision` get table tests.
- `CCTimerKit` stays free of AppKit/Network/Darwin — `PollingEngine`/`AdaptiveCadence` deal purely in
  semantics; the platform seams (`LivePollScheduler`, `NWPathMonitor`, `NSWorkspace`, sysctl) live in
  `cc-timer`. Reuse in Phase 2 is preserved (a different cadence policy would be a new decision → a new
  section or ADR).
- The two cadence axes are orthogonal: 429 and content never get confused, because `effectiveInterval`
  has one priority order and `cause(...)` attributes the change to whichever axis actually owns the new
  interval.
- `LivePollScheduler` races `Task.sleep` against the signal stream and cancels the losing branch
  (`group.cancelAll()`) so that a sleeping `Task.sleep` does not pile up. The single consumer of the
  signal iterator reads strictly sequentially (`SignalReader`, `nonisolated(unsafe)`).
- If Phase 2 brings caching (`If-Modified-Since`) or different activity/interval thresholds — that is a
  new decision → a new section here or a separate ADR.

## Related

- [ADR-0007](0007-token-provider-throws-and-scope-split.md) — `TokenError`, and why a stale token never
  goes to the API.
- [ADR-0008](0008-usageclient-pure-backoff-and-transport-seam.md) — `PollingBackoff`, `UsageTransport`;
  this ADR unfolds the "*running* the timer belongs to the polling layer" part.
- [ADR-0010](0010-usage-health-and-error-states.md) — `UsageHealth`/`FailureReason`; the engine builds
  them from the poll's result.
