# Design: awaiting-input refresh pipeline (poll + FSEvents + cache)

> Companion to [ADR-0066](../adr/0066-detect-sessions-awaiting-input.md). ADR-0066 fixes *what* we
> read and *why*; this note fixes *how* the count stays fresh — the interaction of FSEvents, a rare
> safety poll, and the mtime cache — before the shell code is written.

## Goal

Keep the "N sessions awaiting input" count fresh with **near-zero idle cost** and **no missed
transitions**, honoring two gates: update **only while Claude Code is running and the screen is
unlocked**.

## Three moving parts

```
 ┌─────────────────────────────────────────────────────────────────────┐
 │ shell (TokenPace, AppKit/CoreServices — platform glue, not tested)   │
 │                                                                       │
 │  ┌───────────────┐   file-change    ┌──────────────────────────┐     │
 │  │ FSEvents      │  paths (coalesced │ RefreshCoordinator       │     │
 │  │ stream on     │──by `latency`)───▶│  · debounce/merge        │     │
 │  │ sessions/,jobs│                   │  · gate (lock + claude)  │     │
 │  └───────────────┘                   │  · calls scan()          │     │
 │        ▲  start/stop                 └───────────┬──────────────┘     │
 │        │                                         │ Int                │
 │  ┌─────┴─────────┐   every 30–60 s               ▼                    │
 │  │ safety Timer  │──────────────────▶ ┌──────────────────────────┐    │
 │  └───────────────┘                    │ AwaitingInputScanner     │◀───┼── pure core
 │        ▲                               │  (TokenPaceKit)          │    │  (unit-tested)
 │        │ gate signals                  │  · mtime cache (memory)  │    │
 │  ┌─────┴──────────────┐                │  · scan() → Int          │    │
 │  │ NSWorkspace lock/   │                └──────────────────────────┘    │
 │  │ unlock, Claude probe│                         │                     │
 │  └─────────────────────┘                         ▼ count changed?      │
 │                                          render() → MenuBar/Popup      │
 └─────────────────────────────────────────────────────────────────────┘
```

1. **`AwaitingInputScanner`** (pure, `TokenPaceKit`, already built). Owns the in-memory mtime cache;
   `scan()` returns the current count, re-reading only files whose mtime advanced. This is the
   single source of the number — every trigger funnels through it.
2. **FSEvents stream** (shell). The primary trigger. Watches `~/.claude/sessions` and `~/.claude/jobs`
   recursively; the OS wakes us with a coalesced list of changed paths.
3. **Safety poll** (shell). A rare (30–60 s) timer that also calls `scan()`, to catch anything
   FSEvents coalesced away or dropped across sleep/logout.

The mtime cache is what makes running the *same* `scan()` from three triggers (FSEvents batch,
safety tick, catch-up-on-unlock) cheap: whichever fires, unchanged files cost one `stat()` and no
re-read.

## FSEvents specifics

- `FSEventStreamCreate(paths: [sessions, jobs], latency: ~0.75s, flags: kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)`.
  - `FileEvents` → per-file granularity (path list, not just the parent dir).
  - `latency 0.75s` **is** the "інтервал на обробку вхідних івентів" — the OS batches a burst of
    writes into one callback, so a chatty session doesn't spin us. `NoDefer` delivers the first
    event of an idle→busy burst promptly, then coalesces the tail.
- Callback runs on a dedicated dispatch queue; it forwards the batch to `RefreshCoordinator`, which
  hops to the main actor to touch UI.
- We keep the last `FSEventStreamEventId`. On **stop→start** (unlock, or Claude reappearing) we start
  `sinceWhen: lastEventId` so events during a brief stop are replayed — plus we always run one
  explicit catch-up `scan()` on start regardless (cheap, and covers the "events were dropped" case).

## Gating (the two conditions)

The gate maps directly onto **stream lifecycle**, not a filter inside a hot loop:

| Transition | Action |
| --- | --- |
| screen unlocked **and** `claude` running | start FSEvents stream (from `lastEventId`), arm safety timer, run one catch-up `scan()` |
| screen locked **or** `claude` exited | stop FSEvents stream, disarm safety timer (no work while parked) |

