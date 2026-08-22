---
status: accepted
date: 2026-08-03
---

# ADR-0066: Detecting Claude Code sessions that are awaiting the user's input

## Context

The idea came up of showing a counter in TokenPace along the lines of "N awaiting input" — how many
local Claude Code sessions are currently **waiting for the user to react** (a permission prompt, a
plan confirmation, a question at the end of a turn, `login required`). This is the same state that
the native agent list (FleetView) labels as **"Needs input"**.

The question at the fork: **where to get that state from** — and how to do it without burning
resources (the app polls its source periodically, alongside the usage API poll loop).

The sources considered (all of them local files under `~/.claude/`, read-only):

1. **`~/.claude/projects/<proj>/<sessionId>.jsonl`** — full transcripts. The hypothesis: the last
   assistant record ended the turn (`stop_reason == end_turn`, or an `AskUserQuestion`/
   `ExitPlanMode` block) and there is no user reply after it → "awaiting input".
2. **`~/.claude/sessions/<pid>.json`** — tiny (~400 B) real-time state files, one per live session.
   The `status` field: `busy` | `waiting` | `idle`.
3. **`~/.claude/jobs/<jobId>/state.json`** — the aggregated session state computed by the daemon.
   The fields: `state` (`working`/`blocked`/`done`), `tempo` (`active`/`blocked`/`idle`), `needs`
   (text along the lines of `"approve plan"` — present **only** when a reaction is required).

Empirical testing on live sessions (v2.1.212) surfaced the decisive facts:

- **The JSONL is unreliable and misleading.** Two opposite situations produce the same transcript
  tail: a session genuinely waiting on approve-plan and a session working away both end with a
  `user`/`tool_result` record. An `ExitPlanMode` or a permission prompt does not land in the
  transcript as a closing turn. On top of that, the tail is stuffed with meta records (`mode`,
  `permission-mode`, `last-prompt`, `attachment`, `ai-title`, `agent-name`, `system` and so on) that
  have to be filtered out. The signal from the JSONL matched the real state only some of the time.
- **`sessions/status == "waiting"` is a direct real-time signal**, but a **narrower** one: it covers
  an active permission/plan prompt, but the semantic "ended the turn with a question, waiting for
  confirmation" still sometimes gets written as `idle`. An example: a session with `status: "idle"`
  whose `state.json` already knew `needs: "confirm the edit…"` — on the FleetView screen it sits in
  the "Needs input" list.
- **`jobs/<jobId>/state.json → needs` is the most accurate marker**, because the daemon itself
  computes it (the same daemon that draws FleetView) and it covers **every** waiting substate under
  one flag: permission, approve-plan, end-turn-with-a-question, login-required. A bonus: the `needs`
  text is a ready-made hint for a tooltip ("approve plan", "confirm the edit…").

## Decision

**Count "awaiting input" from two cheap sources (OR), joining them only over live sessions. Do not
read the JSONL at all.**

```
needsInput(session) =
   alive(session) AND (
         sessions/<pid>.json.status == "waiting"
      OR (status != "busy" AND fresh(state.json) AND jobs/<jobId>/state.json.needs != null)
      OR (status != "busy" AND fresh(state.json) AND jobs/<jobId>/state.json.tempo == "blocked"))

alive(session) =
      the process with session.pid exists AND its p_starttime == session.procStart
      (unreadable pid/procStart → fail open: treat it as alive; see postscript #275)

fresh(state.json) =
      state.json.updatedAt (ISO) >= session.statusUpdatedAt (ms) − 60 s
      (unavailable timestamp → fail open: treat it as fresh)

working(session)  =  status == "busy"  OR  state.json.state == "working"
idle/done         =  otherwise
```

> **The freshness guard (see the postscript below).** The `needs`/`tempo` branches come from
> `state.json`, which Claude Code's **own** scanner updates. For worktree sessions that scanner
> desynchronizes and **freezes** `state.json` at a past phase — so we take those two branches into
> account only while `state.json` is not older than the live session file. `status == "waiting"`
> (step 1) is unconditional. Failing open preserves the previous behavior wherever the timestamp
> could not be read.

