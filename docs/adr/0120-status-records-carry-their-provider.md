---
status: accepted
date: 2026-08-22
supersedes: []
superseded_by: []
---

# ADR-0120: `status` journal records carry their provider, and the archive is backfilled

> Lineage: [ADR-0067](0067-local-usage-journal.md) established the append-only journal, its tagged
> heterogeneous JSONL, and the tolerant-decoding policy this builds on ("new fields are added as new
> keys, never by changing existing ones"). 0067 is **accepted and unchanged** — nothing here revises
> it. This ADR extends one of its four record shapes and adds a second migration generation, both of
> which 0067 anticipated as ordinary growth.
>
> Consumes the per-provider aggregate that [#454 §2b](https://github.com/artem-from-ua/tokenpace/issues/454)
> describes; whichever ticket landed first owned introducing it, and this one did.

## Context

A `status` journal line records the raw components of **one** status page plus a single derived
`worst`:

```json
{"kind":"status","t":"2026-08-21T09:12:00Z","svc":[{"n":"Claude Code","s":"operational"}],"worst":"operational"}
```

Nothing in it says *whose* page it came from. With one provider that costs nothing — the answer is
always Claude. It becomes ambiguous **retroactively** the moment a second provider (#454) writes the
same `kind`: two unrelated pages land in one undifferentiated series, and `worst` silently becomes a
worst-of-both that no consumer asked for.

Two facts frame the decision, and they pull in opposite directions.

**Adding the field needs no migration.** The journal's decoding is tolerant by policy: an older build
ignores an unknown key, and a newer build can read an absent key as Claude. Nothing breaks in either
direction, so a tolerant reader alone would satisfy every compatibility requirement.

**A tolerant reader is exactly what the migration precedent argues against.**
[`JournalMigration`](../../Sources/TokenPaceKit/JournalMigration.swift) opens with the reasoning for
rewriting rather than branching: *"A reader could branch on `v`, but then every consumer downstream
carries that branch forever, and the first one to forget it silently mixes two different quantities
into one series."* "Missing means Claude" **is** that branch. So the field is cheap and the backfill is
the real decision.

Measured on the maintainer's journals: **3 214 status lines** in the August release journal and **49**
in the dev journal, none of them tagged.

## Decision

### 1. A `provider` key on `status` records, backfilled onto the archive

`StatusSample` gains `provider`, a journal-stable **snake_case string** (`claude`), set from a new
`ProviderID` enum. Strings, not enum ordinals: a reordered case list would silently re-attribute
every archived record, which is the one failure mode a written-down series cannot recover from.

`JournalMigration` rewrites every archived `status` line to carry it, so no consumer needs an
"absent means Claude" branch. The tolerant decoder keeps its Claude fallback, but the archive no
longer relies on it — it survives only for lines a rewrite cannot reach (a `.v1.bak`, a line pasted
into a bug report, a journal from a machine that has not launched the new build).

The backfill is knowable in retrospect *because of* the very ambiguity that made the tag necessary:
a line written before the second provider existed can only have come from Claude.

### 2. `svc` keeps the **whole feed**; `worst` covers the **monitored set**

`svc` is `summary.components` verbatim — the entire page response, six components for Claude today,
including ones no config monitors. It is **not** narrowed to the monitored set.

The reason is that the monitored set is a **setting**, and the setting is not in the line. Narrowing
`svc` to it would make the field's meaning depend on state the reader cannot see and the user can
change at any time: two lines that look alike would not be comparable, and a toggle flipped in
Settings would show up in the data as if the page itself had changed.

`worst` answers the other question — it is the aggregate over what was actually being watched. So the
pair carries both facts without either standing in for the other, and they **disagree on purpose**: a
line may carry a `major_outage` component in `svc` while reading `worst: "operational"`, which is
correct rather than a bug. A count over `svc[].s` measures the page; a count over `worst` measures the
user's exposure.

### 3. `worst` is derived from that provider's own checks, explicitly

`StatusHealth.worstProblem` flattens **all** checks. Today every check is Claude's, so it is correct
now — and that is precisely why it is dangerous: a second provider merged into `checks` would turn it
into a worst-of-both **without a single call site changing**.

So `StatusHealth` gains `worstProblem(for:)`, scoped by `ServiceID.provider`, and the journal factory
uses it. `worstProblem` stays worst-of-all — the menu-bar dot wants exactly that. `ServiceID.provider`
is an exhaustive `switch` with no `default`, so a service added for a second provider must state its
allegiance rather than inheriting Claude's by omission: the compiler asks the question that "absent
means Claude" would otherwise answer wrongly and silently.

This is what makes the guarantee structural instead of merely currently-true.

### 4. Per-line versioning for `status`, on a counter of its own

`status` lines had no `v` at all; versioning lived only on `UsageSample`. They now carry one, with
**1** = the original untagged shape (implicit — absent reads as 1, mirroring `UsageSample`) and **2**
= this change.

**Per line, not per file**, for the reason `UsageSample.v` already documents: the journal is
append-only and spans app upgrades, so one file legitimately holds several generations and a header
could only ever describe its first line.

**Its own counter, not a shared one.** A `status` line and a `usage` line share a file but not a
shape, and one counter would force either to bump whenever the other changed. The cost is that a
reader must dispatch on `kind` before reading `v` — `v: 2` and `v: 4` in the same file mean unrelated
things — which the docs now state explicitly at both sites.

### 5. Non-usage lines no longer all pass through verbatim

The migration's stated invariant was that `status`, `error` and `resume` pass through byte-identical.
That is now false for `status`, and two mechanisms had to change deliberately or the rewrite would
never have landed:

- **`Outcome.statusTagged`**, a counter of its own rather than a share of `migrated`. `migrated` is
  read as "usage samples reshaped" by every caller, including `migratedFromVersion`, which names the
  backup after a *usage* generation. Folding status lines into it would make a file whose only change
  was a relabelling claim its usage history had been rewritten.
- **`changedAnything` becomes `migrated > 0 || statusTagged > 0`.** This is load-bearing, not
  defensive: the live check reports `rewritten: 0, status tagged: 3 214` on the real August journal —
  every usage line is already current, so status tagging is the *only* work. Keyed on `migrated`
  alone, the pass would have computed a correct rewrite and the shell would have silently declined to
  write it, reporting success while changing nothing.

The rewrite is a **relabelling, not a recomputation**: `t`, `svc` and `worst` are carried across
verbatim. Unlike `util` (replayable through the algorithm that should have produced it) or `sev`
(re-judgeable under the current model, ADR-0115), nothing about a historical status poll can be
recomputed — its inputs were the page's response at that instant, which is gone.

### 6. Everything else about the migration machinery is unchanged

Same entry point (`JournalMigration.migrate(contents:state:)`), same `Outcome` reporting, same shell:
per-generation backups (`.v<n>.bak`), staged `.migrating` write, two atomic renames, and **no backup
is ever deleted** — [#401](https://github.com/artem-from-ua/tokenpace/issues/401) is the cautionary
tale, where a fixed `.v1.bak` name meant a later pass refused to overwrite the older backup and
deleted the live file instead. Idempotent: a second pass is a no-op.

A status-only pass reports `migratedFromVersion == nil` and the shell falls back to the current usage
version when naming the backup — which is honest, because the usage lines in that file really are
current.

## Consequences

**Positive**

- No consumer ever needs an "absent means Claude" branch: after one pass, no stored line relies on it.
- A second provider (#454) cannot silently produce a worst-of-both — the scoping is structural, and
  the exhaustive `switch` makes a new service declare its provider at compile time.
- The `svc`/`worst` split records both "what the page said" and "what the user was exposed to", and
  neither can be mistaken for the other.
- `status` can now evolve its format without perturbing `usage`, and vice versa.

**Negative / accepted costs**

- `v` is overloaded across kinds. A reader that forgets to dispatch on `kind` first will compare two
  unrelated numbers. Mitigated by documenting it at both sites; not eliminated.
- The pass-through invariant is weaker, and one more counter has to be remembered in
  `changedAnything`. The docblock now says so explicitly: **any future counter marking a rewritten
  line must be added there too**, or it will fail the same silent way.
- Every archived status line is rewritten once, so its bytes change even though its meaning does not.
  The backup preserves the original, as with every previous generation.
- `svc` keeps carrying components nobody monitors — a modest size cost (status lines are ~400 bytes)
  accepted in exchange for the line staying self-describing.

## Verification

Run over the maintainer's real journals via `LiveJournalMigrationCheck`
(`TOKENPACE_LIVE_JOURNALS`, opt-in and read-only):

| Journal | Lines | Status samples | Rewritten (usage) | Status tagged | Second pass |
|---|---|---|---|---|---|
| `usage-journal-2026-08.jsonl` | 9 274 | 3 214 | 0 | 3 214 | no-op |
| `usage-journal-dev-2026-08.jsonl` | 122 | 49 | 0 | 49 | no-op |

Line count unchanged on both, no unparseable lines, and after the pass no status line carries a `v`
below the current one. The `rewritten: 0` column is the finding that justifies §5: on real data,
status tagging was the entire change.