Signals already exist in the shell: `NSWorkspace` lock/unlock notifications feed the existing poll
`SignalGate`, and `ProcessClaudeActivityProbe` (sysctl `KERN_PROC`, `PollingShell.swift:237`) reports
whether `claude` is running. The Claude-running edge is polled on the existing heartbeat (no new
timer): when it flips, toggle the stream.

> Rationale for stop-on-lock: no point watching files the user can't act on, and it lets a laptop
> sleep undisturbed. Restart cost is one stream create + one `scan()` — milliseconds.

## Debounce / merge in `RefreshCoordinator`

Even with FSEvents `latency`, two independent bursts (a `sessions/` write and a `jobs/` write ~100 ms
apart) can produce back-to-back callbacks. The coordinator coalesces: on any trigger it schedules a
single `scan()` on the next main-actor turn (dropping a scan already scheduled for this turn), so at
most one `scan()` per UI frame regardless of trigger fan-in. `scan()` itself is idempotent, so an
extra call is only a few `stat()`s.

Only when the returned `Int` **differs** from the last rendered count do we re-render the menu bar /
popup (the count feeds `MenuBarLayout.make` / `PopupLayout.make`, gated by the feature toggle).

## Why hybrid, not one channel (trade-offs)

| | Poll 5 s only | FSEvents only | **Hybrid (chosen)** |
| --- | --- | --- | --- |
| Idle CPU | wakes every 5 s (cheap w/ cache) | ~0 | ~0 (rare safety poll) |
| Latency | up to 5 s | ~`latency`, near-instant | near-instant |
| Missed event risk | low (always re-checks disk) | real (sleep/logout/coalesce) | low (poll backstops) |
| Complexity | low | medium (catch-up after sleep) | higher (both) |

FSEvents alone is tempting for pure zero-cost, but the private, undocumented source (ADR-0066)
already forces a defensive posture; the safety poll is the same "don't trust one fragile channel"
philosophy, and it costs almost nothing thanks to the cache.

## What lives where (mirrors ADR-0009/0023 core/shell split)

- **`TokenPaceKit`** (pure, tested): `AwaitingInputScanner` (done). Optionally a small pure
  `AwaitingRefreshPolicy` for the debounce/should-render decision, if it grows enough to warrant a
  test — kept out of the shell for the same reason `LivePollScheduler` is.
- **`TokenPace`** (shell, platform): the `FSEventStream` wrapper, the `RefreshCoordinator`, the
  safety `Timer`, and the lock/Claude gate wiring. No parsing logic here — it only *drives* the core.

## Logging discipline (quiet by default)

This pipeline is **high-frequency** (an FSEvents callback per file burst, a safety tick every
30–60 s), so verbose logging here would flood a user's log store. Rule: **no per-tick / per-event
logging on the steady-state path in shipping builds.**

- **Steady state** (a scan ran, the count is unchanged, an FSEvents batch arrived): **silent.**
  No `.notice`/`.info` per tick or per event.
- **Log only real state changes**, at most: the count actually changed (`old → new`), the stream
  started/stopped (unlock/lock, Claude appeared/exited), or an error the user could act on
  (FSEvents failed to start, `~/.claude` unreadable). These are rare and worth a `.notice`.
- **Development-time detail** (each batch, each path re-read, cache hit/miss) goes behind a
  `.debug` level **and/or** the existing `TOKENPACE_DEVTOOLS` gate, so it exists while wiring the
  feature but is off for users by default. Per CLAUDE.md, `.debug`/`.info`/`.notice` are not
  written to the persistent store anyway — but we still keep the steady-state path silent so a
  live `log stream --level debug` during unrelated debugging isn't drowned out.
- Any new/changed log line updates `docs/reference/log-messages.md` in the same commit (repo rule).

Net: after the feature is debugged, a user running normally sees essentially **nothing** from it in
the logs unless the awaiting count changes or something breaks.

## Test seams

- Core `scan()` + cache: covered (`AwaitingInputScannerTests`, fixture tree, mtime rewrite, vanish).
- Debounce/should-render policy (if extracted to Kit): unit-testable on synthetic trigger sequences,
  same shape as `LivePollSchedulerTests`.
- The FSEvents wrapper and gate are shell glue → verified live via the stub (`TOKENPACE_AWAITING`)
  and by driving a real Claude session, per `docs/guides/ui-verification.md`.