- The list comes from **live** `sessions/*.json` (there are only a handful). For each one we take
  the `jobId` and look **only** into `jobs/<jobId>/state.json` — we never scan the whole of `jobs/`
  (it holds tens to hundreds of **dead** directories from finished sessions; scanning all of them
  would give a falsely inflated counter).
- `sessions/*.json` is written compactly (`"status":"waiting"`), `state.json` with whitespace
  (`"needs": "approve plan"`). So the reading patterns have to tolerate whitespace; a full
  `JSONDecoder` is unnecessary — targeted regexes over three or four fields are enough.
- We show the `needs` text as a hint (a tooltip or a second line), the way FleetView does.

### Why this way (the cost)

Measured against real files:

| Approach | Files / bytes | Time |
| --- | --- | --- |
| Scanning the JSONL transcripts (wrong) | 102 files, ~20 MB of tails | tens of ms plus the hassle |
| `sessions/*.json` + `jobs/<jobId>/state.json` | ~14 tiny files, a few KB | **0.18 ms** (Swift, substring) |

### Cadence: FSEvents (the main channel) plus a rare safety poll

> The full design of the refresh pipeline (FSEvents plus the safety poll plus the mtime cache,
> gating, debouncing, logging discipline) lives in
> [docs/design/awaiting-input-refresh.md](../design/awaiting-input-refresh.md).

Updating the counter is **event-driven through FSEvents**, not pure polling. We subscribe to the
`~/.claude/sessions` and `~/.claude/jobs` trees (`FSEventStreamCreate` plus
`kFSEventStreamCreateFlagFileEvents`); the system wakes us with a **list of changed paths** rather
than on a timer. The `latency` parameter (~0.5–1 s) coalesces a burst of changes into one batch — for
each batch we do **one** incremental scan of the changed paths only.

On top of that — a **very rare safety-net poll (~30–60 s)** to catch up on events FSEvents might
have coalesced or dropped (sleep, logout, overload). This is the same defensive philosophy as
gracefully falling back on an undocumented format — we do not rely on a single fragile channel.

**The "Claude is running and the screen is not locked" gate** maps naturally onto **starting and
stopping the stream**: unlock / a `claude` process appearing → start the stream and do one catch-up
scan; lock / Claude exiting → stop the stream. Those signals already exist in the shell
(`ProcessClaudeActivityProbe`, pause-when-screen-locked). We keep no separate background timer while
idle.

**The channels' trade-offs** (why a hybrid rather than either extreme):

| | Poll every 5 s | FSEvents only | **Hybrid (chosen)** |
| --- | --- | --- | --- |
| CPU at rest | wakes up regardless | ~0 | ~0 (a rare safety poll) |
| Latency | up to 5 s | ~`latency`, near-instant | near-instant |
| Risk of missing an event | low | real (sleep/logout/coalescing) | low (the poll backstops it) |
| Complexity | low | medium (catch-up after sleep) | higher (both channels) |

- **We subscribe to DIRECTORIES, not files.** FSEvents is path/directory-based (not inode/fd). We
  register the two directory paths `sessions/` and `jobs/` (recursively) rather than specific
  `.json` files — because the set of files is a moving target: every new session creates a new
  `sessions/<pid>.json`, and old ones get deleted. An event on the directory covers the creation,
  modification or deletion of anything inside it, so new sessions are picked up on their own. The
  watcher does not inspect the paths in the event — any batch means "the tree changed" → one full
  stateless scan (which re-reads the directory, and therefore the new files too). That also removes
  the problem of atomic overwrites (`write temp + rename` changes the inode, but the path and the
  directory stay put).
- **The scan is stateless, with no cache.** The core (`AwaitingInputScanner`) is a pure value:
  `scan()` reads a handful of sub-KB files every time (~0.18 ms). The `path → (mtime, awaiting)`
  cache was **deliberately removed**: with FSEvents we only scan when the tree has changed anyway, so
  the cache would have saved microseconds at the price of a stateful class and mtime edge cases. **A
  cache only makes sense in a polling design WITHOUT FSEvents** (a frequent timer where most ticks
  change nothing) — if we ever go back to pure polling, that is when to bring the per-session mtime
  cache back.

