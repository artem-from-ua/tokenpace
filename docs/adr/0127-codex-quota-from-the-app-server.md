---
status: accepted
date: 2026-08-24
superseded_by: [0129]
---

# ADR-0127: Codex quota from a short-lived `app-server` process, with window durations as data rather than enum cases

> **Partially superseded by [ADR-0129](0129-ready-to-start-is-gated-on-the-account-reached-flags.md).**
> Only the last clause of §D13 is superseded — "the row is Claude's idle shape", which assumed the
> detection always yields a drawable row. A window that has not started renders that way **only**
> while the account's `spendControlReached`/`rateLimitReachedType` are clear; when either is raised
> the payload contradicts itself, and **no row is drawn at all** — a warning block stands in its
> place. **Everything else still stands in full**, D13 included: the asymmetric-bound detection, the
> one-sample rule, why no anchor is reconstructed, and why the raw epoch stays in Troubleshoot.

> The usage half of the provider [ADR-0125](0125-codex-as-a-status-provider.md) introduced, and the
> first subprocess TokenPace runs for *data* rather than for a side effect — the `claude` spawn of
> [ADR-0017](0017-delegated-token-refresh.md) exists to make Claude Code rewrite its own Keychain and
> reads nothing back. Consumes the `usageEnabled` switch [ADR-0125](0125-codex-as-a-status-provider.md)
> §D6 declared ahead of this collector.

## Context

Codex publishes no usage API. The quota lives behind `codex app-server`, a JSON-RPC-over-stdio server
inside the installed CLI, so reading it means running a program on the user's machine rather than
making an HTTP request.

Everything below rests on probes against codex-cli 0.148.0 rather than on documentation, and two of
the probes changed the design after it had been planned.

| Probed | Result |
|---|---|
| `initialize` reply | `{userAgent, codexHome, platformFamily, platformOs}` — no protocol version, no capability list |
| `initialized` notification | **not required**; `account/*` answers without it |
| Unsolicited notifications | `remoteControl/status/changed` arrives *between* a request and its response |
| Unknown method | **`-32600`**, not `-32601`, with every supported method named in the message |
| Live account | one `codex` bucket, `planType: plus`, **one 7-day window** (`windowDurationMins: 10080`), `secondary: null` |
| `rateLimits` vs `rateLimitsByLimitId.codex` | byte-identical |
| `account/read` | returns the account **email in the clear** |

## Decision

### D1. One process per read, not one held open — the measurement inverted the plan

The design this record was planned around held a long-lived child process, justified by a handshake
that was believed to cost ≈1.5 s against ≈0.43 s per read. **Measured, that is not what the numbers
are:**

| | median | samples |
|---|---|---|
| spawn + `initialize` response | **0.03 s** | 3 |
| `account/rateLimits/read` on a warm process | **0.44 s** | 6 |
| cold spawn through to a first answer | **0.45 s** | 3 |

The read is a network round trip; the spawn is not. A held-open process therefore saves about **6 %
of one read, once every three minutes**, and buys with it a permanent subprocess on the user's
machine, an orphan to reap if the app is killed, and a sleep/wake lifetime to manage. The process is
started for a read and gone before the read returns, and a cold spawn-to-answer being
indistinguishable from a warm read is what makes that free.

**The planned rationale is recorded here because it was wrong in a checkable way.** A future reader
who reaches for a long-lived actor should re-measure rather than re-reason: if the handshake ever
does cost seconds, this clause is the one to revisit.

### D2. Responses are matched by `id`, and unmatched lines are dropped silently

Not defensive. `remoteControl/status/changed` was observed arriving *before* the `initialize`
response it preceded, so a reader that took "the next line" would hand a notification back as a
result on the very first exchange. Every request carries an `id` and only the reply bearing it is
accepted.

Unmatched lines — a notification, a non-JSON line — are **dropped without logging**. The server owns
its stdout and may print anything; logging what we do not model lets a chatty server fill the log
with traffic nobody asked for.

