---
status: accepted
date: 2026-08-04
superseded_by: [0123]
---

# ADR-0067: Local usage journal (append-only JSONL)

> **Partially superseded by [ADR-0123](0123-one-line-per-error-run-and-a-floor-on-signal-driven-polls.md).**
> Only the `error` line's shape is superseded: it now carries `v`, `detail` (the not-sent reason §1's
> taxonomy never listed), and `n`/`tEnd`, because consecutive identical failures are written as one
> record rather than one per attempt — a reader must sum `n ?? 1` rather than count lines. **The
> decision itself still stands in full**: the append-only JSONL, the `kind` discriminator and its four
> shapes, tolerant decoding, the derived states on `usage` lines, default-off collection with a
> Settings toggle, monthly rotation, `flock` across instances, and the permanently-kept `.v<n>.bak`
> backups.

## Context

TokenPace polls `GET /api/oauth/usage` every 3 min (15 min when idle, ADR-0032), renders the
result, and **discards** it. On `main` (v0.64.0), nothing but `LogArchiver` (ADR-0031) writes to
disk, and every `PersistedConfig` key is either config or a one-shot edge marker
(`backToWorkWasBlocked`, `extraUsageWasOnCredits`, `lastArchiveSync`) — enough to catch an edge,
never enough to hold a time series. So the app answers "am I on pace *right now*" and answers no
question at all about *yesterday*.

