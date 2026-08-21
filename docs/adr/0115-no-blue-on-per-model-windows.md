---
status: accepted
date: 2026-08-20
supersedes: []
superseded_by: []
---

# ADR-0115: Blue never applies to per-model windows; `sev` is recomputed by migration

> Supersedes **§3 and §5** of [ADR-0081](0081-weekly-capacity-gate-for-blue.md). §3 assigned
> per-model rows `blueAllowed = weeklyHasHeadroom`; they now get an unconditional `false`. §5
> claimed the journal-vs-screen divergence was "closed" — it wasn't, and that's exactly what's
> fixed here. The rest of 0081 still stands: the weekly-capacity gate itself for the 5-hour bar,
> closed-by-default on an unparsable weekly reset, degradation to green (not yellow), the merge of
> `ColorRole.paceBlue`.
>
> Restores **§4** of [ADR-0061](0061-far-behind-blue-pacing-zone.md) ("Scope — base 5h/7d only") as
> the operative decision and moves its mechanism from the render layer into the model. In doing so,
> it supersedes the clause in 0061 about `PopupBarView.isBaseLimit` — the flag is removed, the rule
> stays.

## Context

[ADR-0061 §4](0061-far-behind-blue-pacing-zone.md) originally scoped the blue zone to base windows
only: "Blue is shown **only** for the base 5-hour and 7-day bars. **Not** for model-specific
(per-model / per-service) rows and **not** for extra-usage (credits)." The mechanism was the
`PopupBarView.isBaseLimit` flag, which the popup set by row index (`index <= 1`).

[ADR-0081 §3](0081-weekly-capacity-gate-for-blue.md) later distributed `blueAllowed` across the
bars and gave per-model rows `weeklyHasHeadroom` — with the argument "7d-paced, the same weekly
budget." Nothing changed on screen: `isBaseLimit` kept muting them in the popup. But the **model**
now said something different from the render layer, and `PacingBucket` — which reads the model
directly — started writing blue to the journal for scoped windows.

