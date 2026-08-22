---
status: accepted
date: 2026-08-22
supersedes: []
superseded_by: []
---

# ADR-0117: Claude Code activity is read from session journals, not the process table

> Partially supersedes the **mechanism** named in [ADR-0032](0032-simplified-polling-cadence.md) §D3
> and [ADR-0045](0045-honest-reset-boundary-grace.md) §D5′. Both decisions stand exactly as written
> — the 15-minute idle override and the grace's activity gate are unchanged. What changes is only
> *how* `claudeActive` is computed. [ADR-0017](0017-delegated-token-refresh.md)'s consequence about
> the spawned CLI being visible to the probe no longer holds.

## Context

`PollingEngine` polls the usage API every 180 s while Claude Code is running and every 15 min when
it is not ([ADR-0032](0032-simplified-polling-cadence.md) §D3). Until now `claudeActive` came from
`ProcessClaudeActivityProbe`, which scanned the process table via `sysctl(KERN_PROC_ALL)` for an
entry whose `p_comm` was exactly `claude`.

**The match stopped firing.** Claude Code's native installer lays the binary down as
`~/.local/share/claude/versions/<semver>` and makes `~/.local/bin/claude` a symlink to it. The
kernel records the **real file's** basename in `p_comm`, so every Claude Code process now reports a
version string. Measured on the maintainer's Mac: 516 processes, 12 of them Claude Code (the daemon,
five `bg-pty-host`, five `bg-spare`, one session), and **zero** matches for `claude`.

```
pid 95317  p_comm=[2.1.231]  /Users/artem/.local/share/claude/versions/2.1.231
pid 12944  p_comm=[2.1.228]  /Users/artem/.local/share/claude/versions/2.1.228
```

A controlled experiment ruled out the symlink as a rescue: executing a binary through a symlink
named `faketool` pointing at a file named `9.9.999` yields `p_comm` = `9.9.999`, identical to
executing the real file directly. `p_comm` follows the file, never `argv[0]`.

**The symptom in the field.** Real inter-poll gaps from the maintainer's journal
(`usage-journal-2026-08.jsonl`):

```
22:43:50  193s   ← 3 min
22:46:51  181s
22:53:05  192s
23:12:19  961s   ← 15 min
23:27:20  901s
23:30:00  160s   ← 3 min again
23:46:01  961s
00:01:42  941s
00:17:38  956s
```

The 3-minute stretches were not the probe working. They are **coincidences**: the delegated-refresh
spawn and other short-lived children do carry `argv[0] == "claude"`, and a poll whose instantaneous
process-table snapshot happened to overlap one of them read `true`. Sustained work — background
agents, long runs — was invisible throughout. The user-visible effect: agents burning tokens while
the widget refreshed once a quarter hour.

**A second, quieter symptom.** `claudeActive` is also a conjunct of the reset-boundary grace
([ADR-0045](0045-honest-reset-boundary-grace.md) §D5′). With the probe stuck at `false` the grace
**never armed**, so right after a 5-hour reset the bar could flash the honest "ready to start" while
the user was actively working.

**The deeper problem is not the version string.** A process's name is a private contract of the CLI,
and it broke twice over in one investigation: first `p_comm`, then the subcommand names
(`daemon`, `bg-pty-host`, `bg-spare`) that a name-based filter would have had to enumerate next.
Meanwhile Claude Code leaves a direct, structural trace of the thing we actually care about: it
appends to an on-disk journal on every turn.

## Decision

### D1. Activity means a recent write to a Claude Code journal

`claudeActive` is true when any of three paths under the Claude Code home was modified within
`TranscriptActivityProbe.activityWindow`:

| Source | What it covers |
|---|---|
| `history.jsonl` | the user just typed — someone is at the keyboard, looking at the widget |
| `jobs/**` | a background job is progressing, possibly with no session open |
| `projects/**` | all session shapes: interactive, agent-view, background, and subagents |

Verified on disk that these cover every session shape. All sessions write under one root,
`projects/<slug>/`, where the slug encodes the working directory (a git worktree gets its own
directory, not its own root); subagents nest one level deeper in `<uuid>/subagents/`.

### D2. `history.jsonl` counts as activity, before any token is spent

The probe answers **"does the user need a fresh number now"**, not "are tokens burning right now".
Someone who just submitted a prompt is looking at the menu bar, and spend follows within seconds.
Treating input as a valid refresh trigger follows from what the widget is for; withholding it would
optimize a proxy (evidence of spend) over the goal (fresh data when it is being read).

### D3. Any file counts — no extension filter

An earlier draft matched only `*.jsonl`. Measured, that would have discarded most of the signal:
under `jobs/` the `.jsonl` files are 249 of ~5,800 (against 2,014 `.png` and 1,139 `.log`), and under
`projects/` about a third (1,067 of ~3,100, against 1,169 `.txt` and 809 `.json`). All of it is
written while Claude Code works, so all of it is evidence of the same thing — and matching a suffix
would smuggle back an assumption about a private on-disk format, which is the failure mode this ADR
exists to remove.

### D4. Only mtime is read — never file contents

`jobs/*/timeline.jsonl` records a `state` field, and a sample of the maintainer's tree contained
`working` (1,059), `done` (565), `blocked` (494) and `running` (1). Filtering to the "really
working" states was considered and **rejected**:

- A write means the balance may be moving even when the user is doing nothing directly — a
  background job can burn tokens and only then record that it became `blocked`.
- The state vocabulary is another private contract, i.e. the same class of dependency that just
  broke. Trading a fragile process name for a fragile field name is not a fix.
