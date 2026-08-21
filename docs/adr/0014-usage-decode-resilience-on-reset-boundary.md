---
status: superseded
date: 2026-06-23
superseded_by: [0027]
---

> **Partially superseded by [ADR-0027](0027-session-idle-no-phantom-reset.md).** The
> **local-estimate branch for `five_hour`** (synthesizing `now + 5h` at the reset boundary) was
> replaced by an honest "no active session" state (`sessionIdle`), because for the 5h window a
> missing `resets_at` means "the window doesn't exist," not a reset blip. The rest of the decision
> still stands: tolerant decode, the `limits[]` fallback, the local estimate for `seven_day`, and
> borrowing for sub-windows remain in force.

# ADR-0014: UsageSnapshot — synthesizing a window at the reset boundary instead of a decode failure

## Context

In release v0.10.0 the popup periodically showed **"Usage API unavailable — retrying…"**, even
though Claude's services were operational and the bars froze on stale data. Debugging via logs
(`log show --predicate 'process == "cc-timer"'`) showed this was **not** an API failure:

- The response's HTTP status was **200** (CFNetwork: `response_status=200`, `cache_hit=true`).
- But `UsageClient.decode` threw `usage decode failed` three times in a row.
- The failure happened **exactly at the 5-hour window's reset transition** (`five_hour` 29% → 1%, a
  new `resets_at`), lasted ~7 min, and recovered on its own.

Root cause: the `UsageSnapshot`/`UsageWindow`/`UsageLimit` model decoded the core windows
(`five_hour`/`seven_day`) as **required** values. At the reset boundary the API legitimately sends
`null` inside a 200 body where the model requires a value. Verified against a live body — each of
these cases crashed the **entire** snapshot:

| 200 body | Old decode |
|---|---|
| `five_hour: null` / `seven_day: null` | fails (`valueNotFound`) |
| `five_hour` missing | fails (`keyNotFound`) |
| `utilization: null` inside a window | fails |
| a `limits[]` element without `severity` / with `percent: null` | fails |

The `UsageError.decode` error maps to `FailureReason.serverProblem`
([ADR-0010](0010-usage-health-and-error-states.md)) → "Usage API unavailable." The message is
misleading: the API is available, we just failed to read a **transitional** body. And the bars
would also hide/freeze exactly when the window actually reset and should have shown a fresh 0%.

Three approaches to a `null` window came up:

1. **Fail** (status quo) — simplest, but produces a false "unavailable" on every reset.
2. Make the core windows **optional** (`nil` on `null`) — doesn't crash the snapshot, but hides the
   bar exactly at reset, when the user expects to see an update.
3. **Synthesize** a fresh empty window — at the reset boundary the window really is empty
   (`utilization = 0`), so this is a semantically truthful fill-in, not a masked error.

## Decision

**Synthesize a fresh window with `utilization = 0` whenever a core window arrives `null`/missing/
without `resets_at`** — option 3. The logic lives in one place, `UsageSnapshot.init(from:)` (a
custom decoder), so every downstream consumer (health, popup, menu bar) gets an already-normalized
snapshot and knows nothing about the edge case.

1. **`utilization = 0`** — a just-reset window has zero usage. This is true, not a placeholder.

2. **`resets_at` via a fallback chain:**
   1. the window object's own `resets_at`, if present (the `utilization: null` case) — taken as is;
   2. otherwise from `limits[]` by `kind` (`session`/`five_hour` → 5h; `weekly_all`/`seven_day` →
      7d) — these entries duplicate the same `resets_at` in the same response (not a calculation);
   3. otherwise a local estimate, `ResetClock.nextReset(now:window:)` = `now + durationSeconds`,
      **rounded up to 10 min** (rough precision honestly reflected by rough rounding).

3. **Every synthesis is logged** (`AppLogger.network.notice("synthesized … resets_at source=…")`),
   and on a real decode failure the **truncated body** is logged (via the existing `responseText`,
   capped at 500 chars) — so a future, unannounced change to the API schema can be diagnosed from
   logs instead of guesswork (previously `decode` logged only "usage decode failed" with no body,
   and `os_log` truncates a long success body to ~1 KB anyway).

4. **`limits[]` — every field is tolerant** (`decodeIfPresent` plus defaults). The array is never
   consumed downstream (it's only future-proofing) except as the fallback source for `resets_at`,
   so a `null` in one field must not crash the snapshot. New API fields (`scope`,
   `seven_day_oauth_apps`, `tangelo`, …) are ignored by `Decodable`, as before.

5. **`now` for the estimate — via `JSONDecoder.userInfo`** (`CodingUserInfoKey.usageNow`), so the
   decode layer stays testable and doesn't call `Date()` internally (the spirit of the pure-layer
   split, [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md)).
   `UsageClient.decode(from:now:)` threads through the real `now`; the default is `Date()` only for
   call sites with no clock (tests).

6. **Per-model sub-windows (`seven_day_opus`/`seven_day_sonnet`) — a separate, simpler case.** They
   remain **optional**: a missing key or the whole object being `null` → `nil` (the model wasn't
   used this window) — that stays. But a **present** object with `resets_at: null` (a live response
   sends `seven_day_sonnet: {"utilization":0.0,"resets_at":null}`) is the same reset boundary, and
   it must not be confused with "the model wasn't used." Here `utilization` is kept as received, and
   `resets_at` **is borrowed from `seven_day`** — the sub-window is part of the 7-day window, so
   they reset together (simpler and more accurate than the full core-window fallback chain).
   Without this, the popup drew a false "resetting…" at 100% elapsed (because `resets_at=""` →
   `ResetClock.parse=nil` → reset = now). Implemented as `UsageSnapshot.subWindow(...)`; every fill
   is logged.

The "unavailable" message **does not** change: after this hardened decode, the `.decode` branch
will only fire on a genuinely broken body (non-JSON, truncated), where "server problem" is the
right call. We're deliberately not introducing a separate `malformedResponse` reason right now — if
that branch does show up in the logs, we'll file it separately.

## Consequences

- **A normal reset no longer produces a false "Usage API unavailable."** The bar shows a fresh 0%
  with the correct time to the next reset.
- **Resilience to future API schema changes.** A missing/`null` field degrades gracefully instead
  of crashing; logging the body on a decode failure gives evidence instead of guesswork.
- **`utilization` is now tolerant of `null`, but not of the wrong type** — `utilization: "13"` (a
  string) still fails (a type mismatch), caught by the `utilizationAsStringThrowsDecode` test. This
  is deliberate: we forgive only `null` at the reset boundary, not real serialization bugs.
- **The old "fail on a missing window" contract is changed** — two tests
  (`missingFiveHourThrowsDecode`/`missingSevenDayThrowsDecode`) were rewritten as synthesis tests;
  a regression test against a full live body was added, along with unit tests for
  `ResetClock.nextReset`.
- Related to [ADR-0008](0008-usageclient-pure-backoff-and-transport-seam.md) (the `UsageClient`
  decode layer) and [ADR-0010](0010-usage-health-and-error-states.md) (mapping errors to UI states).