### D3. "Too old" is detected on `-32600` **and** the method name, never on the code alone

The server answers an unknown method with `-32600 "Invalid request: unknown variant ..."`, not the
`-32601` the JSON-RPC spec reserves for it. But `-32600` is also the generic invalid-request code — a
malformed `params` struct returns it too. Keying on the code alone would report *our own* bug as an
out-of-date Codex and send the user to upgrade something that is fine, so the message must also name
the method that was called.

### D4. `account/read` is never called, and sign-in state comes from the rate-limit read

`account/read` returns the account email in the clear. Nothing on screen, in the journal, or in
Troubleshoot has a use for it, so the method is not called at all — and the popup needs no separate
sign-in probe, because a `rateLimits` the server omits already answers the question as a side effect
of the request being made anyway.

Calling it is the obvious move — it is the method named "read the account" — so the reason is stated
at the call site as well as here. For the same reason `codexHome` is present in the handshake reply
and deliberately not decoded: it is a path into the user's home directory.

### D5. A 5-hour row is never synthesized

The server reports the windows it has — one, today. Claude's plate always carries a 5-hour bar above
its 7-day one, and that symmetry makes adding one here look like completing the pattern. It would
draw a bar for a limit this server does not report, under a `resets_at` invented to fill the field.

The normalizer emits **one row per reported window**, so a `secondary` appearing later needs no code
change. That N>1 path has no live coverage — `secondary` is `null` on the probed account — which is
why a two-window stub exists to exercise it.

### D6. Window durations reach `PacingModel` as raw seconds, not new `LimitWindow` cases

`windowDurationMins` is a number in the payload: the server chooses it, and an enum can only list
what existed when the enum was written. A `sevenDayCodex` case would be wrong on its face.

So `elapsedFraction` and `barLayout` gain **raw-duration overloads**, and the existing case-taking
ones are re-expressed through them — one implementation, so the two cannot drift apart on the
boundary rules. Nothing downstream widens: `BarLayout` already stores `windowDurationSeconds`, and
`severity`, `pressureLength`, `balanceOffset` and `isCalm` all read fractions and seconds rather than
a case.

`subdivisions` becomes a **lookup, never a formula**. 5 and 7 were chosen for what the marks *mean* —
hour boundaries across five hours, day boundaries across a week — and no arithmetic recovers that: a
week divided by an hour is 168 ticks, a hatched smear. An unrecognised duration returns **0**, which
the bar already draws as no ruler at all. Codex's 10080 minutes is exactly 604 800 s, so it matches
the seven-day case and gets 7 ticks — the right answer reached from the duration rather than from the
provider.

### D7. Codex rows live in their own array, never appended to `layout.rows`

`PopupLayout.blockingReset` keys its `.token(id:)` pick to an **index into `rows`**, and the view
paints the red reset badge on the row whose index matches. Appending another provider's rows
renumbers that array, so the badge lands on a row that is not the blocker — and on the wrong
provider's plate.

This is the same rule that already makes the per-model group hide by *skipping* rows rather than
filtering them, and it is the single highest-risk mistake available in this change, so it is pinned
by a test that asserts the blocking index still resolves to Claude's own row.

### D8. `TweenKey.bar` gains its provider

Claude's `"7-day"` and Codex's `"7-day"` are the same string, and both plates are on the popup at
once. Keyed by title alone they are one animation, and one provider's colour slide plays out on the
other's bar. The key gains a `provider`, defaulted to `.claude` so the menu bar and every existing
caller read unchanged.

### D9. The collector runs off the main actor, and the poll task is detached

The session's pipe reads block the calling thread. This app's actors are reached from `@MainActor`,
and a `Task { }` written inside a `@MainActor` class inherits that isolation — so the naive shape
freezes the UI for the length of the round trip. The exchange runs inside `Task.detached`, and only
its value crosses back; the poll task is detached for the same reason, hopping to `MainActor.run`
only to store the result.