- The error costs are asymmetric and point one way: guessing "active" wastes one request per three
  minutes; guessing "idle" leaves a quarter hour of stale numbers on screen.

Metadata-only also keeps the walk cheap and makes the answer independent of the record format.

### D5. `activityWindow` is 5 minutes

A transcript is appended on every turn — measured, this session's file trailed the live conversation
by 8 s — so the window only needs to outlast a long stretch of model thinking. Shorter risks a false
"idle" mid-turn; longer drags a tail of 3-minute polling past the end of the work.

### D6. The roots are checked cheapest-first, with an early exit

`history.jsonl` (one `stat`) → `jobs/` (a flat scan) → `projects/` (recursive). The probe stops at
the first root that answers yes, and the index seam answers a *question* ("is anything newer than
this?") rather than returning a listing, so the walk can abandon early.

Measured on the maintainer's tree (~19,900 files under `~/.claude`), 20 runs each:

| Case | Best | Average |
|---|---|---|
| Active machine (a fresh root answers before the recursive walk) | 0.01 ms | 0.01 ms |
| Worst case (nothing fresh → all three roots walked in full) | 70.72 ms | 73.89 ms |

The active case is the common one and costs essentially nothing: `history.jsonl` is one `stat`, and
on a working machine it, or `jobs/`, answers immediately. The worst case — an idle machine — pays
74 ms once every 15 minutes, since that branch *is* the idle override.

Note this got dramatically cheaper when the extension filter went away (§D3): the earlier
`.jsonl`-only version measured 9.79 ms in the active case, because the walk had to skip thousands of
non-matching files before reaching a fresh transcript. Filtering was both less accurate and slower.

### D7. The home directory honors `CLAUDE_CONFIG_DIR`

`TranscriptActivityProbe.defaultClaudeHome()` reads `CLAUDE_CONFIG_DIR` and falls back to
`~/.claude`. That variable relocates the entire tree, and hard-coding the default would reproduce
the exact failure this ADR fixes — a probe blind to a supported installation layout.

### D8. The pure part lives in `TokenPaceKit`

`ProcessClaudeActivityProbe` lived in the `TokenPace` executable target, which the test target does
not depend on — so it had **no tests and structurally could not have any**, which is why a total
detection failure could go unnoticed. `TranscriptActivityProbe` and the `ActivityFileIndex` seam now
live in the kit (the pattern already used by
[`ProcessLiveness`](../../Sources/TokenPaceKit/ProcessLiveness.swift)), with only the `FileManager`
walk left in the shell. The `ClaudeActivityProbe` protocol name and `PollingEngine` are untouched:
the question it answers has not changed, only the evidence used to answer it.

## Consequences

- The 15-minute idle override becomes reachable for the right reason. Previously the app sat in it
  permanently — the branch ADR-0032 §D3 intended as the rare case was the only case.
- The reset-boundary grace (ADR-0045 §D5′) can arm again, fixing the "ready to start" flash during
  active work.
- Activity is now detected for **every** session shape, including background agents with no
  interactive session — the case that prompted this investigation.
- The probe reads the user's `~/.claude` tree. It reads metadata only, never file contents, and
  TokenPace itself never writes there, so there is no feedback loop.
- A machine where Claude Code has never run has no `projects/` or `jobs/` directory. A missing root
  answers "not active", which lands on the conservative cadence.
- The probe is one poll-interval coarse: it cannot see work that started and finished entirely
  between two polls. That was equally true of the process snapshot it replaces.
- Detection is now coupled to Claude Code's on-disk layout instead of its process names. That is a
  contract too, but a broader and more observable one — and unlike a process name, a wrong guess is
  visible in the journal as a cadence that never drops to 180 s.

## Alternatives considered

**Match the executable path via `proc_pidpath()`.** Verified working: it resolved 515 of 516
processes and found all 12 Claude Code ones. Rejected because it keeps activity tied to process
identity. The daemon and `bg-spare` workers live permanently, so "a process exists" would mean
"always active" and would quietly retire the idle override; excluding them by subcommand name would
re-introduce a private-contract dependency, and `bg-pty-host` — which lives as long as any
background job does — has no clean side of that line. Left as the fallback if the journal layout
ever proves unstable.

**Read `~/.claude/sessions/*.json` liveness.** `AwaitingInputScanner.sessionIsLive` already parses
`pid` + `procStart` there, with pid-reuse protection, and is name-independent and tested. Rejected
for *this* change only because it answers "a session process is alive", not "work is happening" —
an open-but-idle session would read active. Tracked as follow-up work; it may become a better
signal, or a complement, once that distinction is settled.

**Filter job timelines by `state`.** See §D3.

**Widen the process-name match** (accept version-shaped `p_comm`, or substring-match `claude`).
Rejected: `p_comm` is truncated to `MAXCOMLEN` (16 chars), so a longer name would be silently cut,
and a substring match would false-positive on the Claude Desktop helpers the original exact match
was written to exclude.

## Related

- [ADR-0032](0032-simplified-polling-cadence.md) — the interval model whose `claudeActive` input this
  redefines.
- [ADR-0045](0045-honest-reset-boundary-grace.md) — the reset-boundary grace, the second consumer.
- [ADR-0017](0017-delegated-token-refresh.md) — delegated refresh; its `binaryCandidates` list has
  the same versioned-path blind spot and is tracked separately.
- [ADR-0066](0066-detect-sessions-awaiting-input.md) — the awaiting-input scanner, which reads the
  same `~/.claude` tree for a different question.
