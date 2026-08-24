---
status: accepted
date: 2026-08-24
---

# ADR-0130: One usage record with a windows array, so any provider fits

## Context

`UsageSample` was Claude-shaped. `h5` and `d7` were **non-optional** `WindowSample`s sitting under
fixed keys, beside `opus`/`sonnet`/`scoped`/`spend`/`credits`/`blockingReset`. Codex reports **one**
7-day window and no 5-hour window at all
([ADR-0127](0127-codex-quota-from-the-app-server.md)), so writing a Codex reading into that shape
meant inventing a 5-hour row — a percentage for a limit the server does not report, under a reset
date fabricated to fill the field. That is the same thing `CodexQuotaNormalizer.rows` already refuses
to do on screen.

The journal is append-only, so a bad shape written once is in every archive forever. That is why
[#504](https://github.com/artem-from-ua/tokenpace/issues/504) deliberately wrote **no** usage records
for Codex and left the quota unjournalled.

Two facts constrain what replaces it.

**Position names no window.** Codex's payload has `primary` and `secondary` slots, and during the
episode in [#515](https://github.com/artem-from-ua/tokenpace/issues/515) the account's five-hour
limit was absent while the weekly window sat in `primary`. A shape that keys on slot order would have
read that week as a five-hour window. Duration is the one identity every provider supplies —
`windowDurationMins` is in the payload, and Claude's two windows have known lengths.

**A faithful shape stores a transient zero faithfully.** Over ~14 hours the maintainer's Codex weekly
window reported `usedPercent: 0` against a horizon that advanced second-for-second with the clock,
then returned to 3 % against a fresh anchor ([#519](https://github.com/artem-from-ua/tokenpace/issues/519)).
Journalled, that stretch would be a permanent record of a reset that never happened, followed by a
return to the prior figure, with nothing in the file marking which readings were real — the same
class of damage the weekly-blackout repair in [ADR-0107](0107-weekly-reset-reconstructed-from-the-last-known-one.md) exists
to undo for Claude, and discoverable only after the fact.

## Decision

### D1. One `kind`, not two — the difference is data

Codex writes `kind: usage` under `provider: codex`. A separate `kind: quota` was proposed and
rejected: **nothing would differ**. Both records answer the same question — how much of a window is
spent and when it resets — and the only difference is which windows exist, which is data. A second
kind would also make the `provider` tag from [ADR-0124](0124-journal-records-carry-their-provider.md)
redundant, since the kind would imply the provider: the same workaround as a separate file, moved
inside the file.

An interim change had landed a **second journal file** for Codex so release builds could collect
something at all. It sat outside `belongsToBuild`, outside the migrations and outside
[journal-analysis.md](../reference/journal-analysis.md), so the provider tagging built for exactly
this case did nothing for the first provider it was built for. It is not reintroduced.

The **dev quota log** (`StatusPayloadLog.recordCodexQuota`, `codex-quota-dev-YYYY-MM.jsonl`) is a
different thing and stays exactly as it is: a raw capture of every payload behind two dev-only gates,
including the readings D5 refuses to journal. It is the evidence a window anomaly is reconstructed
from, which is precisely why it must keep recording what the series does not.

### D2. `windows: [WindowSample]`, each stamped with its own `secs`

`UsageSample` gains `windows`; `h5` and `d7` become **computed lookups by duration** over it, both
`Optional`. `WindowSample` gains `secs` — the window's length in seconds, which already reached its
initializer as the precision parameter and is now stored.

A provider may report **any number of windows, including one**, and none is required. Selection is by
`secs`, never by index: the array's order is the provider's own and carries no meaning.

Of the sample's stored properties only a handful were non-optional, and the Claude-specific ones that
remain (`scoped`, `credits`, `blocked`) already have natural empty states. `h5`/`d7` were the only
genuine obstacle.

### D3. The archive migrates to v6, and the old keys are removed

`UsageSample.currentVersion` moves to 6. The launch migration moves each window into `windows[]` and
**drops** `h5`/`d7` from stored lines.

Writing both spellings was rejected. Duplicated fields in an append-only file are permanent, and a
reader that accepts either one is a branch every consumer carries forever — the argument
[`JournalMigration`](../../Sources/TokenPaceKit/JournalMigration.swift)'s own docblock makes against
tolerant readers. The decoder keeps `h5`/`d7` as **read-only** keys with the same standing ADR-0124
gave the Claude provider fallback: for the lines a rewrite cannot reach — a `.v5.bak`, a line pasted
into a bug report — never as the policy the archive relies on. `UsageSample.encode(to:)` is explicit
so a synthesized encoder can never emit them from the computed accessors.

The pass is a **reshaping**, not a recomputation. Every window keeps its `util`, its reconstruction
state (`utilSrc`/`resetSrc`/`n`, ADR-0107) and its `sevRaw` history; `provider` and `sevV` are
carried across untouched, because the colour model has not moved.

### D4. No new counter, and `changedAnything` is unchanged

A v5 line gaining `windows[]` is a **format** bump, which `migrated` already counts and
`migratedFromVersion` already names the backup after. A separate counter would describe the same
rewrite twice — the argument ADR-0124 §D6 makes for the usage kind. `changedAnything` therefore needs
no addition, and the bold warning on its docblock stays satisfied by construction rather than by
memory.

### D5. A not-started reading is never persisted

A window classified by `CodexQuotaWindow.hasNotStarted(now:)` is **dropped at the factory**, and a
read left with no windows writes no line at all.

It describes the absence of a window, not a measurement of one: the server is answering "if you began
now, it would end then". Stored, it is a real-looking reset at 0 %, and the file cannot be corrected
afterwards. TokenBar reached the same conclusion independently and excludes zero/latent readings at
persistence, so sliding readings never skew historical pacing.

The drop is **per window**, not per read: an anchored window beside a sliding one still gets its line,
carrying only the measurement. Nothing is written in place of the dropped window — an `anchorLost`
event is a separate shape and a separate decision, not a usage sample with a fabricated percentage.

### D6. `UsageGridAggregator` needs no change

It reads a sample's `provider` and `t` and nothing else — the density metric counts polls, not
utilisation. The 5-hour/7-day `UsageGridFilter` is still a documented no-op for that metric, and the
first metric that reads a window will select it by `secs`, the same way every other consumer does.

## Consequences

**Positive**

- A provider with one window, three windows, or a window count that changes between polls fits
  without inventing anything.
- Codex quota is journalled through the ordinary path, so the provider tag, the migrations,
  `belongsToBuild` and the analysis reference all apply to it.
- The archive holds one spelling. No consumer carries an `h5`-or-`windows` branch.
- A transient zero cannot enter the record, so the archive never has to be walked back.

**Negative / accepted costs**

- **Every usage line of every archive is rewritten again** — the third full rewrite in a week, and a
  `.v5.bak` beside each file that is never deleted. What makes it safe is
  [#509](https://github.com/artem-from-ua/tokenpace/issues/509): a backup whose name is taken no
  longer causes the live file to be deleted.
- `h5`/`d7` are now a lookup rather than a field, so reading one costs a scan of a short array. At
  two entries that is not measurable; at a hundred it would be, and nothing today reports a hundred.
- Every window carries a `secs` it did not before — 6 266 usage lines on the maintainer's August
  journal grow by that key each.
- **A gap in the Codex series is ambiguous**: it can mean the window had not started, or that nothing
  was polled. That ambiguity is the price of not writing the sliding readings, and it is the
  direction worth erring in — a missing sample is recoverable by inference, a fabricated one is not.
- `analysis` scripts written against `h5`/`d7` break rather than silently reading the wrong thing.
  Deliberate: a script that kept working while reading `windows[0]` as the five-hour bar would be the
  worse outcome.

## Verification

`swift build && swift test` (1 719 tests), then `LiveJournalMigrationCheck`
(`TOKENPACE_LIVE_JOURNALS=1`, opt-in and read-only) over a **copy** of the maintainer's real archive
— never the archive itself. Beyond what it asserted for ADR-0124 it now asserts that no `h5`/`d7` key
survives the rewrite.

The copy was then migrated for real and censused before and after. On the 9 824-line August journal:
line count preserved, all 6 266 usage lines at v6 with `windows[2]`, every window's `secs` one of
`18000`/`604800`, no timestamp or `sevV` changed, `d7.raw` and `h5.util` unchanged on every line, and
the `sev`/`sevRaw` census **identical** before and after. A second pass reported
`changedAnything == false` and produced byte-identical output.

That census is what caught the one behaviour change this work did make. The weekly window's `sevRaw`
was being taken from the original's `sev` rather than from `sevRaw ?? sev`, so on a file migrated once
already the marker was overwritten with an intermediate verdict — and where the two now agreed it
vanished entirely, on 102 lines. The five-hour and per-model windows never had the bug: they go
through `recoloured`, whose docblock states the rule. Fixed to match, and pinned by
`aSecondMigrationKeepsTheOriginalWeeklyVerdict`.

## Related

- [ADR-0124](0124-journal-records-carry-their-provider.md) — the `provider` tag this record depends on
  and deliberately does not duplicate.
- [ADR-0127](0127-codex-quota-from-the-app-server.md) — where the Codex windows come from, and why
  their durations are data rather than enum cases.
- [ADR-0107](0107-weekly-reset-reconstructed-from-the-last-known-one.md) — the reconstruction state the move carries across.
- [ADR-0067](0067-local-usage-journal.md) — the record shape's founding decisions.
