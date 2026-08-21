---
name: journal-insights
description: >
  Open a working session over your own TokenPace usage journal: compute the series profile,
  then answer the user's questions about that data — sessions, states, windows, weeks.
  Keeps the processing traps and the usefulness bar in view; builds an artifact only on request.
  Keywords: journal, insights, analytics, signals, widgets, usage-journal, jsonl,
  analyse journal, journal analysis, insights widget, states, sessions, windows,
  журнал, аналітика, сигнали, віджети, статуси, сесії, вікна.
---

# Working with the usage journal

This skill makes you an **analyst ready for questions**, not a report generator. The user opens
a session to ask something about their data; your job is to know what is in it and to answer
the question that was actually asked.

**The main rule: after the start, stop and wait for the question.** Do not build an artifact,
do not compute five topics "just in case," do not write an overview report on your own
initiative. The series profile is the only thing computed without being asked.

## Step 1. Compute the profile — that is the entire automatic scope

```sh
ls -la ~/Library/Application\ Support/com.artem-n.tokenpace/usage-journal-*.jsonl
```

> ### 🚫 The journal never enters the context
>
> `ls` shows the **size**, not the contents. From there on only the **script** sees the journal;
> you see its aggregates.
>
> - **No `Read`, `cat`, `head`, `tail`, or `grep` over the `.jsonl`** — not even "just a peek,"
>   "to see the format," "to check whether it is empty."
> - **The script prints summaries only.** Not journal lines, not "the first few to check,"
>   not raw JSON. If a run dumps more than a few dozen lines, that is a bug in the script,
>   not a result.
> - **Look up field formats in [§ "What a line contains"](../../../docs/reference/journal-analysis.md#what-a-line-contains)**,
>   not in the file itself. The table there is complete.
>
> **Why this is not pedantry.** The August journal is **6.26 MB, 9,039 lines** (~1.6M tokens,
> more than any context window). One line is ~700 bytes, so even `head -50` costs ~35k tokens —
> and gives you nothing that `python3` would not give in the same time. JSONL lines are
> unreadable by eye, and every answer is computed by code anyway.
>
> **One exception:** diagnosing a corrupted file when the script fails on a specific line.
> Then look at **that one line** (`sed -n '<N>p'`), not its neighborhood.

In a single run, get everything that **any** subsequent answer depends on:

| Component | How to get it | What for |
|---|---|---|
| Series length | first and last `t` | which metrics have matured at all |
| Polling step | median difference between adjacent `t` | resolution limit = `2 · poll` |
| Plan | `plan` / `tier` (ask for the price) | how much work fits in a window |
| Homogeneity | distribution of `v` and `sevV` | whether `sev` can be taken as given |
| Windows and weeks | number of 5h windows after dedup, completed `d7` cycles | what is available to answer questions |
| Schedule | working hours per day, windows per day | the density of the profile |
| Task weight | median `util` increase per session | whether one task can exhaust a window |

State the result in **one compact paragraph**: how many days, what step, how many windows and
weeks, and below which limit no conclusions can be drawn. No charts, no artifact.

### The traps without which even the profile comes out wrong

These four are in play already at this step — the rest of the reference waits for its question:

- **`resets_at` doubles by a second.** Grouping by the raw value is not allowed: it produced
  **4,207 "windows" instead of 73**. Round the key to the minute.
- **The parser must be tolerant.** An empty `reset` appears in **27–56% of lines** — those are
  idle windows, not corrupted data. A naive `fromisoformat` fails mid-run, often after printing
  part of the results.
- **Durations are quantized** by the polling step: there are no values between the `k · poll` clusters.
- **`sevV` homogeneity.** If the whole slice is the current generation, `sev` is taken as given;
  recompute only when older lines are present.

## Step 2. Suggest directions — then stop

Name **3–4 concrete questions** this particular series can answer, and mention the overview
report separately as one of the options. Phrase them as the user's questions, not as metric names:

> Your series is 16.8 days, step 3.2 min, 74 five-hour windows, 3 completed weeks.
> I can answer: what your 5h sessions look like overlaid · how much time the bars spent
> in each state (the 5h × 7d matrix) · whether the week presses earlier than the window ·
> when the day is densest. What are you interested in? Or I can put together an overview
> report on everything.

**The overview report is built only when the user chooses it** — either directly or by saying
they do not know where to start. It is not a default on its own.

## Step 3. Answer the question that was asked

The question determines both the metric and the form. Examples of real phrasings:

| The user's question | What to build |
|---|---|
| "show me an analysis of my 5h sessions" | all windows overlaid in "fraction of window × `util`" coordinates, one curve per window |
| "show me an analysis of my interval states" | a 5h × 7d matrix with edge bands and a time-sample switch — the form requirements are in [§ "State shares"](../../../docs/reference/journal-analysis.md#state-shares-a-5h--7d-matrix-with-marginal-bands) |
| "when do I work the most" | a profile by hour of day / day of week |
| "how much is left for the week" | the remainder in whole windows: `remaining_% · N / 100` |
| "can the alarm be predicted" | what precedes orange by 20–30 min |

**Load the section for the topic from
[journal-analysis.md](../../../docs/reference/journal-analysis.md)**, not the whole file:

| Question topic | Reference section |
|---|---|
| sessions, pauses, durations | "Stitching sessions", "Statistical properties" |
| colors, states, time shares | "When to count states: three time samples" |
| windows, peaks, burned quota | "Observation completeness", "The peak versus the last value" |
| money, cost of a window | "Converting to money", "Coefficient N" |
| rules, thresholds, alarm | "Optimizing app behavior", "First: the complete color rules" |
| choosing a chart form | "Which charts to build, and when" |

### Technical conditions that apply to every answer

- **Time sample.** For "how much time the bar spent in state X" — only "working with Claude"
  (±15 min around a rise in `util`). `sessionIdle` inflates activity **threefold**.
- **Weighting.** Each sample is weighted by the time to the next one, capped at 4 polling steps.
- **Blocked states are separate.** The "working with Claude" sample undercounts them by
  construction. Being blocked is an event with a duration, not a state with a share.
- **Significance.** Test the effect against a null model. On real data, two out of three
  hypotheses that looked convincing failed the threshold.
- **Name the slice explicitly.** Series length overturns conclusions: six have already flipped
  between the 1 / 3.5 / 11-day slices.

## Step 4. Ask about the format before building a page

**By default the answer goes to the terminal** — a table, a few numbers, a short conclusion.
That is cheap and sufficient for most questions.

An artifact costs noticeably more tokens, so **when a question is page-sized, ask rather than
decide on your own**: "a table here, or a page with switches?" One exception: the user said
"page," "artifact," or "show me visually" — then build without asking.

An artifact genuinely fits where the form does not work without one: sample switches, overlaid
trajectories, a large matrix, several related charts on one axis.

If you do build one, these elements are mandatory:

- **A sticky parameter panel**, if the controls change every chart.
- **A "what to do with this" section** — what holds, what is not worth doing, and what is
  proposed if there is no signal.
- **The slice the conclusion came from**, named explicitly.
- Before publishing — the reference's checklist (17 items).

## The usefulness bar — it applies to every answer

Before computing anything that lays claim to a place in Insights or Notifications:

> Is there an action the user would take differently having seen this — and would have taken
> wrongly without seeing it?

**If it does not pass, say so right away**, before building, and suggest where the signal might
come from instead: another dimension, another sample, another metric.

**Silence is a valid result.** Four candidates have already fallen away: the distribution of
sessions by starting hour, coding windows by peak rate, the correlation between idle time and
final `util`, and the burned tail in money terms.

Questions like "show me my sessions" do **not** need to clear this bar — the user wants to look
at their own data, and that is legitimate in itself. The bar applies to proposals to put
something into the product.

## What not to do

- **Do not pull the journal into the context.** No `Read`, no `cat`/`head`/`grep` over the
  `.jsonl`; the script prints aggregates, not lines. 6.26 MB ≈ 1.6M tokens — more than the
  context window, and none of it is information `python3` would not give you. Details are in
  the block in step 1.
- **Do not build an artifact without consent.** The most expensive way to guess wrong is to
  assemble a page for a question that needed three numbers.
- **Do not compute neighboring topics "while you are at it."** One question, one answer;
  offer the rest in words.
- **Do not propose tuning the color thresholds.** Moving a boundary changes the verdict without
  changing the spending. Stretching the threshold by 56% removes less than half a point of orange.
- **Do not present unspent quota as a debt.** Five-hour windows open several times a day and are
  covered by the same weekly payment — summing their remainders counts one payment several times
  over. A calm week is just a calm week.
- **Do not mix series with different profiles.** Averaging hides exactly the difference the
  signal exists for.
- **Do not show raw data instead of a conclusion.** A cloud of 3,000 dots is not an analysis.