This was found by running it, not by reading it: the first build reached the poll and never returned
from the read.

### D10. Failure spends one retry per tick, then a five-minute cooldown

The common failure is a child that dies during start-up, which a second attempt clears. Anything
surviving two attempts is a condition a third would not fix either — so the collector stands down for
five minutes rather than spawning again at the next tick. Without that, a broken `codex` install
becomes a process spawn every three minutes for as long as the app runs.

A missing binary and an out-of-date Codex skip even the retry: both are stable facts about the
install, and a second spawn re-learns them at the cost of another process.

### D11. The quota is deliberately **not** journalled

`UsageSample.h5` and `UsageSample.d7` are **not** `Optional`. Fitting Codex's single 7-day window
into that shape requires **inventing** a 5-hour window — exactly what D5 forbids on screen — and the
journal is append-only, so a bad shape written once is in every archive forever.

Codex `status` records are written (ADR-0125 §D3 depends on them for its fallback age); quota records
are not. The Codex-shaped usage record is its own ticket
([#508](https://github.com/artem-from-ua/tokenpace/issues/508)), probably a new `kind` or a
`windows: [WindowSample]` under a bumped version.

A consequence worth stating plainly: the **per-provider clocks** added by
[ADR-0124](0124-journal-records-carry-their-provider.md) are still unused by Codex. They are tested
and waiting, not speculative.

### D12. `CodexQuotaError` maps onto the existing `FailureReason` cases

Eight causes — `cliNotFound`, `handshakeFailed`, `processDied`, `timedOut`, `methodUnsupported`,
`notSignedIn`, `rpc`, `malformedResponse` — and **no new `FailureReason` case**. Every distinction
they draw is one the user already meets on the Claude side, and the sentences are assembled at the
view's localisation seam; a parallel Codex vocabulary would double that seam to say the same things.
The mapper is exhaustive with no `default:`, so a new cause must be mapped consciously.

### D13. A reset equal to `now` plus the window's own length means the window has not started

`account/rateLimits/read` does not always name an instant. On a spotless window it answers with
`now + windowDurationMins × 60`, **recomputed per request**. Measured on the live Plus account,
codex-cli 0.148.0 — three reads across thirteen seconds of wall clock:

| `usedPercent` | `resetsAt` | `resetsAt − now` | offset from a whole window |
|---:|---:|---:|---:|
| 0 | 1788142481 | 604 800 s | 0 s |
| 0 | 1788142487 | 604 799 s | −1 s |
| 0 | 1788142494 | 604 800 s | 0 s |

The reset advanced **13 s across those 13 s**. The −1 s is our own `now`, taken before a 0.44 s
round trip; the server's arithmetic is exact. Passed through as an instant this draws a 7-day
countdown that slides forward every poll and never ticks down — a number that looks precise and
means nothing.

The same account returns the anchored form when something has been spent: `usedPercent 3` against a
reset fixed at `22:37:31Z`, an arbitrary wall-clock second rather than a grid boundary. **That is
what says the window is rolling** — it starts on the first spend after a reset and runs its own
length from there.

**The rule.** A window has not started when `resetsAt − now` is at least `durationSeconds − 120 s`
and at most `durationSeconds * 2`, **and** `utilization == 0`.

**−120 s on the near edge**, because the budget is the gap between the server's `now` and ours — a
0.44 s round trip behind a spawn D10 may retry once, plus clock skew — while the ceiling is the 180 s
poll interval. Under one interval, at most **one** poll of a genuinely anchored window can be
misread, and that is the poll in which the window really has just opened, where both readings agree.

**The far edge is deliberately loose — up to a full `durationSeconds` beyond the horizon, i.e. twice
the duration out.** A window that has not started can only ever report its full duration remaining,
so a horizon *shorter* than that means time has already run off it — an anchored window. A horizon
beyond it is the same not-started state read across a clock that disagrees with the server's, and
skew only ever pushes a reading that way, never the other. For the 7-day window this accepts a
reported reset up to 14 days out.

**One sample, not a run of consecutive polls.** Requiring the shape to persist would render the
sliding countdown for a full poll every time a window actually resets, and would need state that has
nowhere to live — the quota is not journalled (D11), and this stays a pure function of one payload.
It buys nothing, because `utilization == 0` is an independent second witness: 3 % of a window that
has not started cannot exist, so anything spent rules the state out on its own.

**The row is Claude's idle shape, not a new one.** `sessionIdle` already means "no window exists
server-side, so there is nothing to pace and nothing to count down to", and the view answers it with
a green knobless track, the status word `ready to start`, and no detail line. Reaching for it keeps
a state the user has already met from arriving in a second dialect.

The alternatives both make the row worse. Rendering **no countdown** means `resetLine: nil`, which
draws `resetting…` — a claim that a reset is happening this second, a second false statement rather
than a fix for the first. **Reconstructing an anchor** the way
[ADR-0107](0107-weekly-reset-reconstructed-from-the-last-known-one.md) does for Claude has nothing to
roll forward: that works because Anthropic's weekly resets sit on a stable per-plan grid, and Codex's
do not — a rolling window's next reset depends on a first spend that has not happened.

**The raw value stays observable.** Troubleshoot gains a `Reported resets` line carrying the epoch
seconds verbatim. With no countdown drawn, that is the only surface left showing what the server
actually sent, and it is the evidence the state rests on.

## Consequences

- **TokenPace now runs a program on the user's machine to fetch data.** That is a different class of
  act from an HTTP GET, which is why the switch is off by default and why the Settings footer says in
  plain words what runs and that the email is never read.
- **The Codex plate can carry bars.** It was status-only; a plate now stands on either half, so a
  user with every Codex status service off but the quota on still sees a plate.
- **A failed read drops the bars rather than freezing them.** A stale percentage under a
  live-looking bar is worse than no bar. The reason lands in Troubleshoot, not in the popup's warning
  banner — that banner is Claude's, and a Codex failure surfacing there would read as a problem with
  the bars above it.
- **A `swift run` with no `TOKENPACE_STUB` will not exercise this.** A dev build with no stub resolves
  to the frozen screenshot frame, so the collector is never built; the live path needs
  `TOKENPACE_STUB=real`. This cost a diagnosis session and is worth knowing before the next one.
- **The retry-and-cooldown means a broken install goes quiet for five minutes at a time**, so a user
  who fixes their `codex` mid-cooldown waits up to five minutes for the bars, rather than seeing them
  at the next tick.
- **A Codex row can now be idle**, which the plate previously had no path to. Its detail line is
  dropped the way Claude's idle 5-hour row drops its own, and the spoken label takes the status word
  in place of the `0%` the sighted render omits.
- **A window sitting at 0 % for its whole life would read as never started.** That is the state's
  correct reading — the window genuinely has not begun accruing — and it self-corrects on the first
  spend, when `utilization` rises and the reset anchors.
- **`PacingModel.blueBehindWidthSeconds`'s proportional fallback is now reachable from real data.** Its
  docblock said it was only reachable from synthetic layouts; that sentence is rewritten, and any
  future window whose length is neither 5 h nor 7 d takes the `0.20 · duration` branch by design.

## Alternatives considered

- **A long-lived `app-server` process**, as originally planned. The measurements in D1 do not support
  it: 0.03 s of spawn against 0.44 s of network.
- **Spawning `codex --version`** to learn the version. The `initialize` reply already carries it in
  `userAgent`; a second spawn learns what the first said.
- **Calling `account/read` for the sign-in state.** It returns the email (D4).
- **Reading `rateLimitsByLimitId.codex`.** Byte-identical to `rateLimits`, and keyed by a limit id the
  server is free to rename.
- **Detecting an old Codex on `-32601`.** The server does not use it; it answers `-32600` (D3).
- **Detecting it on `-32600` alone.** That is also a malformed-`params` response, so our own bug would
  be reported as the user's out-of-date install (D3).
- **New `LimitWindow` cases for Codex's windows.** The duration is data, and an enum lists only what
  existed when it was written (D6).
- **Deriving `subdivisions` arithmetically** instead of by lookup. A week over an hour is 168 ticks
  (D6).
- **Appending Codex rows to `layout.rows`** and letting the plates slice the array. It renumbers the
  indices the blocking badge is keyed to (D7).
- **Synthesizing a 5-hour row** for symmetry with Claude's plate (D5).
- **Journalling the quota now**, by writing a zeroed 5-hour window beside the real 7-day one. That is
  the invention D5 forbids, made permanent by an append-only file (D11).
- **`usageEnabled` default-on**, for consistency with every other monitoring flag. Answered in
  [ADR-0125](0125-codex-as-a-status-provider.md) §D6: it spawns a process, and onboarding is the
  answer to discoverability.

## Verification

Stubs, none of which spawns a process — the source is a canned one under every scenario, so a stub
renders identically on a machine that has never installed `codex`: `codex-quota-green`,
`codex-quota-orange`, `codex-quota-exhausted`, `codex-two-windows` (the only way to see the N>1 path
before the server sends a `secondary`), `codex-quota-not-started` (D13, on the real clock so the raw
epoch in Troubleshoot visibly creeps), `codex-not-signed-in`, `codex-cli-missing`, `codex-cli-old`.

Live, against the real `codex`: the 7-day window renders with **one** row and no 5-hour row, the plan
reads `Plus`, and two reads three minutes apart each logged `codex quota: 1 window(s)`.

**D13 against the live account**, through the production path — decode, normalize, rows — by the
opt-in `LiveCodexQuotaCheck` (skipped unless `TOKENPACE_LIVE_CODEX` names the binary, so `swift test`
never spawns a process). Three reads: offsets from a whole window of `0 s, −1 s, 0 s`, the reset
advancing 13 s across 13 s of wall clock, and every read yielding `hasNotStarted == true` with a row
that is `sessionIdle` and carries no reset line. It exists because a frozen fixture cannot show a
value that moves between reads, and the movement is the whole defect.

**Process hygiene, observed rather than assumed.** A sampler parented-matched on the dev app saw the
child in 14 samples with `max_concurrent=1`, and none between reads. An earlier sampler reported a
clean zero while failing to see a control child started by hand — the "quiet answer read as a pass"
trap, caught by validating the sampler against a child of known-live provenance before trusting its
negative.

**Privacy audit.** A full poll cycle's log plus the run's journal: zero email matches, zero
`codexHome`, zero `.codex` paths, zero reset-credit ids, zero raw payload fields. The journal carried
`usage` and `status` records only — no quota record, per D11.

## Related

- [ADR-0125](0125-codex-as-a-status-provider.md) — the provider this completes, and the `usageEnabled` switch it declared
- [ADR-0017](0017-delegated-token-refresh.md) — the other subprocess, spawned for a side effect rather than for data
- [ADR-0124](0124-journal-records-carry-their-provider.md) — the per-provider clocks this deliberately leaves unused
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — the pure-core split the wire model and normalizer follow
- [ADR-0107](0107-weekly-reset-reconstructed-from-the-last-known-one.md) — the same creeping shape on Claude's side, where a stable weekly grid makes reconstruction possible and D13's rolling window does not
- [#501](https://github.com/artem-from-ua/tokenpace/issues/501), [#504](https://github.com/artem-from-ua/tokenpace/issues/504), [#508](https://github.com/artem-from-ua/tokenpace/issues/508), [#515](https://github.com/artem-from-ua/tokenpace/issues/515)
