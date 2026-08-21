---
status: accepted
date: 2026-06-22
---

# ADR-0008: UsageClient — pure backoff, an injected token, and a transport seam

## Context

Issue #9 describes `UsageClient` as an HTTP client for `GET /api/oauth/usage` with a mandatory
`User-Agent` and backoff on 429. Two scope details are non-obvious and call for a deliberate decision
about the module's boundaries — the same class of decision as
[ADR-0005](0005-pacing-fractions-not-blocks.md), [ADR-0006](0006-reset-time-absolute-vs-relative.md)
and [ADR-0007](0007-token-provider-throws-and-scope-split.md).

1. **Where backoff lives.** The SPEC's "Refresh cadence" hands the polling *timer* to ticket #13
   (sleep/wake plus network): it is the polling layer that schedules the next wake-up and reacts to
   sleep, wake and the network. But #9's acceptance criteria explicitly require "backoff works (a unit
   test on the interval logic)". If backoff lived inside an asynchronous `fetch` (one that sleeps and
   retries), testing the intervals without a live clock and a live network would be hard.

2. **Where `UsageClient` gets its token, and how to test the network.** `UsageClient` depends on
   `TokenProvider` (#8), but architecturally it is the polling layer that *orchestrates*. If `fetch`
   read the Keychain itself, the network layer would be coupled to Keychain I/O and `Security`, and
   unit tests would have to mock the Keychain. Separately, there is the question of how to exercise
   `fetch` without going to `api.anthropic.com`.

## Decision

1. **Backoff is a pure value-type state machine, `PollingBackoff`, with no timer and no sleeping.**
   The state model is a single `level: Int?` (`nil` == healthy → 180 s; otherwise an index into
   `steps`). The transitions are deterministic and side-effect free: `escalated()` moves up a step
   (`nil→0→1→2→3`, holding at 3), `reset()` returns to 180 s, and `interval` is derived. The 429 steps
   are stored **in seconds** (`[3, 6, 12, 15] × 60 = [180, 360, 720, 900]`) — the minutes-versus-seconds
   encoding is load-bearing and is guarded by the `stepsAreInSeconds` test. `fetch` **neither sleeps
   nor retries** — it returns a snapshot or throws a `UsageError`; advancing the backoff and scheduling
   the next wake-up belong to the polling layer (#13). That keeps all of the interval logic unit-tested
   in isolation, like `PacingModel`.

2. **The token is injected from outside as a `String`.** `fetch(accessToken:now:transport:)` takes a
   ready bearer token; the polling layer (#13) calls `TokenProvider.currentAccessToken(now:)` itself,
   handles `.expired` (re-reading the Keychain periodically until Claude Code overwrites the item) and
   passes a fresh token down. `UsageClient` imports neither `Security` nor the Keychain and is tested
   with a literal token.

3. **Pure `buildRequest`/`decode` seams, separate from the networked `fetch`** — the same pure/I/O
   split as in `TokenProvider` (`decode` separate from `readRawData`). `buildRequest` carries the
   construction of all four headers and the "do not go out without a `User-Agent`" guard (it throws
   `.missingUserAgent` before any network call); `decode` parses the JSON into a `UsageSnapshot`. Both
   are testable without a network. An internal overload, `buildRequest(…, userAgent:)`, makes a
   negative test of the guard possible with an empty string — the public path always passes a non-empty
   version constant.

4. **`URLSession` is injected through a minimal `UsageTransport` protocol** (one async function;
   `URLSession` already has that signature) rather than by subclassing `URLProtocol`. The default is
   `URLSession.shared` (the project's "inject the dependency, with a default" idiom). Tests substitute
   a `StubTransport` returning a canned `(Data, HTTPURLResponse)` — hermetic, with no live HTTP.

## Consequences

- All of the backoff logic is covered by unit tests (`PollingBackoff`: the progression, the hold
  ceiling, reset, the encoding in seconds) without waiting for polling layer #13. #13 only reads
  `interval` and invokes the transitions.
- `UsageClient` stays free of the Keychain and `Security`; token errors are the orchestrator's
  business. A clean separation: `UsageError` carries only network and decode reasons, `TokenError`
  carries Keychain reasons.
- `fetch` is tested through a `UsageTransport` stub on every branch
  (200/429/401/5xx/transport/non-HTTP/malformed) without touching the network; no test hits
  `api.anthropic.com`.
- `resets_at` is not parsed in `UsageClient` — it is kept as a raw string and goes to `ResetClock.parse`
  (#7), so that date normalization stays in one place.
- The token is never logged: `AppLogger.network` carries only `.public` diagnostics (the HTTP status,
  `retryAfter`, static strings); the `Authorization` header is built but never handed to the logger.
- `PollingBackoff.escalated(retryAfter:)` honors a server `Retry-After` longer than the schedule
  (jumping to the first step ≥ the hint, or to the ceiling) — the state stays a flat `level`, so
  `reset` works unchanged.
- If Phase 2 changes the polling policy (different intervals for widgets/the complication) or adds
  caching (`If-Modified-Since` — `now` is already threaded into `buildRequest` for exactly that) —
  that is a new decision → a new section here or a separate ADR.