There is already a precedent for reading `~/.claude/…` — the log archiver (ADR-0031).

## Consequences

**Upsides.** An exact match with what FleetView shows; near-zero cost; a ready-made hint text; no
fragile heuristic transcript parsing.

**Downsides / risks.**

- **A private, undocumented format.** `sessions/*.json`, `jobs/*/state.json` and the fields' values
  (`status`, `state`, `tempo`, `needs`) are Claude Code's internal machinery (observed on
  **v2.1.212**). They can change between versions without warning. A **graceful fallback** is
  mandatory: a missing field, directory or new value → treat it as "not awaiting", the counter does
  not crash, and the feature degrades quietly.
- **Stale files.** `sessions/*.json` can survive a dead process. Before counting one, check liveness
  by `pid` (`kill(pid, 0)`) and/or filter out a very old `statusUpdatedAt`.
- **The sources desynchronize** — which is exactly why we OR both rather than taking `status` alone.
- **Sessions with no `jobId` or no `state.json`** (an interactive one in another repo; a
  freshly-launched one with an empty `state.json`) — the code has to tolerate that and fall back on
  `sessions/status`.
- **Subagents and fan-out.** `state.json.fan[]`/`inFlight.tasks` are subagents inside a job, **not**
  separate sessions. Do not count them as separate "awaiting input" units; the waiting state lives at
  the level of the top-level job.

## Postscript: a freshness guard against a frozen `state.json` (the worktree bug)

After this shipped, a specific instance of the "stale files" risk above turned up, worth its own
record because it produced a **phantom hand that never went down**.

**The symptom.** A worktree session that had long since passed approve-plan (either working on or
already idle) was counted as "awaiting input" forever. In Claude Code's own FleetView it likewise
kept its "Needs input" marker, even though nothing was actually waiting.

**The root cause (in Claude Code, not in us).** The `needs`/`tempo` fields in
`jobs/<jobId>/state.json` are updated not by the session but by a separate daemon scanner that reads
the transcript from a stored `linkScanPath`. For worktree sessions that path is derived from the
**non-worktree** project directory and points at a transcript that is not there (the real one lives
in the directory with the worktree suffix). The scanner never advances → `state.json` **freezes** at
whatever phase it wrote last (typically `needs:"approve plan"` plus `tempo:"blocked"`). The session
meanwhile carries on, while `state.json` still advertises "awaiting".

**Our fix — a freshness guard (`AwaitingInputScanner`).** We trust `needs`/`tempo` **only while
`state.json` is not noticeably older than the live session file** (`sessions/*.json`, which the
daemon rewrites on every status change). We compare `session.statusUpdatedAt` (ms epoch) against
`state.json.updatedAt` (ISO-8601 — a **different format**, parsed separately) with a **60 s**
tolerance for normal inter-process lag. A frozen state lags by minutes to hours, so the guard fires
confidently, while `status == "waiting"` (the direct real-time signal) stays unconditional.

**Fail open.** If either timestamp cannot be read, we treat the state as fresh (that is, behave as we
did before the guard). The guard **only suppresses** a signal it has proven frozen; it never silences
a session whose staleness it cannot demonstrate. So a format defect degrades to the previous behavior
rather than silently losing real "awaiting" sessions.

A workaround on the daemon's side (fixing `linkScanPath` in `state.json`) is possible, but it is a
point fix and it does not hold: a new worktree session will write the wrong path again. The right
final fix belongs in Claude Code itself (deriving `linkScanPath` from `worktreePath`); our guard makes
the feature robust regardless.

## Postscript: a `busy` guard against sticking after a plan is approved

A second instance of the same "the job state lies" family, and one the freshness guard does **not**
catch.

**The symptom.** Right after a plan is approved the hand lights up even though the session is already
working. FleetView at that moment honestly reports `0 awaiting input`, and the session reads
`Working · approve plan`. It goes out on its own, without intervention; it lasts exactly as long as
the turn does — from tens of seconds to tens of minutes in background jobs.

**The evidence (Claude Code v2.1.220).** A snapshot of the live files at a moment when the hand was
lit:

```
sessions/47273.json:  status = "busy"             ← the truth: the session is running a turn
jobs/83af0c92:        needs  = "approve plan"     ← stuck at the approval phase
                      state  = "blocked"
                      tempo  = "blocked"
                      updatedAt = 15:58:25Z       ← frozen at the moment of approval
```

At the moment it went out, the same job read `state:"done"`, `tempo:"idle"`, `needs:null`. So the
daemon rewrites the job state **only at the end of the turn** — until then `needs` keeps advertising
"awaiting".

**Why the freshness guard is powerless here.** It is *relative*: it compares `state.json.updatedAt`
against `session.statusUpdatedAt`. After the approval **both** timestamps freeze at the same instant,
so the pair looks "fresh" (the verdict is `fresh=fresh`) and the stuck `needs` sails through. The
guard closes the case "the job state lags behind a live session"; here nothing lags.

**The fix — `status == "busy"` ⇒ not awaiting.** In this situation the session file is the only one
telling the truth. The condition sits **after** step 1, so a real prompt (`status == "waiting"`)
stays unconditional, and **before** reading the job state, which does not deserve trust in this
phase. This is the very same `working(session)` already defined in "Decision" above — only now it is
actually applied.

**The limits.** The guard trusts the daemon to maintain `status` carefully. If a session ever really
did wait with `status:"busy"`, we would lose that hand — in the snapshots collected, that never
happened (every phantom had `busy`, and the one genuine wait arrived through the `status == "waiting"`
branch).

**Alternatives that stay on the table** if the symptom ever comes back in another form:

- **An absolute stale threshold** — ignore `needs`/`tempo` if `state.json` has not been updated for
  more than N minutes. It catches any freeze without knowing its nature, but N is guesswork: a long
  turn and a genuinely long wait look identical.
- **A liveness check by `pid`** (`kill(pid, 0)`) — filters out orphaned session files of dead
  processes; a risk already named in "Consequences" above and still open.
- **The semantics of `detail`** — a field the daemon now maintains instead of, or alongside, `needs`,
  containing the user's own line (in our snapshot, "давай спробуємо"). Parsing free text is fragile;
  not recommended.

## Postscript: the watcher does not run under data stubs

The watcher's start gate was narrowed with a third condition — `currentScenario == .realNetwork`
(`updateAwaitingInputWatcher()`). The reason: `TOKENPACE_STUB` exists to give a **frozen,
reproducible frame** on canned data, while the watcher reads the **live** `~/.claude/sessions|jobs`.
So under a stub, real state leaked into the frame: the counter jumped around with whatever sessions
happened to be waiting for input at capture time, and the screenshot stopped being deterministic. As
a side effect this also removes the FSEvents stream and the 45-second safety timer on stub runs,
where they serve no purpose.

