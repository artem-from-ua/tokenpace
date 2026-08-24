---
status: accepted
date: 2026-08-24
---

# ADR-0124: Every journal record carries its provider, and error runs never merge across providers

> Lineage: [ADR-0120](0120-status-records-carry-their-provider.md) tagged the `status` line and
> backfilled the archive. It is **accepted and unchanged** — nothing here revises it. This record
> applies the same decision to the remaining three shapes, for the reason 0120 could not yet act on:
> a second **usage** provider, not a second status page.

## Context

[ADR-0120](0120-status-records-carry-their-provider.md) settled the argument for one record kind. A
`status` line said nothing about whose page it came from; with one provider the answer was always
Claude, and it became ambiguous **retroactively** the moment a second page wrote the same `kind`.
The fix was a `provider` key plus a backfill, so no downstream consumer ever needs an "absent means
Claude" branch — the branch that
[`JournalMigration`](../../Sources/TokenPaceKit/JournalMigration.swift) opens by arguing against.

`usage`, `error` and `resume` still carry that ambiguity. Nothing in them says whose quota was read,
whose poll failed, or whose observation stopped. A second usage provider
([#501](https://github.com/artem-from-ua/tokenpace/issues/501)) makes all three ambiguous the same
way, and the journal is append-only: a line written untagged today stays untagged in every archive
forever. **The tag has to land before any second provider writes a usage line**, which is why this is
its own ticket ([#502](https://github.com/artem-from-ua/tokenpace/issues/502)) rather than a step
inside one.

Two things make this more than 0120 repeated three times.

**The error-run collapse merges on identity.**
[ADR-0123](0123-one-line-per-error-run-and-a-floor-on-signal-driven-polls.md) writes one line per run
of consecutive identical failures, where "identical" means matching `code`, `reason`, `detail` and
`retryAfter`. Two providers can fail with exactly those four values equal — `code: "timeout"`,
`reason: "timeout"`, both details and hints absent. Interleaved on one cadence, their failures fold
into a single line carrying one provider's name: the two-series merge this whole record exists to
prevent, reproduced one layer below the tag that was supposed to prevent it.

**The gap clock is shared.** `UsageJournal` keeps one `lastPollInstant`, and `JournalGap.marker`
reads it to decide whether a hole is worth recording. One clock means a Claude poll advances the
detector for a provider that is not polling at all — so an outage on the other provider leaves **no**
hole in the record and reads as continuous observation. Of everything here, that is the only failure
a written-down series cannot recover from afterwards: a missing marker is indistinguishable from a
period that was genuinely observed.

## Decision

### D1. One `provider` key, the same shape on all four record kinds

`UsageSample`, `ErrorSample` and `ResumeMarker` each gain `provider` — a journal-stable snake_case
string from `ProviderID`, the same name and type `StatusSample` already carries.

Stored as `String`, not the enum: a line written by a build that knows a provider this one does not
still decodes honestly instead of failing the whole record. The tolerant decoder keeps a Claude
fallback with the same standing 0120 gave it — for the lines a rewrite cannot reach (a `.v4.bak`, a
line pasted into a bug report, a journal from a machine that has not launched the new build), never
as the policy the archive relies on.

### D2. Three independent version counters, and `ResumeMarker` gets its first

| Kind | Was | Is |
|---|---|---|
| `UsageSample` | `v: 4` | `v: 5` |
| `ErrorSample` | `v: 2` | `v: 3` |
| `ResumeMarker` | *(no counter)* | `v: 1` |

Each kind versions itself, for the reason 0120 §4 gives: a `usage` line and an `error` line share a
file but not a shape, and one counter would force either to bump whenever the other changed. A reader
dispatches on `kind` before reading `v` — four numbers spelled `v` now mean four unrelated things.

**An absent `v` on a `ResumeMarker` reads as 0, not 1.** Everywhere else in the journal an absent `v`
means 1, because v1 was a real generation of that shape. `ResumeMarker` never had the field, so
claiming "1" would assert a generation that never existed. The same argument was already made for
`UsageSample.sevV`. The payoff is uniformity where it matters: the migration predicate is
`v < currentVersion` for all four kinds, with no per-kind special case to forget.

### D3. `sevV` deliberately does not move

The colour model is unchanged, so `UsageSample.currentColorVersion` stays where it is. A colour bump
would make the pass recompute every window's verdict and stamp `sevRaw` where it moved — work this
change has no reason to do, and evidence it would fabricate. This is exactly the split
`v`/`sevV` exists for: a format bump that says nothing about colour.

### D4. `provider` joins the error-run identity tuple, first

`ErrorRun` carries `provider`, and `ErrorRunCollapse.admit` compares it **before** `code` — the
coarsest discriminator first, so the cheap test that separates two whole series runs ahead of the
four that separate failures within one.

The physical failure this prevents, stated so it can be checked without reading anything else: two
providers failing with `code: "timeout"`, `reason: "timeout"`, `detail: nil`, `retryAfter: nil` are
**equal on every field the old predicate read**. Interleaved within the run's 3-minute width they
collapse to one line with `n: 2` under one provider's name, and nothing in the file records that two
series were merged. `runsDoNotMergeAcrossProviders` pins it, with `theSameProviderStillExtendsTheRun`
beside it so the first cannot pass by way of a collapse that stopped working altogether.

### D5. The writer's clocks and open runs become per-provider

`UsageJournal.lastPollInstant` and `openErrorRun` become `[ProviderID: …]`, and `append` takes the
provider whose poll it is.

For the runs this follows from D4 — one shared slot would merge what the predicate now separates. For
the clock it is the more serious half: a shared `lastPollInstant` lets one provider's polling suppress
another's resume marker, so an outage leaves the record with no hole in it and every downstream
reader treats the missing stretch as observed. `JournalGap.marker` therefore takes the provider too,
and stamps the marker it builds.

Termination calls **`flushAllErrorRuns()`**, not a per-provider flush: the per-provider call would
write one run and silently drop the rest, which is the easiest mistake to make here and the one that
looks like nothing happened. `appendStatus` is unchanged — it deliberately touches no clock, because
a status poll is not a break in the usage series.

### D6. `Outcome` gains two counters, and `changedAnything` gains both

`errorTagged` and `resumeTagged` join `statusTagged`. Usage lines need no third counter: a v4 line
gaining `provider` is a format bump to v5, which `migrated` already counts and `migratedFromVersion`
already names the backup after. A separate counter would describe the same rewrite twice.

**Both go into `changedAnything`.** Its docblock warns about this in bold — *any future counter that
marks a rewritten line must be added here too* — and the warning is not hypothetical: a journal whose
only stale lines are `resume` markers is ordinary (a laptop that sleeps a lot, with usage polling
off). Missing from the check, the pass computes a correct rewrite, the shell silently declines to
write it, and the log reports success. `aResumeOnlyChangeIsDetectedAsChanged` pins that case.

### D7. The byte-passthrough for a run of one is overridden exactly once

The collapse path deliberately reuses a stale line's **original bytes** when its run holds one
attempt, so a file with nothing to fold is not rewritten and a launch does not touch every journal.
That optimisation now works against the tag: an untagged run of one would keep its untagged bytes
forever, because nothing else ever revisits it.

So a line behind `ErrorSample.currentVersion` drops the saved bytes and is re-encoded through
`ErrorRunCollapse.close`, counting as `errorTagged` rather than `errorsCollapsed` — there were never
two attempts to fold, and calling it a collapse would claim attempts that did not exist. An
already-collapsed line (`n != nil`) takes the same override, keeping its `n`/`tEnd`: those are
finished work whose inputs are gone.

### D8. `UsageGrid` gets a provider **filter** now; the provider **dimension** is deferred

`UsageGridAggregator.grid(...)` takes `provider: ProviderID? = .claude`.

**The default is `.claude`, not `nil`.** A mixed file counted without a filter double-counts every
hour both providers polled, and the result looks entirely plausible — nothing in a density cell says
it summed two series. `nil` asks for all of them, and it has to be asked for. A `resume` marker is
filtered the same way: another provider's hole is not this one's, which kept polling through it.

The full dimension — a grid that shows one provider, all of them, or a comparison — is deferred, and
the gate is checkable by anyone: **when a surface exists that draws a grid for more than one
provider.** Today `InsightsWindowController` is an empty shell, so designing that UI question now
means answering it with no screen to check the answer against.

## Consequences

**Positive**

- No consumer of any record kind needs an "absent means Claude" branch after one pass.
- Two providers cannot silently merge into one error line — the discriminator is in the identity
  tuple, not in a rule somebody has to remember.
- An outage on one provider leaves a real hole in the record, because its gap clock is its own.
- Every kind can now evolve its format without perturbing the other three.

**Negative / accepted costs**

- **The largest rewrite in the project's history runs on the first launch after upgrade.** Because
  `UsageSample.currentVersion` moved, the pass rewrites **every usage line of every archive** — not a
  subset, all of them — and leaves a `.v4.bak` beside each file. On a large journal that is measurable
  time at startup, and measurable disk for the backups, which are never deleted.
- `v` is now overloaded four ways. A reader that forgets to dispatch on `kind` compares unrelated
  numbers. Documented at every site; not eliminated.
- The pass-through invariant is weaker again: no kind is exempt, and two more counters have to be
  remembered in `changedAnything`.
- A stale `error` run of one is re-encoded, so a file that would previously have been left untouched
  is rewritten once. It is a one-off — the second pass sees a current line and passes it through.
- Per-provider clocks mean a provider that has never polled has no clock, so its first poll after a
  relaunch emits no marker. That is the same honest behaviour a cold start already has.

## Verification

`swift test`, then `LiveJournalMigrationCheck` (`TOKENPACE_LIVE_JOURNALS=1`, opt-in and read-only)
over a **copy** of the real archive. The check now asserts, beyond what it asserted for 0120: no
`usage`/`error`/`resume` line is left below its own `currentVersion`, none carries a provider other
than Claude, and a second pass reports `errorTagged == 0` and `resumeTagged == 0` with
`changedAnything == false`.

The counters `error tagged` and `resume tagged` are printed per file, so the maintainer's run reports
how much of each kind the archive held.
