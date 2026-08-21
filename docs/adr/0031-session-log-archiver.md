---
status: accepted
date: 2026-07-25
---

# ADR-0031: Raw Claude Code session log archiver (accumulate-only)

## Context

Claude Code by default **automatically deletes** its data older than `cleanupPeriodDays` (default
**30 days**), and does so **on every CLI startup**
([docs](https://code.claude.com/docs/en/claude-directory.md)). That means the full transcript of
every session (`~/.claude/projects/<proj>/<session-id>.jsonl`), subagent transcripts, exported tool
outputs, file snapshots for checkpoint-restore, and plans vanish without a trace after a month. This
isn't a bug, it's documented retention policy — but users who want to keep the full history of their
sessions (retrospectives, searching old conversations, analytics) lose it.

Issue [#110](https://github.com/artem-from-ua/tokenpace/issues/110): TokenPace should be able to
periodically copy these logs into a folder the user specifies, and — crucially — **never delete from
the archive what Claude Code has already cleaned up at the source**, so the archive outlives the
30-day cleanup.

Forks in the road: (1) where the feature lives — a separate launchd script or inside the app; (2)
what does the copying — external `rsync` or native Swift.

## Decision

**Built into TokenPace, accumulate-only, native Swift.**

### 1. Shape — inside the app, not a separate launchd agent

TokenPace is a long-lived menu-bar process with the heartbeat of a live polling loop. Sync is just
another "due on heartbeat" duty alongside checking for updates (`UpdateCheckCadence`) and status
(`StatusCadence`). A separate launchd agent would duplicate the scheduler, config, and UI that
already exist in the app. The cost — sync doesn't run when the app is off — is acceptable for a
utility that already lives in the menu bar around the clock (with a default 30-day window, a
once-a-day sync has a huge margin).

### 2. Cadence — once a day, marker advances only on success

`ArchiveCadence` (Kit) mirrors `UpdateCheckCadence`: a 24-hour window, `isDue(lastSync:now:)`, `nil` →
due. Unlike the update check, the `lastArchiveSync` marker only advances on a **successful** sync
(not on every attempt), because there's no third-party API here to be polite to — a failed sync
(an unwritable folder) stays due and retries on the next heartbeat, like `StatusCadence`.

### 3. Mechanism — native Swift `FileManager`, not `rsync`

The heart of the feature — the decision of "which files to copy" — lives as a **pure, testable
function** `ArchiveSyncPlan.filesToCopy` in the kit, alongside all the other project logic
(`PacingModel`, `UpdateCheckCadence`, `MigrationPlan`). This follows the pure-core / thin-shell
convention ([ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md),
[ADR-0023](0023-persisted-config-version-marker.md)). `rsync` would invert this: it would hide the
actual decision inside an unobservable external process that can't be unit-tested, depends on a
binary (Apple's rsync is a fork of openrsync, and flags vary between macOS versions), and adds
friction with the hardened runtime of a signed `.app`. The shell (`LogArchiver`) does I/O only: tree
traversal, calling the plan, copying.

### 4. Accumulate-only — by construction, no `--delete`

`ArchiveSyncPlan` **never returns deletions**. A file Claude Code has cleaned up is simply absent from
the source snapshot, so it never makes the copy list, and its copy in the archive is left untouched.
The archive grows monotonically. (The rsync equivalent is simply **without** `--delete`.)

A file is (re-)copied when it is **new** or **changed** — the source is newer by mtime **or** differs
in size. The size comparison is mandatory, because session `.jsonl` files are *appended to* as the
session goes on: a file that grew without its (coarse) mtime changing still needs to be recopied.

### 5. Sources — an explicit allow-list, not "everything minus an exclude"

Only per-session history folders subject to cleanup are copied: `projects/` (transcripts +
`subagents/` + `tool-results/`), `file-history/` (file snapshots), `plans/`. An allow-list, rather
than "all of `~/.claude` except secrets," guarantees that `.credentials.json` and any tokens
**physically cannot** end up in the archive — a critical project rule (never log, never copy
credentials). Ephemeral data (`session-env/`, `shell-snapshots/`, `tasks/`, caches, `sessions/`) and
whatever cleanup doesn't touch (`history.jsonl`, `stats-cache.json`) are not archived — they're either
regeneratable or never lost.

### 5a. Environment gates — a silent defer on battery, a block on low space

*Added in [#306](https://github.com/artem-from-ua/tokenpace/issues/306).* Originally the archiver had
no gate at all — the one out of five periodic tasks that writes noticeable amounts of data to disk.
Symmetric to §3a of [ADR-0033](0033-automatic-update-install.md), two were added, but with
**different** semantics, and that difference is the substance of the decision.

**Battery — defer**, as with updates: the condition is transient and self-corrects, so no state is
persisted, the marker isn't moved, and the next heartbeat re-evaluates. The gate sits in
`pollArchiveIfDue` **after** the cadence check (otherwise a disconnected Mac would log every poll) and
**not** in `performArchiveSync` — a manual "Archive Now" and folder selection go through the latter,
and that's an explicit user intent.

**Free space — block**, not defer: a full disk doesn't resolve itself, so the next heartbeat changes
nothing. The decision is a pure `ArchiveSpacePlan.verdict`; the threshold is the **same 5 GB** as
`UpdateInstallPlan.minFreeBytesAfterDownload` (one promise, "TokenPace never runs the disk to the
edge," is simpler to explain than two different numbers), and it's measured on the **destination
volume**, since the archive is usually on an external disk.

**Both states are visible in the UI as a ⚠ row.** Silently deferring would leave the user with a
frozen "Last archived" date and no explanation — regardless of whether the cause resolves on its own.
The difference between the states lives in the **text** ("free up space" versus "will resume when you
plug in"), not in the styling: a row about a condition blocking the feature is a warning. Without the
triangle, the project only draws hints that *describe* a control's action. When both gates are closed,
**only** the space row is shown — two rows would suggest that plugging in would help, and it wouldn't.

The battery gate is deliberately **not** wrapped into a pure type: the two gates live at different
times and have different bypass rules, so a shared `decide` would force every call site to pass a
fake value for the gate it isn't evaluating. The battery one is a single `guard` with no arithmetic —
nothing to test in it.

Because of the space gate, `sync` became **two-phase**: first, scanning all roots into an aggregate
plan, then the check, and only then copying. The gate has to judge the whole run — otherwise it would
copy two roots and refuse on the third, leaving the archive half-updated.

### 5b. Atomic replace — a fix to the §4 invariant

*Fixed in [#306](https://github.com/artem-from-ua/tokenpace/issues/306).* `copyReplacing` did a
remove-then-copy despite its docstring saying "atomically replacing." That **contradicted the
accumulate-only promise of §4**: on `ENOSPC` the archive's copy was already deleted, and the new one
wasn't written — so the archive lost a file for which it was often the last remaining copy. In other
words, the worst failure mode occurred exactly when the archive was the only source of the data.

Now it's `replaceItemAt` via a staging copy **next to the target**. Two constraints shape this:
`replaceItemAt` **moves** and consumes its second argument (handing it a file from `~/.claude` would
mean deleting the original log), and the swap must be same-volume, otherwise it degenerates into a
copy. The staging name starts with a dot, because `scan` runs with `.skipsHiddenFiles` — a file
orphaned by a crash doesn't count as archived. The source's mtime is preserved in the process, which
is critical: it's exactly what `ArchiveSyncPlan` compares, and losing it would mean silently
recopying the entire archive every day.

### 6. Folder access — no sandbox, no bookmark

The app isn't sandboxed (no entitlements), so accessing an arbitrary folder doesn't need a
security-scoped bookmark. `NSOpenPanel` in Settings is just a convenient way to pick a path; it's
stored as a plain string in `PersistedConfig`.

## Consequences

- The full session history outlives Claude Code's 30-day cleanup, in the user's own folder.
- The "what to copy / what to keep" logic is unit-tested (`ArchiveSyncPlanTests`,
  `ArchiveCadenceTests`).
- Sync only runs while TokenPace is running — a trade-off against duplicating the scheduler in
  launchd.
- A new `archive` logging category; file paths only at `.debug` (they contain project names).
- The feature is opt-in (default-off) and inert until a folder is chosen.
- Sync doesn't run on battery — on an unplugged laptop, the archive "freezes" until reconnected
  (#306). A deliberate trade-off: the daily cadence has a large margin against the 30-day cleanup
  window.
- A full destination disk stops the backup **with a visible reason**, rather than silently (#306).

## Verification

`swift build && swift test` (`ArchiveSyncPlan`: new/unchanged/grew/pruned/mixed; `ArchiveCadence`:
nil/boundary/before/after; `ArchiveSpacePlan`: the boundary from both sides, an empty plan, fail-open,
threshold parity with `UpdateInstallPlan`). Live: Settings → enable, pick a folder, "Archive now" →
check the mirror of `projects/`/`file-history/`/`plans/`; delete a `.jsonl` at the source → sync → the
file remains in the archive (accumulate); append a line to the source → sync → the archive copy grew.

For the gates (#306) — stub `TOKENPACE_FAKE_ARCHIVE_GATE=battery,space` and the checklist in
[ui-verification.md](../guides/ui-verification.md). The cheapest check for §5b: run "Archive Now"
twice in a row — the second run should copy **0** files; a nonzero count means the swap lost mtime.