This is the same gate that already stands over the usage journal (ADR-0067): synthetic data does not
reach live subsystems. The gate is also recomputed when the scenario is switched **live** in dev
tools (#187, ADR-0047), so going from stub to real brings the watcher up without a restart.

The way to check the indicator under a stub is unchanged — `TOKENPACE_AWAITING=N` synthesizes
sessions, bypassing the watcher and the master toggle. In Settings (Extra features → Session status,
Appearance) a stub shows a ⚠️ "Stubbed in this development build."; the toggles stay active, because
the saved value still applies to the next real run.

## Postscript: fragility is declared, not detected (#243)

The "private, undocumented format" risk above has a silent failure mode: if Claude Code renames a
field, the regexes stop matching, the counter goes to **0**, and at zero the indicator hides — so a
broken feature looks exactly like a calm day.

[#243](https://github.com/artem-from-ua/tokenpace/issues/243) proposed **detecting** that: a separate
state for "there are live `sessions/*.json`, but none of them yielded either a `status` or a `jobId`"
plus a line in Troubleshoot. Rejected (closed as not planned) for two reasons:

- **The change is invisible to the user.** The menu bar and the popup stay identical in every state
  (the issue's own author insists on this — a warning in the bar would be worse noise than the bug).
  The only surface is a line in the ⌥-gated Troubleshoot, which is diagnostics for the maintainer,
  not a feature.
- **The shape of the future break is unknown.** Detecting `live > 0, parsed == 0` catches a renamed
  field, but it does **not** catch the directories moving (`live == 0` reads as "Claude is not
  running") and it does **not** catch a partial rename (the counter stays valid but is quietly
  undercounting). One scenario out of three is covered.

**Instead, the fragility is recorded as a property of the feature** — a permanent ⚠️ line under the
toggle in Settings → Extra features → Session status: the feature reads Claude Code's internal files,
which are undocumented and may be changed on Anthropic's side at any time, after which the counter may
stop appearing and disappearing correctly. Unlike the conditional stub hint in the section's header,
this line is visible **always**, including in a release build.

The existing transition log (`AwaitingInputWatcher`, `awaiting-input N → M`) stays as it is: it
records the transition to zero, but does not distinguish a format break from sessions honestly
finishing. Coming back to detection is worth it once the format actually breaks — the real shape of
the failure will suggest a more precise signal.

## Alternatives considered

Instead of polling — Claude Code's own hooks (`Stop`, `Notification`) appending an event to a
hypothetical `~/.tokenpace/awaiting.jsonl` that TokenPace reads. That gives the exact **moment** the
turn returns to the user and does not depend on the internal format of the state files. The downside:
it requires the user to install hooks into their `~/.claude/settings.json` (a setup step, and
fragility across updates). For the first iteration we chose **polling the state files** as
zero-config; hooks are deferred as a possible more precise channel later, if the file format proves
insufficient.

## Postscript: a live network is not enough — it has to be chosen explicitly (#267)

The gate from the previous postscript (`currentScenario == .realNetwork`) turned out to be
insufficient, and it was the watcher that exposed it.

`TOKENPACE_STUB=healthy` — a non-existent id — silently resolved to `.realNetwork` (see ADR-0047's
postscript), so a run intended as stubbed went out to the live network. Visually it looked like a stub
in every respect — except for `hand.raised`, which showed the maintainer's **real** sessions waiting
for input. In other words, the single gate "is this `.realNetwork`?" does not distinguish a live
network that was **chosen** from a live network we merely **ended up in**.

The gate gained a fourth condition — `scenarioWasExplicit`:

```swift
let wantWatcher = PersistedConfig.awaitingInputEnabled
    && awaitingInputStub == nil
    && currentScenario == .realNetwork
    && scenarioWasExplicit
```

Explicit means `TOKENPACE_STUB=real`, picking "Real network (no stub)" in dev tools (`switchScenario`
sets the flag), and an ordinary launch of the installed `.app` with no env — the normal production
mode. We deliberately gate on **intent** rather than on the build type: otherwise it would become
impossible to check the raised hand against live sessions under `swift run`, and that is the only way
to exercise the real scanner (`TOKENPACE_AWAITING=N` short-circuits the watcher and the scanner never
runs).

Nothing changes for the end user.

## Postscript: a "live session" is checked by pid, not assumed (#275)

The decision's formula says "join only over **live** sessions", and the scanner's docstring says the
same. But liveness was an **assumption**: the scanner took every `sessions/*.json` at face value. In
reality a session file outlives its process — only Claude Code's cleanup removes it, after
`cleanupPeriodDays` (30 by default).

The consequence: a `claude` killed or crashed at exactly the moment a permission prompt was on screen
leaves `status:"waiting"` on disk, and there is no one left to overwrite it. The raised hand in the
menu bar stays lit for **weeks** — pointing at a session that does not exist.

So the formula gains an extra conjunct:

```
awaiting = the session's process is alive
       AND ( sessions/<pid>.json .status == "waiting"
          OR (state.json is fresh AND .needs != null / .tempo == "blocked") )
```

The implementation is `ProcessLiveness` (`Sources/TokenPaceKit/ProcessLiveness.swift`), an injected
seam over `sysctl(KERN_PROC_PID)`. Two conditions, both required:

1. **the pid exists** — otherwise the session cannot update its own file;
2. **it is the same process** — the kernel reuses pids, so we check the session file's `procStart` (a
   ctime string in UTC) against the kernel's `p_starttime`. Without that, an unrelated process that
   inherited the same number would "resurrect" a dead session.

**Fail open**, like the rest of the scanner: if the pid or `procStart` cannot be read, we count the
session. The filter only removes what can be **proven** dead; a gap in parsing should degrade to the
previous behavior rather than hide a session the user is genuinely being asked about.

This also replaced the watcher gate's third term ("claude running") from
[awaiting-input-refresh.md](../design/awaiting-input-refresh.md): that gate would have stayed silent
about every session while no `claude` was running, whereas the pid check removes exactly the dead
session — even when other `claude` processes are active.

## Postscript (#438): we show `name`, not `needs`

The decision above assumed: "we show the `needs` text as a hint (a tooltip or a second line), the way
FleetView does". The prediction held — but with a **different field**. Under ⌥ the popup shows the
session's **`name`**, the same title Claude Code's agentic view lists it under.

The reason for the swap: `needs` is a **category of blocking** (`approve plan`, `confirm the edit`),
and it repeats. Three sessions waiting on plan approval would produce three identical lines — an
answer to "what are they busy with", whereas the user under ⌥ is asking "**which one do I go to**".
`name` tells sessions apart and, crucially, is a **shared vocabulary** across two surfaces: the user
sees in the popup the same word they will search for in the agentic view. `needs` stays available —
`state.json` is already read in `isAwaiting` — and may one day enrich the tooltip.

Technical facts recorded during implementation:

- **The name comes from `sessions/<pid>.json`**, which the scanner reads in full anyway. One extra
  regex costs ~2.6 µs (measured) and **zero** additional I/O, so lazy reading "only when ⌥ is held"
  was deliberately rejected: it would have required a second read path and a cache with invalidation
  for a saving smaller than the measurement error.
- **An unnamed session does not have an empty field — it has a placeholder.** Claude Code writes its
  own `jobId` into `name`, that is, the first 8 characters of the `sessionId`. The forms **do not
  match** across files: in `jobs/<id>/state.json` such a name is simply absent. So the detection is a
  disjunction (absent / empty / equal to the `jobId` / equal to `sessionId.prefix(8)`), and it checks
  **equality against the session's own ids**, never the string's shape: a genuine name that happens to
  look like a hex blob stays a name.
- **The placeholder must not be shown**: it reads as an identifier fit for copying, whereas
  `claude --resume` rejects it — it accepts a full UUID **or** a session name (both verified on
  v2.1.228). In its place, the line reads `<unnamed>` in italics.
- **No history of renames exists anywhere** — `name` is overwritten in place, so the current value is
  by construction the latest. The question "are we showing a stale name" falls away for lack of a
  mechanism. A rename is recorded by a separate `nameSource` field (`auto` / `user`), which we do not
  read.
- **A consequence for the watcher's deduplication:** `name` entered `Equatable`, so renaming a session
  now legitimately breaks `result != lastResult` and produces the log line `awaiting-input N → N` with
  no change in the number. That is not a fault — the popup is obliged to show the new name.

## Postscript (#438): projects are sorted by name

The ⌥ breakdown used to sort projects **most-urgent-first** (the most red at the top). Now it sorts by
**name**.

The change was forced and is coherent: the ranking rested on the `2✋ 1✋` chips that used to sit in the
project's row and have now been removed — each hand moved to its own session row. The project header no
longer shows any urgency at all, so ordering by it would mean sorting by a quantity that is not on the
screen: the user would see a list of names with no way to explain their order to themselves.

Sessions within a project run **freshest first** — by descending `daysUntilDeletion`, which is
equivalent to descending `updatedAt` (the scanner computes `daysLeft = cleanupDays − ageDays` with a
single `cleanupDays` for the whole scan). We did not introduce a separate time field, so as not to keep
the same quantity in two coordinate systems. The tiebreak by name, then by project, is **mandatory**
rather than cosmetic: `ageDays` is clamped through `max(0, …)`, so every just-updated session collapses
to the same value, and without a total order the rows would line up in directory-traversal order — and
`AwaitingSessions` is `Equatable`, so the watcher would read every reshuffle as a change.