ADR-0081 §5 recorded the opposite at the time: "In particular, this closes the old divergence where
a scoped row could get `sev: "blue"` even though the popup gates it via `isBaseLimit`." That claim
was false. Teaching `PacingBucket` to read `blueAllowed` was necessary but not sufficient: the gate
only closes when the **week** is ahead of pace, and the rest of the time it's open, and blue kept
passing through. The same falsehood propagated into the reference docs
([bar-status-conditions.md](../reference/bar-status-conditions.md) §4: "so `sev` for them is never
`blue`") and even got baked into a test, whose doc block explained that "the journal has no such
gate — this is what keeps the recorded bucket equal to the pixel the user saw."

**Measured on the maintainer's August journal** (5,792 `usage` rows): **2,214 records with
`scoped.sev == "blue"`** — 38% of all scoped samples, and not one of them was ever on screen.

### Why blue really doesn't belong on per-model rows

Blue means one specific piece of advice: **the seven-day window has headroom you aren't using**. A
scoped limit is a slice of that same week, so the advice would be addressed to itself. The
[users-and-goals.md](../reference/users-and-goals.md) check ("does an action exist that the user
would take differently") fails it: everything worth saying about the week's headroom has already
been said by the 5h and 7d rows, and Fable's own low utilization adds no new decision.

The precedent was there the whole time. `CreditsPacing.barLayout` already did exactly this:

> Credits are out of the blue-zone scope: the money window is not a token limit… `blueAllowed: false`
> **states that in the model rather than relying on the render layer never setting `isBaseLimit`**.

Per-model is the second instance of the same class.

## Decision

### 1. `blueAllowed` now means three independent reasons

The canonical definition on `BarLayout.blueAllowed` is rewritten: the field no longer answers "does
the week have headroom," but "is the blue advice here true, addressed to this bar, and meaningful."
`false` results from any of three:

1. **the week has nothing to offer** — the 5-hour bar with a closed weekly gate (ADR-0081 §3 still
   stands for this part);
2. **the bar is itself the week** — per-model rows (Opus / Sonnet / `weekly_scoped`);
3. **the bar gives no pacing advice at all** — credits, inert idle placeholders.

This is the actual fix. Without it, the next change to the weekly logic would bring blue back to
scoped rows: as long as the definition said "`false` = a lie **about the week**," reason 2 would
keep looking like a special case of reason 1.

### 2. The gate lives in the model; `isBaseLimit` is removed

`PopupLayout` and `JournalRecord.usage(from:)` build per-model rows with `blueAllowed: false`.
`PopupBarView.isBaseLimit` is removed entirely — along with its two color branches, the gate on the
"far behind pace" wording in `statusText`, its threading through `addBar`, and two redundant
assignments in the Settings renderers. `behindColor`, `isFarBehind`, and `BarLayout.severity`
already checked `blueAllowed` on their own, so the external gate was only duplicating them — and
drifting from the model.

In `JournalRecord.scoped()` the `blueAllowed` parameter is removed outright, rather than set to
`false`: a caller able to pass `true` is a caller able to reproduce this exact divergence.

### 3. Journal format v4: `sev` recomputed, `sevRaw` and `sevV` added

The migration (`JournalMigration`, the same mechanism with its indestructible `.v<n>.bak`,
[ADR-0067 §6](0067-local-usage-journal.md)) recomputes `sev` for every window using the current
model:

- **`sev`** — the current model's verdict (what analysis reads);
- **`sevRaw`** — the verdict recorded at poll time, **only where the two differ**. A missing field
  reads as "matches," not "no data." Writing it every time would mean adding six duplicated fields
  per sample to say nothing new; this way, every field that's present is a real change;
- **`sevV`** — the color model's generation, **one per row**: a poll evaluates all windows against
  the same thresholds at the same moment, so six copies could only ever agree.

**Two version axes, not one.** `v` says how to read the row; `sevV` says which model evaluated it.
A threshold change doesn't touch any key, so bumping `v` for it would turn a semantic change into a
format migration — and, worse, leave analysis with no way to ask "is this `sev` current" without
knowing which `v` shipped which thresholds.

**Why there's a marker here but not on `util`.** [ADR-0067 §6](0067-local-usage-journal.md)
deliberately doesn't flag migrated `util`: **the same** algorithm runs there, so a flag would
imply a difference that doesn't exist. `sev` is the opposite — the algorithm is **different**
(thresholds shifted, per-model rows lost the right to blue), so the old and new answers really do
diverge. The flag records a real difference; without it, the one piece of evidence of what the
user actually saw would be gone.

### 4. Recomputation runs after the date repair

The v2 → v3 pass rewrote `d7.reset`/`timePct` but kept the old `sev` — leaving rows whose verdict
was computed against an already-fixed `timePct`. The new pass computes color **after**
`repairWeeklyReset`, from the repaired values.

The weekly-gate arithmetic was pulled out into
`PacingModel.weeklyHasHeadroom(weeklyTimeFraction:weeklyUsageFraction:)` and is called from both
sites: the main overload's doc block promises the gate "can't diverge from the 7-day row the user
is looking at," and the second, handwritten comparison in the migration is exactly how that promise
used to break.

**The idle branch is mandatory.** Rows with an unparsable `reset` have no pacing geometry; their
verdict is `util >= 100 ? red : green`, matching the live factory. This isn't an edge case: on the
live journal, that's the shape of over a quarter of all 5-hour windows.

## Consequences

- **The journal and the pixel agree by construction**, not by coincidence. Both sides read one
  field; there is no second gate. The `journalBucketMatchesRenderedSeverity` invariant is now
  checked on per-model rows too — previously only on `h5`, which is exactly why the defect went
  unnoticed.
- **The series became uniform.** On the August journal, **2,400 verdicts** were recomputed: 2,213
  `scoped: blue → green`, 83 `h5: blue → green`, 54 `d7: yellow → green`, 38 `d7: green → yellow`,
  10 `d7: orange → yellow`, 1 `h5: green → blue`. After the pass, per-model windows carry **zero**
  blue.
- **The journal has noticeably less blue in it, and it's honest now.** The metric "how much time
  did the bar advise speeding up" used to be dominated by scoped rows nobody ever saw.
- **The next threshold change is cheaper.** "Recompute everything where `sevV` is older than
  current" — and `v` doesn't need to move. A pass that only touches color doesn't name an older
  generation (`migratedFromVersion == nil`), so its backup doesn't get a format name the file never
  had.
- **Rounding was checked and ruled out.** `JournalPrecision` rounds `util`/`timePct` **after**
  computing `sev`, so recomputing from the recorded fields could in theory have flipped
  borderline states. The distance of each of the 187 h5/d7 transitions to its threshold was
  measured: none fall within the rounding step. The entire divergence is the model change.
- **`.v3.bak` stays forever** — after the migration, `sev` no longer matches what the user saw, and
  the backup is the only record of the original verdicts for rows where `sevRaw` wasn't written
  (because it matched).
- **The two live series migrate differently.** The maintainer's series migrates itself, on the
  first launch of the new build. Ostap's series lives as a copy outside the app's own folder, so it
  needs a separate run with the same code.
