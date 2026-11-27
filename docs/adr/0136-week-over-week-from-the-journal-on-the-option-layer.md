---
status: accepted
date: 2026-11-27
---

# ADR-0136: Week-over-week comparison comes from the journal and sits under the 7-day bar on the ⌥ layer

## Context

The 7-day bar answers "how am I doing this week". It cannot answer the question a user asks every
few weeks: **is my plan the right size?** One week is noise. A heavy launch week or a quiet holiday
says little about the plan. The answer needs past weeks next to this one.

The data is already on disk. The usage journal ([ADR-0067](0067-local-usage-journal.md)) records
every successful poll, including the 7-day utilisation, its time fraction and its reset. That is
the server's figure for the **whole account**, covering every surface that spends quota. Local
Claude Code transcripts would cover this Mac only.

The question is occasional, so the answer should not cost permanent popup height.

## Decision

### D1. Source: the usage journal's 7-day readings

Week-over-week is computed from Claude's `d7` readings in the journal (`WeeklyComparison`, pure in
`TokenPaceKit`). It is not computed from token counts in local transcripts, and it does not use a
new API request.

- Readings group into windows by reset, rounded to the hour, because the same reset arrives in
  spellings a second apart.
- A window's final value is its **peak**, not its last reading, because the counter can roll back
  inside a window.
- A window is **complete** only if a reading landed at ≥ 98.5% of its time. The app may not have
  run at the end of a week, and the peak of a week seen only half-way is not its final value.

### D2. Content: two lines, each half dropping out on its own

```
last week by now 16% · ended at 52%
past 4 weeks ended 52–85% · avg 75%
```

- **last week by now**: last week's use at the point of its window this one has reached. It is
  shown only if a reading sits within 0.02 of the window (≈3 h) of that point. A further-off
  reading would compare different moments.
- **ended at**: last week's peak, shown only if that week is complete.
- **past N weeks**: the range and average of the final peaks of up to four recent complete weeks.
  It is shown only with at least two, because one week is already the line above.

Missing data removes a half or a line. It is never estimated.

### D3. Placement: under the 7-day bar, on the ⌥ layer

The lines are drawn **below** the 7-day bar while ⌥ is held, and on no other row. They go below
the bar, not between the details line and the bar, so the row still reads header, figures, bar,
like every other row. Putting them above the bar separated the figures from the bar they describe.

### D4. Cadence: reloaded at most hourly

The shell reads the last three monthly journal files off the main actor, at most once an hour.
History grows only by the current week, and the live snapshot already covers that week.

## Consequences

- Users who run TokenPace only some of the time see fewer lines, or none, until the journal holds
  complete weeks. That is the cost of not estimating.
- A fresh install shows nothing here for at least a week, and the "past N weeks" line needs two
  complete ones.
- A dev build reads its own `-dev` journal, which rarely holds full weeks. Checking this feature
  needs `TOKENPACE_HISTORY_FROM_RELEASE=1`, which reads the release journal read-only.
- One more read of up to three journal files per hour. The files are small enough that this does
  not show up next to the poll.

## Alternatives considered

- **The Insights window.** It is the natural home for history, but it is a separate window the user
  has to open. The question comes up while looking at the weekly bar, so the answer belongs next to
  that bar.
- **A permanent line.** This rejects the ⌥ layer's purpose: it would cost height every time the
  popup opens, for a question asked now and then.
- **Token counts from local transcripts.** These are this Mac only, and they are not the unit the
  limit is enforced in.

## Related

- [ADR-0067](0067-local-usage-journal.md): the journal this reads.
- [ADR-0117](0117-dropdown-actions-behind-option.md): the ⌥ layer.
- Verification: [ui-verification.md](../guides/ui-verification.md#week-over-week-lines-under--the-7-day-bar).
