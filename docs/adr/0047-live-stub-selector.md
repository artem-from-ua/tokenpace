---
status: accepted
date: 2026-07-30
---

# ADR-0047: A live stub selector — rebuilding the polling engine at runtime

## Context

Stub scenarios (`TOKENPACE_STUB=…`) are the main way to verify UI states: ~24 canonical frames
(`climbing`, `both-red`, `credits-active`, `reset-grace`, …). The active scenario was read from the
environment **once at launch** (`AppDelegate.stubName`) and "baked into" the transport: a large
`switch` in `startPolling` (~24 cases) constructed a `StubUsageTransport(mode:)`, and the choice of
token provider/refresher was also made from `stubName`. Seeing a different scenario meant **killing
the app and relaunching** with a different env var. This was painful once the color tuner (#185)
came along — it's natural to want to sweep it across different pacing levels without a restart.

The goal (#187): add a dropdown to the same dev-only **Development tools…** window (from #185) that
switches the data source live — the menu-bar icon and popup update within one polling cycle.

This isn't purely a UI concern: the active scenario is woven into how `PollingEngine` gets built,
and the engine isn't reachable for after-the-fact edits.

## Alternatives considered

1. **A `SwitchableUsageTransport` wrapper.** An externally stable transport with a mutable "inner"
   stub; a swap changes the inner one and sends `.manualRefresh`. But switching a scenario changes
   **more than the transport**: the token provider (`StubTokenProvider` vs
   `KeychainTokenProvider`/`ExpiredStubTokenProvider`) and the refresher (`nil` vs
   `ClaudeCLIRefresher`) change too. These are immutable `let`s on `PollingEngine`, outside that same
   seam. A wrapper would only cover the transport → every stub↔real-network transition would still
   need a full teardown. It adds a type and complexity without removing the teardown.
2. **Rebuild the engine (chosen).** `pollTask?.cancel()` plus rebuilding the engine block with the
   new scenario, then `.manualRefresh` for an immediate poll.

## Decision

**Rebuild the whole `PollingEngine` on every switch** — factored into `buildAndRunEngine(for:)`,
shared by both startup and a live swap. It pulls the transport/provider/refresher from a
**`StubScenario`** and starts a new `pollTask`. `switchScenario(_:)` (called by the dropdown) does a
teardown+rebuild and forces a `.manualRefresh`.

**`StubScenario` is the single source of truth.** A new `CaseIterable` registry (modeled on
`ColorRole`, 0046): each case's `rawValue` is the exact `TOKENPACE_STUB` id (`"1"`, `"both-red"`,
…), so `StubScenario(rawValue:)` gets env compatibility for free; `displayName`/`summary` supply the
dropdown's labels; `makeTransport()` folds in the former ~24-case `switch`. Both the launch path
(`launchScenario = StubScenario(rawValue: env ?? "") ?? .realNetwork`) and the dropdown read one
registry — **no duplicated list of cases** (an acceptance criterion). The descriptions (a maintainer
requirement) live on `summary`, right next to the mapping to `Mode`, so they never drift out of
sync.

**`SignalHub` hands out a fresh stream to every engine.** An `AsyncStream` is **single-consumer**:
once the first engine has started consuming `signals.stream`, a new scheduler on the same signal
stream gets nothing. `SignalHub.newStream()` creates a new `AsyncStream`+continuation, finishes the
previous one, and switches `send(_:)` over to the current continuation (under an `NSLock`).
Observers (`WorkspaceSleepWake`, `ScreenLockObserver`, `NetworkMonitor`) send into `send` without
caring which engine is active — they always reach the current continuation. This is the subtlest
detail: without it, a live swap would silently stop reacting to sleep/wake/network.

**The gate is the same `TOKENPACE_DEVTOOLS` as in 0046.** The dropdown lives inside the
already-gated window; outside dev tools the registry is inert (the launch path still reads env for
the maintainer's own runs). The window→app bridge is a closure, `onStubChange` (mirroring
`ColorStore.onChange`); app→window is `setCurrentScenario(_:)`, for preselecting the active scenario
(including one set via env).

## Consequences

- **+** Switching between ~25 states in place, with no restart — faster visual verification, and a
  convenient way to sweep the color tuner across pacing levels.
- **+** One `StubScenario` registry instead of an inline switch plus scattered comments; the
  descriptions and the mapping sit side by side.
- **+** A fresh `StubUsageTransport` on every selection naturally resets the `calls` counter, so
  sequenced scenarios (`stale-error`, `reset-grace`, `optimistic-reset`, `just-unblocked`) replay
  from poll 1 whenever reselected.
- **−** Every swap tears down and rebuilds the engine plus `pollTask` (not the cheapest operation),
  but that only happens on a dev selection; the normal launch path is unchanged (one
  `buildAndRunEngine` at startup).
- **−** `SignalHub` became `@unchecked Sendable` with an `NSLock` around the continuation (it used to
  be `let stream`) — the price of correct resubscription.
- Rule: when adding a stub scenario — add a case to `StubScenario` (rawValue = the env id,
  `displayName`, `summary`, `makeTransport`) and update the list in
  `docs/guides/ui-verification.md`. There's no more inline switch — everything goes through the
  registry.

## Postscript: env resolution no longer falls through to the live network (#267)

The decision still stands — the registry and the dropdown still read from one source — but the
one-line mapping quoted above
(`launchScenario = StubScenario(rawValue: env ?? "") ?? .realNetwork`) turned out to be dangerous
and was replaced.

`init?(rawValue:)` returns `nil` for any string outside the registry, and `?? .realNetwork` silently
collapsed that `nil` into "no stub set." Since `case realNetwork = ""` was also the live network's
id, **"nothing was set" and "something nonsensical was set" became indistinguishable**: a
one-letter typo (`TOKENPACE_STUB=healthy` instead of `all-green`) switched the app into fully live
mode — a real Keychain, real requests, live `~/.claude` trees — while still looking like an ordinary
stub run.

What changed:

- `realNetwork` got a non-empty id — **`"real"`**. The live network now has to be requested by name;
  an empty string is no longer a valid id.
- Resolution was factored out into `StubResolution` (`TokenPaceKit`, a pure core per ADR-0009) and
  covered by tests; `StubScenario.resolve(env:isAppBundle:)` is a thin wrapper around it.
- An unknown value (including empty) degrades into **`screenshot`**, not into live, and logs a
  `.notice` listing the valid ids. The default in a dev build is also `screenshot`; an installed
  `.app` with no env stays live.
- Resolution also returns a flag for "the choice was explicit," which the awaiting-input watcher's
  gate reads (see the postscript in ADR-0066).

The rule from "Consequences" gets one addition: a new case's id must be **non-empty and unique** —
`StubResolution.idsAreResolvable` checks this with an `assert` over `validIDs`.