Issue [#238](https://github.com/artem-from-ua/tokenpace/issues/238) (the Insights epic) proposes
**one append-only journal** that consumer features (#239/#240/#241) and the Insights pipeline
itself (aggregator #244 → window+pilot chart #245) read, instead of each one growing its own
storage. This ADR settles the decision for step 1
([#242](https://github.com/artem-from-ua/tokenpace/issues/242)) — the collector and storage.

The forks: (1) format and storage mechanism; (2) exactly what to store — raw fields, or derived
states too; (3) default-on or off; (4) location; (5) how to survive several app instances writing
at once.

## Decision

**Append-only JSONL under Application Support, default-off, heterogeneous `kind` rows with raw
fields + derived states, monthly rotation by filename, `flock` across instances.**

### 1. Format — append-only JSONL, heterogeneous `kind` rows

One object per line, tagged by `kind`: `usage` (a successful usage poll), `error` (a failed one:
429/timeout/network/auth/JSON-parse), `status` (a separate status poll), `resume` (a gap marker).
Decoding is **tolerant** (like `MonitoredServices`/`StatusSummary`): an unknown `kind`/key is
ignored, not thrown on; new fields are added as new keys. The reader (`JournalReader`) tolerates a
corrupted/truncated trailing line (a crash mid-append) — it skips it rather than failing.

**Not App Group.** ADR-0065 (WidgetKit, `draft`) plans to write a snapshot into an App Group
container, but that isn't implemented and has an open question of its own (App Group without full
sandboxing). The journal is the first write of a decoded snapshot to disk; it doesn't wait for the
widget.

### 2. Content — raw fields **and** the derived states the app shows in the UI

Downstream shouldn't have to recompute what the app already computed. A `usage` row carries: all 4
windows (`utilization`+`resets_at`), per-model `weekly_scoped` limits, `sessionIdle`, the full
`SpendInfo` (`Money` as `amount_minor`+`currency`+`exponent`, with no cent loss) — **plus**
derived values: `timePct` (the elapsed fraction), `sev` (the objective color bucket), credits'
`spentFrac`/`monthPct`, the `blocked`/`credits` flags, `hasBrokenActiveReset`,
`BlockingReset.Choice`. Plus `ms` (the API response latency) and `plan`/`tier` — plan metadata
from the Keychain (`subscriptionType`/`rateLimitTier`, **not secrets**: limits and pacing vary by
plan, so they're useful for attributing the series; they flow through
`TokenCredentials`→`TokenDiagnostics`, never the token itself).

**`sev` — "control-freak mode."** The color bucket (`blue`/`green`/`yellow`/`orange`/`red`,
`PacingBucket`) is computed from raw data **independently of the user's cosmetic settings**:
`CalmColorMode` is not applied, so the series stays comparable across users.

> Updated by [ADR-0081](0081-weekly-capacity-gate-for-blue.md): there used to be a second
> exception here — the threshold was computed from a fixed formula, ignoring
> `FarBehindInterval`. That option is gone, and the journal, in turn, **does respect** its
> successor, `BarLayout.blueAllowed` (the weekly-capacity gate): that isn't cosmetics, it's a fact
> about the data, so `sev` now equals the color the user actually saw.

**Errors — a journal-specific taxonomy, not the UI's.** `error.reason` distinguishes more
precisely than the impoverished `FailureReason`: **4xx→`clientProblem`** (429 — a client-side rate
limit), **5xx→`serverProblem`**, **decode→`decode`** (a malformed 200), **401/403→`auth`**,
transport → `timeout`/`dns`/`network`.

### 3. Default-off + a Settings toggle

Mirrors `archiveEnabled` (ADR-0031): opt-in, inert until turned on. The journal writes
percentages/amounts (not transcripts), so privacy exposure is weaker than the archiver's — but
"writing to disk without asking" is a habit we don't start. **Settings only configures the
collector** — the "Record usage history" toggle lives in **General**. Viewing the data is a
separate surface: a **dedicated "Insights" window** (styled like Settings), opened from the
**first item of the dropdown menu, "Insights…"** (with a separator after it). In #242 this window
is a placeholder shell; the pipeline fills it in later: the aggregator turning
`[JournalRecord]` into days×hours (#244), and the window with the pilot chart (#245); separate
consumer features (#239/#240/#241) read the same journal.

**We write only against live, real data.** A write happens only when the toggle is on **and**
`currentScenario == .realNetwork` — synthetic `TOKENPACE_STUB` data must never land in the
journal.

### 4. Location — Application Support, monthly rotation, dev/release isolation

`~/Library/Application Support/com.artem-n.tokenpace/usage-journal[-dev]-YYYY-MM.jsonl`:
- **`-YYYY-MM`** from the row's UTC timestamp — a natural monthly rotation for future log rotation
  and a bounded file size.
- **`-dev`** if the bundle is running **not** from `/Applications` (`swift run` / a dev build) —
  so a dev build doesn't pollute the real release journal that the maintainer runs from
  `/Applications`.
- A fixed folder (app-managed state), with no folder picker — unlike the archiver, this is not a
  user-facing file.

**Dev override:** `TOKENPACE_JOURNAL_FILE=<path>` routes every write to a single file; the
generator `TOKENPACE_GENERATE_JOURNAL=<days>` (`JournalFixture`) writes a multi-day journal to it
for verifying downstream readers.

**The limit of the `-dev` suffix.** It separates a *dev build* from a release, but it does **not**
separate "work" from "test": a copy from `/Applications`, run to verify a feature that needs
signing, writes to the **same** `usage-journal-YYYY-MM.jsonl` as production use. Only the
`.realNetwork` gate holds back stub synthetics; `TOKENPACE_GENERATE_JOURNAL` gets past it
(deliberately bypassing live-only gates), as do `resume` rows from restarts (`lastWriteInstant` is
in-memory) and the unconditional `migrateIfNeeded()`, which rewrites the existing file (leaving an
indestructible `.v<n>.bak`). That's why test runs of the notarized copy point the journal through
`TOKENPACE_JOURNAL_FILE` — see
[ui-verification.md § "Usage journal"](../guides/ui-verification.md#usage-journal-242-adr-0067).

### 5. Concurrency — a `flock` advisory lock

Several TokenPace instances writing to one file is the normal case (the notarized release + dev
copies). On macOS, `O_APPEND` is only atomic up to ~256 B, and a row is 300–700 B → without a
lock, lines from different processes interleave. Every append takes `flock(LOCK_EX)`; contention
is essentially zero (one write every 3 min).

### 6. A format version in every row + in-place migration ([#386](https://github.com/artem-from-ua/tokenpace/issues/386))

Every `usage` row carries **`v`** — the sample's format version, monotonically increasing. Not a
file header: the journal is append-only and survives app updates, so a single file legitimately
holds rows of different versions, and a header would only describe the very first of them.

- **v1** — the initial shape (`v` absent reads as 1). `util` holds the value from the API; `gap`
  is a stored field.
- **v2** — `util` now carries the value **the app actually acted on** (for `seven_day` this is
  reconstructed,
  [ADR-0103](0103-weekly-utilization-reconstructed-from-the-five-hour-counter.md)); `raw` holds
  the value straight from the API; `src`/`n` describe the reconstruction.
- **v3** — [ADR-0107](0107-weekly-reset-reconstructed-from-the-last-known-one.md): `src` was
  renamed to `utilSrc`, and `resetSrc` appeared alongside it, because the reset **date** started
  being reconstructed too, so "source" alone stopped answering the question. The migration also
  **rewrites** `reset` and `timePct` in rows written during the weekly API blackout: those held an
  estimate of `now + 7d`, which crept forward on every poll, while `timePct` stayed at zero for
  hours — meaning analysis of those hours read a flat line that never existed. 199 rows were
  restored on the Max journal and 56 on the Pro one, with an error of 0.000 s.

**`gap` and `creditGap` are no longer stored** — they're computable. Both were written with
11–20 digits, while all the actual uncertainty sat in `util` with a 1-pp step: **0.55 MB out of a
4.6 MB** monthly file spent on digits that meant nothing. No reader ever consumed them — they were
only written and checked in tests.

**Precision — one rule, not a table of constants.** For window fractions, the step must be no
coarser than one second on that field's **own** window, i.e. `decimals = ceil(log10(windowSeconds))`:
5 digits for `h5.timePct`, 6 for `d7`/`scoped`, 7 for `monthPct`. Fields stay **dimensionless
fractions**, not seconds: seconds would give precision without a rule, but the reader would then
need to know the window's length — and for `scoped` rows, **which** window it's borrowing, too.

**Migration — a rewrite, not a rename.** Every v1 row already contains `h5.util`, `d7.util`, and a
timestamp (verified: **100%** of records), i.e. exactly what reconstruction needs. So `util` is
filled in by **the same algorithm that runs live**, replayed over history in order: nothing is
invented. Migrated rows carry an ordinary `src` — the algorithm and the result are the same, so a
separate marker would imply a difference that doesn't exist.

**`.v<n>.bak` backups are kept forever.** After migration, `util` is no longer a raw value, so the
backup is the only record of what the server actually returned; if a flaw ever turns up in the
algorithm, history can only be reconstructed from there. The app never deletes them — that's the
maintainer's call.

**The suffix names the version the backup contains** ([#401](https://github.com/artem-from-ua/tokenpace/issues/401)).
It started out as the hardcoded `.v1.bak` — an accurate description while there was only one
migration, and a wrong one the moment there were two: the v2 → v3 pass found the existing
`.v1.bak`, **correctly** refused to overwrite it (older evidence), and instead **deleted the v2
file itself**. The archive jumped v1 → v3 with no intermediate state — which is exactly what
happened on the maintainer's live journal.

Now every generation leaves its own backup: a file taken through v1 → v2 → v3 gets both a
`.v1.bak` and a `.v2.bak`, so any step can be checked independently, without replaying the earlier
ones. The version comes from the migration itself (`Outcome.migratedFromVersion` — the
**smallest** of the versions rewritten, since an append-only file legitimately holds several
generations, and the label must match the oldest). Existing `.v1.bak` files need no renaming: they
hold v1 and are already correctly named under the new rule.

Three properties the migration must uphold, each verified on live journals:

- **an unparseable line** is carried across byte-for-byte and counted (a truncated tail after a
  crash);
- **out-of-order timestamps** — a real case was found (11:03 before 10:37, two processes writing
  under `flock`). Such a row is rewritten from its own values, but it **does not teach** the
  estimator, or it would register a drop in spending that never happened;
- **state carries across files** — the journal is monthly, and a cold start every month would
  otherwise leave every row of it anchored to an inherited value for no reason.

**Files are not selected by prefix.** `usage-journal-` is also a prefix of `usage-journal-dev-…`,
so a naive `hasPrefix` lets the **release** build migrate dev journals that aren't its own. This
was caught before the first live migration — on a machine where the dev file happened to already
be current, so the damage would have been **invisible**, not absent. The predicate was pulled out
into `JournalMigration.belongsToBuild` specifically so it could be covered by a test: the shell
target has no tests, and that's exactly how the bug slipped through.

Atomicity comes from a `rename` pair: the new file is written alongside the old one and `fsync`'d,
the original is moved aside to `.v<n>.bak`, and only then does the new one take its place. A
failure at any step leaves either the old file or the new one — never a half-written one. There's
no race with concurrent appends **by construction**: `UsageJournal` is an actor, so a rewrite and
an `append` can never run at the same time.

## Consequences

- **History starts on release day** — no backfill; that's the argument for shipping the collector
  before the features that read it, not after.
- **Gaps are first-class.** The 3/15-min cadence plus `pausePollingWhenScreenLocked` punch holes in
  the series by design. `resume` markers distinguish "nothing happened" from "we weren't
  watching"; the reader **never interpolates** across a gap (the same honesty as
  `ServiceStatus.unknown` / idle, ADR-0027).
- **A write never breaks a poll.** `UsageJournal.append` doesn't throw and dispatches off-actor; on
  any error, it logs and drops.
- **No rotation code.** ~480 polls/day × ~70–300 B ≈ a few MB/month; monthly files turn rotation
  into a matter of `rm`-ing old files, not app logic.
- **A clean Kit/shell boundary** (ADR-0009): the row types, factories, `PacingBucket`, gap, and
  reader are pure and tested in the Kit; the shell does only `flock` I/O and naming.
- **`sev` ignores only `CalmColorMode`** — the cosmetics; it respects `blueAllowed` (the weekly
  gate), so the bucket matches the color actually seen
  ([ADR-0081](0081-weekly-capacity-gate-for-blue.md)).
