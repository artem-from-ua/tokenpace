# Analyzing the usage journal

A reference for anyone computing statistics from `usage-journal-*.jsonl` — your own or one supplied
by another user. It describes **what the journal contains, how to process it correctly, and where
processing silently lies to you**.

> Related: [ADR-0067](../adr/0067-local-usage-journal.md) — the decision on format and collection;
> [usage-api-quirks.md](usage-api-quirks.md) — quirks of the API itself (quantized `util`,
> the incomparability of 5h and 7d, the disappearance of `resets_at`);
> [users-and-goals.md](users-and-goals.md) — the check for whether a signal you found is useful at all.

This file does **not** duplicate the first two: those cover where the data comes from, this one
covers what to do with it next.

## Why it exists

The project is in the phase of hunting for signals for Insights
([#241](https://github.com/artem-from-ua/tokenpace/issues/241)) and Notifications. Every such hunt
starts the same way: parse the JSONL, roll it up into windows or sessions, compute an aggregate. The
mistakes repeat too — and they cost not just time but false product conclusions that look convincing.

## The bar for a signal — the same one as in the menu bar

**Insights and Notifications get no discount.** The requirement from
[users-and-goals.md](users-and-goals.md) applies to them word for word:

> Is there an action the user would take differently having seen this — and would have taken
> wrongly without seeing it?

The temptation to lower the bar comes up every time: Insights is a separate window you open
deliberately, so it feels like "anything interesting can go in there." That is wrong for two reasons.

- **Showing something costs attention on any surface.** A chart that changes nothing crowds out the
  one that does — and trains the user not to look at all.
- **A notification costs more than the menu bar, not less.** It arrives on its own, interrupts work,
  and has no "calm state" you can ignore with a glance. Its bar is **higher**.

What follows in practice:

| Principle from the menu bar | How it reads for Insights / Notifications |
|---|---|
| **The value is the model's input, the color and the verdict are its output** | A chart of `util` over time is not a signal. It becomes one when a decision that would otherwise be wrong is visible in it |
| **Silence is a valid state** | An empty Insights screen in a calm week is a result, not an unfinished feature. A notification that never fired is one too |
| **Ranked by how urgently a correction is needed, not by how big the number is** | A big number (77% unused) with no action available is quieter than a small one (0.6 of a window left before the reset) |
| **The user already controls some things** | Before proposing a signal, check whether the answer is not already set where the value itself is set (e.g. the billing cap) |

**The most common failure** on this data is a statistically flawless result with no action attached.
Examples that failed the test in a real hunt: the distribution of sessions by start hour, coloring
windows by peak rate, correlating idle time with final `util`. All three are correct and change
nothing.

## The journal is processed by a script, never read

**The file never enters the agent's context.** The field table below exists precisely so that there
is no need to peek inside the file: the format is complete, and `Read`/`cat`/`head`/`grep` over the
`.jsonl` add nothing but spent tokens.

Orders of magnitude, so it is clear why this is a rule rather than a suggestion: the August series is
**6.26 MB, 9,039 lines**, or ~1.6M tokens (**larger than the context window**). One line is ≈700
bytes, so even `head -50` costs ~35k tokens and gives you nothing `python3` will not compute in the
same amount of time.

- **The script prints aggregates, not lines.** A run that dumps raw JSON "just to check" is a bug in
  the script, not an intermediate result.
- **The only exception** is diagnosing a corrupted line the parser chokes on: look at **that one
  line** (`sed -n '<N>p'`), not its neighborhood.

## What a line contains

One object per line, tagged with `kind`. For analytics the `usage` lines are the interesting ones;
the other three shapes get a subsection each below. Read the `error` one before you count anything —
it carries a trap.

> **Every count must filter by `provider` first.** Since
> [ADR-0124](../adr/0124-journal-records-carry-their-provider.md) every line of every `kind` carries
> `provider`, and archives were backfilled by the launch migration. An archive can hold more than one
> provider's series in one file, and a count taken without the filter sums them — the result looks
> entirely plausible, because nothing in an aggregate says it merged two series. Filter first, then
> count; a comparison across providers is two filtered counts, never one unfiltered one.

> **Never count `error` lines — sum `n ?? 1`.** Since
> [ADR-0123](../adr/0123-one-line-per-error-run-and-a-floor-on-signal-driven-polls.md) consecutive
> identical failures are written as **one** record carrying the count, and existing archives were
> collapsed retroactively by the launch migration. One real journal held 122 592 identical `notSent`
> lines from a single Keychain outage; after the collapse that is 132 records. A line count reads it
> as 132 failures — wrong by three orders of magnitude. A rate computed from the spacing between
> lines is wrong in the other direction: it reads one failure every three minutes where there were
> sixteen a second.

| Field | Type | What it is |
|---|---|---|
| `t` | ISO-8601 UTC | the moment of the poll |
| `h5.util` | Int 0…100 | the 5-hour window, whole percent |
| `h5.reset` | ISO-8601 | when the window resets |
| `h5.timePct` | Double 0…1 | how much of the window has elapsed |
| `h5.sev` | `blue`/`green`/`yellow`/`orange`/`red` | the color bucket, independent of cosmetic settings |
| `h5.sevRaw` | same | the verdict recorded at poll time — **only** if it differs from `sev`. A missing field means "identical", not "no data" |
| `d7.*` | same | the 7-day window |
| `scoped[]` | array | per-model limits (`name`, `pct`, `reset`, `timePct`, `sev`, `sevRaw`) |
| `v` | Int | the version of the line **format** — for a `usage` line, **5** is current; absent reads as 1. Every `kind` has its own counter, so dispatch on `kind` before reading it (a `status` line's `v` is at 2 and means something else entirely) |
| `provider` | String | whose quota this line measures (`claude`). Written on every line since v5 and backfilled onto every archived one, so **never** infer it from absence |
| `sevV` | Int | the generation of the **color model** that produced `sev` (1 is current); absent = older than the first named one |
| `spend` | object | the spend limit, credits consumed, currency |
| `plan` / `tier` | String | `max`/`pro`, the plan — needed to attribute the series |
| `sessionIdle` | Bool | the app considered the session inactive |
| `ms` | Int | API response latency |

### The `status` line

Still not an analytics source — the `usage` lines remain the interesting ones — but the format
section has to be accurate, and since [ADR-0120](../adr/0120-status-records-carry-their-provider.md)
these lines carry two more keys:

| Field | Type | What it is |
|---|---|---|
| `v` | Int | the version of the **`status`** line format (**2** is current); absent reads as 1. A counter of its own — unrelated to the `usage` line's `v` above |
| `t` | ISO-8601 UTC | the moment of the status poll |
| `provider` | String | which status page this line came from (`claude`, `codex`). Written on every line since v2 and backfilled onto every archived one, so **never** infer it from absence — and **always group by it** before counting, since one file now holds several pages' polls |
| `svc[]` | array | the **whole feed** of that page (`n` = component name, `s` = raw status), including components no config monitors. The feeds differ in size by an order of magnitude — Codex's carries every OpenAI component, not only the Codex ones — so a count over `svc` is a statement about one provider, never a comparison across them |
| `worst` | String | worst-of over the **monitored** services of *this provider*, or `operational` |

**`codex` lines are also read back by the app**, which nothing else in the journal is: they are the
fallback source for a Codex component's age when the incident feed cannot supply one
([ADR-0125](../adr/0125-codex-as-a-status-provider.md)). Two consequences for anyone processing them.
A rewrite or a filter that drops `status` lines silently removes ages from the popup. And the
reconstruction reads the newest line's `svc` and walks back while a component's `s` holds — so it
resolves only to the poll cadence, and a status held across the whole retained record deliberately
yields **no** age rather than one dated to the oldest line.

**`svc` and `worst` answer different questions, and they disagree on purpose.** `svc` is the page's
response verbatim; `worst` is the aggregate over what the user was actually watching. So a line can
carry a `major_outage` component in `svc` and still read `worst: "operational"` — that is correct, not
a bug: the outage was on a component nobody asked about. A count over `svc[].s` measures *the page*, a
count over `worst` measures *the user's exposure*. Never substitute one for the other.

Which services were monitored is a **setting**, and it is not in the line. That is why `svc` is not
narrowed to it: a narrowed feed would silently change meaning whenever the user flipped a toggle, and
two lines that look alike would not be comparable.

### The `error` line

One record per **run** of consecutive identical failures, not per attempt
([ADR-0123](../adr/0123-one-line-per-error-run-and-a-floor-on-signal-driven-polls.md)):

| Field | Type | What it is |
|---|---|---|
| `v` | Int | the version of the **`error`** line format (**3** is current); absent reads as 1 — a pre-collapse line, one attempt, no `detail` |
| `provider` | String | whose poll failed (`claude`). Written on every line since v3 and backfilled onto every archived one. Part of the run's identity, so two providers failing identically never merge into one line |
| `t` / `tEnd` | ISO-8601 UTC | the **first** and **last** attempt of the run. `tEnd` is absent when the line is a single attempt; `tEnd − t` is the run's duration, never the spacing between attempts |
| `n` | Int | how many attempts this line stands for; **absent means 1** |
| `code` | Int **or** String | an HTTP status (`429`, `503`) when a response arrived, or a category (`notSent`/`timeout`/`dns`/`network`/`decode`/`nonHTTP`) when none did. A bare JSON number or string — a parser must accept both |
| `reason` | String | the **closed** taxonomy: `clientProblem`/`serverProblem`/`auth`/`decode`/`timeout`/`dns`/`network`/`notSent`. Safe to group by |
| `detail` | String | an **open** refinement of `reason`, present only where there is one to give — the six not-sent causes (`token expired`, `keychain access denied`, `not signed in`, `keychain read failed`, `malformed credentials`, `missing User-Agent`). Group by it only with a fallback bucket |
| `retryAfter` | Number | `Retry-After` seconds, 429 only. Part of the run's identity, so two 429s with different hints never merge |
| `ms` | Int | latency of the run's **first** attempt; absent when the request was never sent |

**`detail` is absent on every archived line, and that is not a gap in the data.** The reason was
dropped before it reached the journal until ADR-0123, so no line written before it can carry one. A
count of `notSent` causes over an old archive is not "mostly unknown" — it is unanswerable, and the
`.v<n>.bak` does not help either.

**Status lines are on a different cadence from usage lines** (ADR-0013) and carry no resume markers of
their own, so never interleave the two series or read a gap in one as a gap in the other.

### The resume line

A marker written when a gap exceeded the expected cadence. What it means and how to use it is under
["An observation gap is a first-class entity"](#an-observation-gap-is-a-first-class-entity); this is
its shape.

| Field | Type | What it is |
|---|---|---|
| `v` | Int | the version of the **`resume`** line format (**1** is current); absent reads as **0**, not 1 — the field never existed on this shape, so there is no generation "1" to claim |
| `t` | ISO-8601 UTC | the first poll **after** the gap. The gap covers `[t − gap … t]` |
| `gap` | Number | the gap length in seconds |
| `provider` | String | whose observation stopped (`claude`). Written on every line since v1 and backfilled onto every archived one |

**A marker belongs to one provider's series, and only that one.** Each provider's writer keeps its
own gap clock, so a hole in one is not a hole in another — the other kept polling straight through it
([ADR-0124](../adr/0124-journal-records-carry-their-provider.md)). Applying every marker in the file
to every series paints holes over stretches that were observed, which is the same untruth as
interpolating across a real one, in the opposite direction.

**Take `sev` as given — but look at `sevV` first.** The ready-made value already accounts for the
weekly-capacity gate ([ADR-0081](../adr/0081-weekly-capacity-gate-for-blue.md)) and the ban on blue
for per-model windows ([ADR-0115](../adr/0115-no-blue-on-per-model-windows.md)), and it does not
depend on the user's cosmetic settings — reproducing all of that in analysis is harder than it looks
(see ["First: the complete color rules"](#first-the-complete-color-rules-not-just-the-thresholds)).

The condition is that the slice be homogeneous: every line with a `sevV` equal to the current
generation. If the journal holds samples with a lower `sevV` (or none at all), they were judged by a
**different** model, and mixing them with the rest is not allowed. What to do about it is item 16 of
the [checklist](#checklist-before-showing-a-result).

## The Codex quota log — a separate file, dev only

`codex-quota-dev-YYYY-MM.jsonl`, beside the journal in the same directory and **not part of it**.
One line per successful Codex quota poll, written only when the running build is a dev one and the
Development-tools checkbox that also drives `status-payloads-dev-*` is on. There is no release
counterpart and no plan to add one: `UsageSample` cannot hold a lone 7-day window without inventing
a 5-hour one, and the archive the maintainer's history is built on takes no invented rows
([#520](https://github.com/artem-from-ua/tokenpace/issues/520),
[#504](https://github.com/artem-from-ua/tokenpace/issues/504)).

The name is what keeps it out. `JournalMigration.belongsToBuild` keys on the `usage-journal-`
prefix, which this name does not carry, so no build's migration ever opens the file — and the writer
refuses a release build besides.

| Field | Type | What it is |
|---|---|---|
| `v` | Int | the version of the **quota** line format (**1** is current). Its own counter, unrelated to every `v` above |
| `observedAt` | ISO-8601 UTC | when we read the response |
| `windows[]` | array | one entry per window the server reported, in its order. **One today**; the count is the server's |
| `windows[].usedPercent` | Double 0…100 | the server's own number, clamped to the range and otherwise untouched |
| `windows[].windowDurationMins` | Int | the window length in minutes — 10080 on the live Plus account |
| `windows[].resetsAt` | Number | **epoch seconds** — the one field whose format differs from every reset in the usage journal, which are ISO strings. **Absent** when the server sent none, never `null`, so absence is unambiguous |
| `windows[].notStarted` | Bool | our verdict at `observedAt`, from `CodexQuotaWindow.hasNotStarted(now:)`: `usedPercent` is 0 and `resetsAt` sits a whole duration ahead (±120 s on the near edge, up to twice the duration on the far) |
| `spendControlReached` | Bool | the account-level flag, **absent** when the server sent `null` |
| `rateLimitReachedType` | String | which limit the account is up against, in the server's words; **absent** when `null`. An open vocabulary — group with a fallback bucket |

**Every poll is written, unchanged or not, and that is the difference from
`status-payloads-dev-*`.** A window that has not started reports a `resetsAt` recomputed as `now`
plus its own length on every request, so it differs in every response while meaning "nothing is
happening"; a change gate would keep exactly those lines and drop the anchored ones. Two
consequences for processing:

- **The cadence is data.** A gap between consecutive `observedAt` values means the app stopped
  observing — there is no `resume` marker in this file, so gaps are found by differencing
  `observedAt` against the ~180 s poll interval. An unbroken run of identical readings means the
  state held, and is not redundancy to deduplicate away.
- **`notStarted: true` lines are the point, not noise.** They are the opposite of the release-side
  admission rule: the usage journal records history and skips readings it cannot vouch for, this
  file captures evidence and keeps them. Filtering them out is what makes a window anomaly
  unreconstructable.

**Two things never reach the file, and both are the normalizer's doing rather than the log's.** A
window whose `windowDurationMins` is zero or negative is dropped before the record is built, and a
read carrying no `rateLimits` at all throws as not-signed-in — so a failed poll writes nothing and is
visible only as a gap. Neither has been observed on a live account; if a gap ever needs explaining,
the `codex quota unavailable: <reason>` line in the app log is where the reason is.

**Read `notStarted` as one poll's verdict, not as a fact about the window.** It is a pure function of
one payload, so a degraded backend can flip it for a single reading. The sequence is what carries
meaning: whether the anchor was lost in one tick or drifted, whether the horizon ever stabilised, and
whether `usedPercent` stayed flat at 0 or wobbled. A live account has been observed reporting 3 %
against a fixed reset, then ~14 hours of 0 % with a moving horizon, then 3 % again against a fresh
anchor — the counter preserved behind the zero the whole time
([#515](https://github.com/artem-from-ua/tokenpace/issues/515),
[#519](https://github.com/artem-from-ua/tokenpace/issues/519)).

**Nothing identifying is in the file** — no email, no `codexHome`, no auth path, no reset-credit id.
`account/read` returns the email in the clear and is never called; the plan word is not recorded
either.

## Granularity: what can be measured and what cannot

**Polling happens no more than once every 3 minutes, and once every 15 while idle**
([ADR-0032](../adr/0032-simplified-polling-cadence.md)). This is the physical resolution limit of
everything computed from the journal.

Measured on real series:

| Series | Median interval | Share of intervals > 20 min |
|---|---|---|
| Max, August 2026 | 3.2 min | 0.6% |
| Pro, August 2026 | 15.0 min | 5.1% |

The interval distribution is **bimodal**, not continuous: 3.2 min (the regular poll) or ~16 min
(after idling). There is almost nothing in between — on the Max series there are 20 out of 5,679,
i.e. 0.35%.

### Consequence: durations are quantized

Any duration computed as a difference between measurements is a **sum of whole intervals**. On a
series with a 3.2 min step, real values cluster at 6.4 · 9.6 · 12.8 · 16.0 · 19.3 min — and
**between the clusters no values exist at all**.

This is not noise that smooths out on a large sample. It is a comb, and it breaks histograms:

> **Trap.** A logarithmic bin grid cuts across that comb at an angle: some bins catch two clusters
> each and look overflowing, others land exactly in a gap and come out **empty next to saturated
> neighbors**. On a real series the 9.8–12.2 min bin turned out to be zero while its neighbors had
> 238 and 242 observations. It looks like lost data — in fact no values can be there.
>
> **How to do it right:** bin by a whole number of polling steps (`k · poll`, `k = 1, 2, 3…`), not
> geometrically. After that the Max series was left with 1 empty bin out of 28 — and that one in the
> tail, where there is simply little data.

### What you must not do with this

- **Do not compare absolute short durations between users with different intervals.** A 10-minute
  pause in a series with a 15-minute step is invisible entirely. The comparison is only valid at
  scales noticeably larger than the coarser of the two steps.
- **Do not treat single-sample events as having a duration.** A lone measurement with an increment
  records the fact that work happened, but its duration is unmeasurable: it is somewhere between 0
  and one step.
- **Do not draw conclusions below the resolution limit** — that is `2 · poll` for any quantity
  computed as the difference between two moments.

## Deduplicating windows: `resets_at` comes in doubles

The same reset shows up in the journal in two spellings a second apart: `06:59:59.883…` and
`07:00:00.276…`. That is one reset, not two windows.

Grouping by the raw value gives a **catastrophically wrong result**: on the Max series — **4,207
"windows" instead of 73**, nearly a sixtyfold overcount.

```python
# CORRECT: round to the minute
key = reset.replace(second=0, microsecond=0) + timedelta(minutes=1 if reset.second >= 30 else 0)
```

For weekly windows it is more reliable to group **by the day of the reset** — the one-second error is
there too, but the windows are 7 days apart, so collisions do not happen.

> Separately: `resets_at` values that land **exactly** on a 10-minute boundary with no fractional
> seconds are the old local fallback, not server data. The details and how to tell them apart are in
> [usage-api-quirks.md § "The 10-minute grid in the data is ours, not the server's"](usage-api-quirks.md#the-10-minute-grid-in-the-data-is-ours-not-the-servers).

## Reset detection: the instant plus the drop, never just one

The deduplication above gives you **window boundaries**. But "when exactly did the window turn over"
is a separate question, and the naive answer to it is wrong twice over.

**A reset = a shift of the `resets_at` instant AND a drop in `util`.** Both conditions are required:

- **The `util` drop alone** is not enough: it can be a give-back
  ([#239](https://github.com/artem-from-ua/tokenpace/issues/239)), i.e. quota returned without the
  window turning over. Confusing the two means breaking the very feature the journal is collected for.
- **The instant shift alone** is not enough: the instant drifts forward on an idle window without any
  spend at all.

```python
TOLERANCE_S  = 600    # 10 min: damps resets_at jitter and optimistic rounding
MIN_DROP_PP  = 1.0    # the util drop has to be meaningful

moved = (abs(epoch - epoch.shift()) / 1e9 > TOLERANCE_S)   # the instant shifted
      | (epoch.isna()  & prev.notna())                     # instant → empty
      | (epoch.notna() & prev.isna())                      # empty → instant
moved.iloc[0] = False                                      # the first sample is not an event
turnover = moved & (util_drop >= MIN_DROP_PP)
```

**Why `TOLERANCE_S = 600`.** Two sources of noise add up: the API jitters the fractional part of
`resets_at` on every poll, and near the boundary the app optimistically rounds the next reset forward
by up to ~10 min ([ADR-0030](../adr/0030-optimistic-reset-and-exact-timer.md)). Without a tolerance,
naive comparison yields **about 200 "resets" a day instead of three**.

### An empty `reset` is a window identity, not a missing value

The subtlest spot. `""` means an idle window with no pacing geometry, and the transition **into**
emptiness is just as much a turnover event as a shift to a new instant. That is why the condition
above has three branches, and `NaT` participates as a full-fledged value.

> **What breaks without this.** A naive `dropna()` eats idle windows: one reset is lost entirely,
> another is dated **8 hours later**. After the fix, the share of `h5` resets observed live rose from
> 5 out of 10 to **8 out of 10**.

### Optimistic rounding understates the peaks

Take the reset instant from the **last `reset` among the samples before the drop**, rounded to the
minute — not from the first sample after it. Otherwise the window peak is systematically understated:
the measured discrepancies were **67% instead of 21%** and **49% instead of 42%** on the same windows.

### An event "across a gap" is undated

If the turnover happened inside an observation gap, we know neither when it was nor whether there was
only one. Mark it with its own flag (`across_gap`) and **do not date it**: the detection timestamp is
the moment we looked again, not the moment of the event. Take the actual instant from `prev_reset`.

The threshold for the flag is a **gap > 15 min**. Without it, 4 out of 5 flags turn out to be
3-minute gaps — i.e. the ordinary polling cadence.

## An observation gap is a first-class entity

`pausePollingWhenScreenLocked` stops polling while the screen is locked, so **gaps in the series are
by design**. The main invariant:

> **"No data" ≠ "nothing happened."** Never interpolate across a gap, never connect it with a line,
> and never count a gap as zero.

A gap is identified by **two independent signs**, and one of them is enough:

```python
CADENCE_IDLE_S  = 900     # conservative default: the per-sample cadence is unknown
GAP_MULTIPLIER  = 2

break_here = (dt_s > CADENCE_IDLE_S * GAP_MULTIPLIER)   # spacing twice the idle cadence
           | (sample is first after a `resume` marker)  # the app recorded the gap itself
```

The `resume` marker is **more authoritative** than spacing: it is the app's own decision, not our
guess. It also carries the gap length, so its start is reconstructed as `t − gap_s`.

**Both signs are per provider.** The marker names whose gap it is, and the spacing test must be run
over one provider's lines — computed over a mixed file it measures the interleaving of two cadences,
not a hole in either.

Practical consequences:

- **Every segment is a separate line on the chart.** No stroke crosses a gap.
- **Increments sum only within one segment**, and only positive ones.
- **`error` is not a gap.** "We looked and could not" is a separate layer; drawing it in the same gray
  as "we did not look" means stating something untrue. Nor is one `error` line one attempt — see the
  `n` trap above; a band drawn from `t` to `tEnd` is the honest width for a collapsed run.
- **A gap shorter than ~30 min** should be drawn as a tick on the axis, not a full-height band:
  otherwise a 15-minute gap carries as much visual weight as a nine-hour one.

## When to count states: three time samples, and why this is not cosmetic

The question "how long was the bar orange" has no answer until you say **which time** the share is
taken from. Three options, from the coarsest:

| Sample | What it includes | How to get it |
|---|---|---|
| **Computer unlocked** | everything in the journal | filter nothing |
| **Session active** | the app considered the session alive | `sessionIdle == false` |
| **Working with Claude** | the moments when requests were actually going out | ±15 min around `util` growth |

The first is free: polling stops while the screen is locked
([ADR-0032](../adr/0032-simplified-polling-cadence.md)), so **every record in the journal is already
a moment with the computer unlocked**. No separate filter is needed for it.

### Why `sessionIdle` is a coarse filter

It is the app's flag about its **own** state, not the fact of working with Claude. The measured
difference:

| | Computer unlocked | `sessionIdle = false` | Working with Claude |
|---|---|---|---|
| Max series | 323.4 h | 228.7 h | **172.7 h** |
| Pro series | 162.4 h | 70.6 h | **23.5 h** |

On the Pro series `sessionIdle` **overstates activity threefold**.

### Detecting work by `util` growth

The direct evidence of a request is the counter going up. A ±15 min window is taken around each
moment (overlaps are merged) to cover the pauses between requests inside a session.

```python
same_window = (cur.reset and prev.reset
               and abs((cur.reset - prev.reset).total_seconds()) <= 90)
if not same_window: continue            # a reset or a window shift — not work
delta = cur.util - prev.util
if delta > 0: moments.append(cur.t)     # negative is a give-back, also not work
```

The `same_window` check is mandatory: without it the drop to zero at a reset and the jump after a
`resets_at` shift read as activity. **What exactly gets filtered out** (Max series): of 1,622
rejected transitions, **1,522 are pairs of idle windows** where both `reset` fields are empty and no
growth was possible; genuine resets number 44, window shifts 56. The filter does not eat work.

### Why this changes the conclusions, not just the numbers

The share of time when the 5-hour bar demanded action (orange + red), on the Pro series:

| Sample | Share |
|---|---|
| Computer unlocked | 7.6% |
| `sessionIdle = false` | 17.5% |
| **Working with Claude** | **34.4%** |

On the coarse sample this reads as "almost never"; on the precise one, **a third of working time the
bar is asking you to slow down**. Idle time systematically dilutes the sample and understates the
share of states that demand action.

**Rule:** for any metric of the form "how long was the bar in state X", use the "working with Claude"
sample. For metrics about the resource itself (how much was consumed, how much burned) no filter is
needed — there the unit is the window, not time.

### The limit of applicability: blocked states are not covered here

**The "working with Claude" sample answers questions about non-blocked states.** The red state by
definition has no `util` increments — the window is exhausted, the counter sits at the ceiling — so no
halo around increments is built for it.

Measured: the single `5h = red` episode on the Pro series lasted 114 min, and only **14% of its
samples** fell inside the activity window. For comparison, `yellow` and `orange` are retained at
65–92%.

This is **not a flaw in the filter but the limit of its purpose**. The consequence for the work:

- **The question "what share of time was the bar orange" belongs to this sample.** It is about pacing,
  i.e. about the states in which the user can still change something.
- **The question "how long was I blocked" belongs to a separate metric.** Being blocked is an **event
  with a duration**, not a state with a share: it is described by the number of episodes, their length,
  and how much time was left before the reset at the start of each. A stacked bar of shares will not do
  here — it would dissolve
 a two-hour idle stretch into hundreds of hours of observation.
- **They must be drawn as different shapes.** State shares — a stack or a matrix; blocking episodes —
  an event timeline or a distribution of durations. Mixing them in one diagram means comparing
  quantities of different natures.

## Stitching sessions: the threshold is a parameter, not a constant

The journal has no "the user was working" field — a moment of work is detected the same way as in
["Detecting work by `util` growth"](#detecting-work-by-util-growth) above. A "session" does not exist
in the journal either. It is **constructed** by stitching together moments of work separated by
pauses shorter than a threshold. The analyst picks the threshold, and everything depends on it:

| Stitching threshold | Sessions | Median | Typical (lognormal) |
|---|---|---|---|
| 20 min | 87 | 44 min | 35 min |
| 40 min | 53 | 98 min | 70 min |
| **60 min** | **37** | **178 min** | **121 min** |
| 80 min | 28 | 296 min | 168 min |
| 120 min | 25 | 296 min | 201 min |

The spread of the typical duration is **×5.7** between the ends of the range. Therefore:

- **Never quote an "average session duration" without the threshold it was obtained with.** Without
  the threshold that number is not a quantity, it is a choice.
- **The threshold is not found in the data.** Pauses are power-law distributed (see below), so there is
  no natural boundary of "the session ends here" at any scale.
- **The practical choice is where the session-count curve flattens out.** On the Max series that is
  ~60 min: up to it the count halves (87 → 37), after it barely moves (37 → 25).

### Recommended default

**60 minutes** for series with a 3 min step. For series with a 15 min step the lower thresholds are
degenerate — there every moment of work becomes its own session, because shorter pauses are simply
invisible.

## Statistical properties, verified on real series

Knowing these facts saves you from false interpretations.

### Pauses are power-law — there is no characteristic size

The CCDF of pauses falls on a straight line in log-log coordinates across four orders of magnitude
(3 min → 30 h), exponent **−0.83**, R² = 0.91. Testing the "two regimes" hypothesis with a break at
20/30/45/60/90/120 min shows that **no break improves the description**.

Consequences:

- **A "typical pause" is a quantity without meaning.** The median is 6.4 min, yet 33% of all idle time
  falls in pauses longer than 12 hours.
- **You cannot tell from a pause's duration whether the session has ended.** A pause that has lasted an
  hour is, by the same logic, as likely to end at minute 61 as at minute 5.

### Sessions are lognormal — there is a characteristic scale

Unlike pauses. The fit error (KS) is 0.14–0.19 for lognormal against 0.24–0.39 for power-law; a
bootstrap over 300 resamples gives lognormal the win **in 100% of cases at all six thresholds**.

This means the question "is this session unusually long" **is meaningful**, unlike the same question
about a pause.

### Rhythm exists only at the daily scale

A periodogram of the increment series with a significance threshold from 120 shuffles:

- the dominant peak is at **23.4 h** — 7.8× above the noise;
- **below 6 hours there is almost no structure** — of 43 short periods tested, 2 clear the threshold.

That is, **inside a session the work is even**, with no periodicity of its own. You will not build a
short-term forecast from the rhythm; a daily one you can.

### Pauses have a weak memory

Autocorrelation of the log durations: `r = +0.14` at lag 1 against a noise threshold of 0.077,
**p = 0.0005**. The effect is small but robust. This does not contradict the power-law distribution:
that describes *which* durations occur, autocorrelation describes *in what order*.

## Noise and significance

The series are short (weeks, not years), and most of the interesting quantities have heavy tails. So
**almost every "pattern" you find has to be checked against a null model**, otherwise you find
structure in randomness.

### The null model: shuffling

The cheapest and most reliable method for this data. The idea: preserve the distribution of values,
destroy the temporal order — and see whether the effect survives.

```python
import random
def null_threshold(values, statistic, n=400, q=0.95):
    """Threshold: the 95th percentile of the statistic on shuffled data."""
    nulls = []
    for _ in range(n):
        shuffled = values[:]
        random.shuffle(shuffled)
        nulls.append(statistic(shuffled))
    return sorted(nulls)[int(n * q)]
```

What to check with what:

| Hypothesis | What to shuffle | Statistic |
|---|---|---|
| "there is periodicity" | bins of the increment series | power at the period |
| "pauses remember the previous one" | the sequence of pauses | lag-k autocorrelation |
| "night pauses are different" | the night/day labels | difference of the exponents |
| "the pause is longer after intense work" | the pause values | ratio of medians |

**Number of iterations:** 200 for a rough idea, 400–2000 when the number is going into the UI or into
a decision.

### An example of why this is not a formality

On a real series three hypotheses looked equally convincing "by eye." After the permutation test:

| Hypothesis | Effect | p | Verdict |
|---|---|---|---|
| pauses have memory | r = +0.14 | **0.0005** | proven |
| night pauses have a different exponent | −0.70 vs −0.91 | 0.062 | a trend |
| the pause is longer after a large increment | ×1.48 | 0.054 | not proven |

Two of the three failed the 0.05 threshold — and without the check all three would have gone into the
conclusions as equals. **An effect of ×1.5 on 695 observations can be noise** — that is
counterintuitive, and exactly why the check is mandatory.

### Careful with a hypothesis picked after the fact

If you try 20 slices and take the best one, one of them will show p < 0.05 purely by chance. When
there are many slices, either apply a correction (Bonferroni: `p · number_of_tests`) or honestly write
"found by search, needs confirmation on a new series."

## Confidence intervals

Quoting a bare point estimate on a short series is the most common way to overstate your confidence.

### The bootstrap is the universal method for this data

The distributions are not normal (power-law, lognormal), so formulas along the lines of `± 1.96 σ/√n`
do not work. The bootstrap always does:

```python
import random, statistics as st
def bootstrap_ci(values, statistic=st.median, n=2000, alpha=0.05):
    """95% CI by the percentile bootstrap."""
    boots = []
    for _ in range(n):
        sample = [random.choice(values) for _ in range(len(values))]
        boots.append(statistic(sample))
    boots.sort()
    return boots[int(n * alpha / 2)], boots[int(n * (1 - alpha / 2))]
```

### How much data is needed for what

| Quantity | Minimum | Why exactly that much |
|---|---|---|
| Median pause | ~50 pauses | heavy tail, wide CI |
| Coefficient N | 10–15 ticks of `d7_util` | the weekly counter moves rarely |
| Weekly loss | 8–10 full weeks | two windows are too few for an average |
| Power-law exponent | ~100 values | the CCDF slope is sensitive to the tail |
| Daily profile | ≥ 5 observations per hour | otherwise the hour's median is untrustworthy |

**A measured example:** for N on the daily series the 95% CI came out as **8.9–10.8** against a point
estimate of 9.76. So "≈10" is the honest phrasing, while "9.76" in the UI creates a false impression
of precision.

### Presentation rules

- **In the UI a rounded number, in a document one with a CI.** "≈10 windows" is more useful to the user
  than "9.76".
- **While the data is thin, write "still counting" rather than a premature estimate.** This is stated
  outright in [users-and-goals.md](users-and-goals.md) about the coefficient N.
- **Never quote a CI where the sample is < 10.** It will be wider than the quantity itself and will
  only confuse.

## Coefficient N: how much of the 5h scale fits in one point of the weekly one

It makes the two incomparable scales commensurable. It is measured **from the user's own series**:

```python
# cumulative sums of positive increments, NOT the instantaneous ratio of derivatives
N = sum(positive_deltas_h5) / sum(positive_deltas_d7)
```

Measured values: **9.76** (Max) and **10.18** (Pro) — that is, one fully burned 5-hour window eats
~10 pp of the weekly limit.

- **Do not hardcode it.** N depends on the plan, the model mix, and whatever promotions Anthropic has
  running.
- **Do not compute an instantaneous ratio.** `d7_util` is an integer and moves rarely; dividing
  step-by-step gives you zeros and infinities.
- **You need ≥ 10–15 ticks of `d7_util`**, i.e. several days. Until then, show "still counting".

A derived quantity convenient for the UI: `100 / N` ≈ **10.2 pp** — the cost of one full window — and
`remaining_% · N / 100` — the remainder of the week in "full 5-hour windows".

> **Terminological trap.** A "full 5-hour window" as a unit of measurement ≠ a real work session. A
> real session lasts ~2 h and spends a quarter of the window. Phrasing it as "9.2 sessions left" reads
> as a forecast of how many sessions there will be and is **misleading** — the correct form is "the
> limit will cover 9.2 full 5-hour windows".

## Observation completeness

The journal is only written while the app is running. So before any per-window aggregate you have to
decide whether the observation is sufficient.

### For 5-hour windows

A window qualifies if: the last measurement is **no more than 30 min before the reset**, **≥ 3 h** of
the window were observed, and it contains **≥ 10 measurements**. On a real series this leaves 44
windows out of 71.

### For 7-day windows

**The criterion is whether the app was running at the moment of the reset** (`timePct ≥ 0.985`),
because that is when the final peak is visible.

> **A trap that is easy to fall into.** Requiring that you also see the *start* of the window is wrong:
> a window you connected to at 96% of its duration still gave you a measured final peak. The additional
> requirement `timePct_first ≤ 0.05` mistakenly throws such windows into the "incomplete" pile.

### An unfinished window — extrapolate it, do not discard it

A window still in progress gives a nonsensical "remainder" if you take its peak as the final one. The
right way:

```python
projected = min(100.0, peak / last_timePct)   # "if the pace does not change before the reset"
```

On real data this changed the week's estimate from "77% loss" to "8.8%" — because the window had only
lived a quarter of its time. **Mark extrapolated values as a forecast** and do not mix them with
measured ones in the totals.

## The peak versus the last value

For "how much was consumed over the window", take the **maximum over the window**, not the last
measurement: the counters sometimes roll back (a drop from 67% to 21% was observed inside a single
5h window).

## Two weekly limits

`scoped[]` holds a **separate seven-day per-model limit** (`Fable` was observed) with its own `pct` and
the same reset schedule as `d7`.

- Most analysis needs **only `d7`**.
- **Do not multiply the losses of both by the full subscription price** — both limits are covered by
  the same payment, so that is double counting.

## If we ever read Claude Code transcripts

The journal carries no attribution: it knows **how much** was consumed but not **on what**. The
temptation to take that from Claude Code's own `.jsonl` transcripts is strong — they have the project,
the branch, the model, the tokens. But the fields there have **varying reliability**, and confusing
them is expensive.

| Field | Reliability | Why |
|---|---|---|
| `message.model` | **reliable** | a structural fact |
| `cwd`, `gitBranch`, `sessionId` | **reliable** | structural facts |
| `tool_use.name` | **reliable** | a tool was either invoked or it was not |
| `cache_read_input_tokens` | **reliable** | matches ground truth ≈1× |
| `message.usage.input_tokens` | **UNRELIABLE** | a streaming placeholder; undercounts **by up to 137×** |
| `message.usage.output_tokens` | **UNRELIABLE** | does not include thinking tokens; **10–17×** on Opus |
| the same after deduplicating by `requestId` | **partially** | dedup removes the double counting but does not cure the placeholders |

**The conclusion worth remembering: read the transcript for attribution, not for tokens.** Who worked
and on what — exactly. How many tokens — no.

The reliable track for tokens and cost is the **statusline** (`context_window.*`, `cost.*`): it is
maintained internally from finalized API responses, on a separate path from the JSONL.

> **`cost.total_cost_usd` is an API equivalent, not money off the subscription.** Phrase it only as "it
> would have cost $X at API prices", never "you spent $X". On Max the subscription is already paid for.

**Privacy.** The project path is PII: store a hash plus the folder name, not the full path. Branch
names can contain ticket numbers. Do not store transcript contents (code, secrets) at all — aggregate
them in place.

## Converting to money

```
averageWeeksInAMonth = 365.25 / 12 / 7 = 4.3482
weekly cost          = monthly price / 4.3482
loss, €              = lossPercent / 100 · weekly cost
window cost, €       = weekly cost · (100 / N) / 100
```

Measured reference points: Max €110.70/mo → €25.46/week → **€2.60 for a full 5h window**;
Pro €22.14/mo → €5.09/week → **€0.50**.

**Careful with the interpretation.** An unspent limit is not a loss. A week with less need is simply
smaller, not wasted. The number is useful for one decision — **whether the plan is justified** — and
that is made once every few months, not every week.

## Optimizing app behavior: the criterion gets written first

A pacing rule, a threshold, a notification trigger — all of these are **optimized against a
criterion**, and the criterion has to be written down **before** the first measurement. Otherwise
what happens is what already happened in this project: every new criterion produced a different
ranking, and the comparison got tuned to fit the result.

A measured example of how that looks:

| Criterion | Who "won" | Why the criterion is wrong |
|---|---|---|
| "will the window reach 70%" | `util ≥ 70%` | the rule fires **after** the condition arrives — that is a statement of fact, not a forecast |
| accuracy + coverage | predictive `u/t ≥ 0.9` | ignores stability: on one series it added episodes and switches |
| + flapping | the current rule | three dimensions pull in different directions, and nobody assigned weights between them |

### The structure of a criterion: three mandatory parts

**1. What the rule must do — in one sentence, in terms of a user action.**

Not "predict high `util`", but "warn at the point where a change in behavior can still change the
outcome". The metric falls straight out of that phrasing: not prediction accuracy, but **whether
enough time was left to react**.

**2. What the rule may not do — constraints that disqualify a candidate regardless of metrics.**

These checks are binary: fail one and you are out, no matter how much you win on the other
dimensions.

| Constraint | How to check it | Where it came from |
|---|---|---|
| do not alarm when the user is **behind** the pace | share of firings with `util ≤ timePct` = 0 | the `util ≥ 70%` rule produced 43% of those |
| do not blink | median episode > 20 min, windows with 3+ switches = 0 | one window switched 8 times |
| do not carry a constant across windows | every threshold is a function of `windowDurationSeconds` | the 5h threshold in the 7d hysteresis made blue unreachable |
| do not depend on cosmetic settings | `sev` is computed without `ColorAdvice` | otherwise series from different users are incomparable |

**3. How much data it takes for the answer to mean anything.**

Comparing alarm rules is limited not by the total number of windows but by the number of **events
the rule was supposed to catch**. By the maturity thresholds from this same file — **15–20 such
events**.

### The criterion for yellow-orange

**What it does:** warns that at the current pace the window will be exhausted before the reset —
while there is still time to ease off.

**The key observation from the data: the event it warns about almost never happens.** On the Max
series, exhausted windows (`util ≥ 95%`) — **zero out of 50**; on the Pro series — **one out of 15**.
High ones (`≥ 70%`) — 4 and 5 respectively.

Two conclusions follow:

- **Optimizing accuracy on a sample like that is impossible.** A difference of "40% versus 67%" on
  four events is one or two windows, i.e. noise. Any ranking of formulas here would be random.
- **The question of whether this warning is needed at all is legitimate.** If the window is never
  exhausted, the signal guards against an event that does not occur. But the sample is small and
  atypical (one series was captured during a vacation period), so this is a hypothesis, not a
  conclusion.

**The formal criterion, once there is enough data:**

```
among windows that reached exhaustion:
    share where the rule fired at least 30 min beforehand   → maximize
among windows that did NOT reach it:
    share where the rule fired                              → minimize
subject to: no firing when util <= timePct,
            median episode > 20 min
```

30 minutes is not an arbitrary number: it is the time in which, on a 5-hour window, you can shift
your pace enough to change the outcome (at a median speed of ~19 pp/h that is ~10 pp).

### The criterion for blue-green — it is **not** about headroom, it is about money burned

This framing comes from the maintainer, and it changes the criterion completely: blue does not say
"you have headroom", it says **"you are paying for air"**. So what gets optimized is not the accuracy
of the state description, but **how much burned quota it helped rescue**.

**Measured on the Max series:**

| Quantity | Value |
|---|---|
| Burned in total | **30.5 full windows** |
| Of those, theoretically rescuable (≥ 2 h left and peak < 60%) | **6.3 windows** |
| Windows where blue was shown | 28 |
| Of those, genuinely rescuable | 7 |

**So three quarters of blue's firings are pointless** — it lights up in windows that would have
ended fine anyway, or where there is no longer time to do anything. This is the opposite problem
from orange: there the signal is too rare, here it is too generous.

**The formal criterion:**

```
maximize: pp of burned quota in windows where blue appeared
          while >= 2 h still remained until the reset
minimize: time blue was shown in windows that ended above 60%
subject to: the same four constraints from the table above
```

The second part matters: blue in a window that is going to be used anyway is not harmless noise but
**an invitation to spend quota for no reason** — exactly what
[users-and-goals.md](users-and-goals.md) warns against.

**Why "100% accuracy" for the current threshold proves nothing.** The criterion "the window ended
below 60%" is satisfied by 42 of 50 windows — with a base rate like that, almost any rule will hit.
An easy criterion gives a false sense that the threshold is optimal.

### It depends not on the plan but on the consumption profile

It is tempting to say "the criterion depends on the plan", but that is imprecise. The plan is only
one of three components, and on the measured series it is **not the most important one**:

| Component | Max series | Pro series | Difference |
|---|---|---|---|
| **Plan** | `max`, €110.70/mo | `pro`, €22.14/mo | ×5 in price |
| **Work schedule** | 10.2 h/day, 2.9 windows/day | 2.1 h/day, 1.4 windows/day | **×5 in density** |
| **Typical tasks** | median burst 34 pp, p90 65 | median 30 pp, p90 80 | **nearly identical** |
| **CC settings** | unknown — not in the journal | unknown | not measured |

The most surprising thing here is the third row: **the size of a typical task is nearly the same for
both**. Both run comparably heavy jobs; the difference is entirely in **how many such runs fit into
a day** and **how many windows take them in**.

Treating this as a "plan" difference would mean crediting price with what the schedule does.

**Four components of a profile, each with its own contribution:**

1. **Plan** — how much work a window holds. Determines whether the ceiling is reachable at all.
2. **Schedule** — how many windows a day open and how densely they fill. Determines how often there
   is anything to show in the first place.
3. **Typical tasks** — the weight of one run in points. Determines whether a single task can exhaust
   a window or whether it takes a series of them.
4. **Claude Code settings** — the model chosen, the reasoning effort level, use of workflows and
   subagents. The same request on Opus at high effort and on Sonnet costs different fractions of a
   window, and a workflow with fan-out multiplies that by the number of agents.

The first three are measurable from the journal with no extra fields at all — everything is visible
from `util` increments and the schedule of windows.

> **The fourth component is unavailable from the journal.** A line has `plan`, `tier` and `scoped[]`
> (per-model limits — on the measured series, only `Fable`), but **neither the chosen model, nor
> `effort`, nor any trace of a workflow or subagents**. So any difference they cause currently looks
> like "unexplained spread in task weight" and gets attributed to the third component.
>
> This is the most likely explanation for why the median burst on the two series matches (34 and
> 30 pp) while `p90` diverges (65 versus 80): the heavy tail may be about the model a task was run
> on rather than the size of the task. **Telling those apart is impossible with the data at hand** —
> it needs the statusline fields (`model`, `ctxOut`), which is exactly why they are in the registry
> of fields for extending the journal.

**Practical consequence for analysis:** a conclusion about "the user's typical tasks" holds only
until they change model or effort. When comparing series captured in different periods, you have to
assume the fourth component may have changed silently — it leaves no trace whatsoever in the journal.

**Consequence for analysis:** the result of a formula comparison is reported **per profile
separately**, and a profile is described by all three components, not by the plan alone. Series with
different profiles are not mixed — otherwise the averaging hides the very difference the signal
exists for.

### How this looks on the two series at hand

The two formulas weigh differently on different profiles, so **there is no single optimum**. The
contrast on the measured series:

| | Max series | Pro series |
|---|---|---|
| Windows exhausted (`≥ 95%`) | **0 of 50** | **1 of 15** |
| High windows (`≥ 70%`) | 4 | 5 |
| Alarming (orange+red) while working | 2.5% of the time | **34.4%** |

**Yellow-orange matters more on the smaller plan**, because subscription windows there hold fewer
tokens: the same work brings you up against a ceiling that is out of sight on Max. A rule tuned on a
series where exhaustion never once happened will be too late for that user.

**Blue reads differently on the smaller plan too.** On Max it says "you are saving", on Pro —
**"the window is fresh, get something big started"**: when the limit is tight, it matters to know
that a big run will still fit whole rather than being cut off halfway. This is not the same signal
with a different weight but **a different action**: where one user reads "no need to hurry", the
other reads "now or never".

**Consequence for the method:** the rule is optimized **separately for each profile** — plan,
schedule and typical task weight together. A criterion collapsed to a single number on a mixed
sample will hide the very difference the signal exists for.

### What this means for the work right now

**Do not change any formula until the data accumulates.** Not because the formulas are flawless —
yellow-orange has 40% accuracy, blue has 75% pointless firings — but because **on 4–5 events any
change is fitting to two series**, one of which was captured in an atypical period.

**What to do instead:** write a second verdict in parallel
([#426](https://github.com/artem-from-ua/tokenpace/issues/426)) and accumulate. In 8–10 weeks there
will be 15–20 events, and the criteria above become applicable.

## Mandatory: check for signal before generating, not after

**Every analytical artifact must contain a section about whether its diagrams carry a signal that is
useful to the user.** Not "what you can see", but **what to do about what you see**. If there is no
signal, that is a result too, and it has to be stated plainly.

**The order matters: the question is asked before anything is drawn.** Building a diagram and then
looking for meaning in it is the most expensive way to work: time goes into a form that may turn out
to be unnecessary, and the temptation arises to justify what has already been made. The right order
is this.

### Before building

1. **State which decision this will affect.** One sentence of the form "having seen this, the user
   will do X instead of Y". Doesn't pass — say so to whoever asked **before** building, not after.
2. **Check whether the requested diagram can even carry that signal.** It often turns out that an
   adjacent form or a different sample is what's needed — and asking is better than drawing the
   wrong thing.
3. **If there is no signal in pure form, propose how to get one:** extend the diagram (add a
   dimension, a toggle, a marginal bar), change the sample, or take a different metric from the same
   data. The proposal is stated **before** generation, together with an estimate of what exactly it
   adds.

### In the artifact itself

A section at the end, next to the conclusions. What it has to contain:

- **What acts on this.** A concrete action, not "interesting to know".
- **What not to do.** This is most often where the important part hides: numbers that look like a
  call to optimize something but are not actually a debt (unspent quota, a calm week).
- **Why the alternative approach didn't work.** If options were tried and dropped — name them with
  the reason; it saves the next person from repeating them.

### The parameter panel — sticky on scroll

If an artifact has controls that change **all** the diagrams on the page (data source selection,
time sample, processing threshold), they have to stay reachable once the reader has scrolled down.

```css
.toolbar{
  position:sticky; top:0; z-index:20;
  margin:0 -24px; padding:12px 24px;              /* compensate for the wrapper padding */
  background:color-mix(in srgb, var(--ground) 88%, transparent);
  backdrop-filter:saturate(180%) blur(12px);
  border-bottom:1px solid transparent;            /* the border appears only once stuck */
}
.toolbar.stuck{ border-bottom-color:var(--line); box-shadow:0 2px 12px rgba(0,0,0,.06) }
```

The `.stuck` class is attached via an `IntersectionObserver` on an empty sentinel element **before**
the panel: `position: sticky` on its own gives no way to know whether it has engaged, and a shadow
in the unstuck state looks like a stray line in the middle of the page.

```js
new window.IntersectionObserver(([e]) => {
  toolbar.classList.toggle("stuck", !e.isIntersecting);
}, {threshold: 0}).observe(sentinel);
```

Three details, each for a reason:

- **A translucent background with `backdrop-filter`**, not an opaque one: content is visible
  scrolling underneath the panel, so it does not read as the page being cut off.
- **Negative margins the width of the wrapper padding** — otherwise the bar stops at the column edge
  and looks like a widget rather than a panel. They also require `overflow-x: hidden` on `body`.
- **A shadow only in the stuck state** — in the normal state the panel should be part of the page,
  not a separate element.

Do not make sticky: legends of individual diagrams, captions, anything that concerns **one** panel.
Only what controls everything gets to be sticky.

### First: the complete color rules, not just the thresholds

The most common mistake when comparing formulas is to take **only the threshold** and forget the
overrides. A rule consists of several branches, and each one catches something. A shorthand like
"`lead ≥ 0.16·(1−t)`" describes one branch out of four, and carried into code it produces different
numbers.

**Yellow → orange** (the `util > timePct` branch, the order of checks is mandatory):

```
if util >= 1                        → red        # exhausted
if remainingSeconds <= 20 min       → orange     # the window is about to reset, any gap is worth attention
if lead < 0.16·(1 − timeFraction)   → yellow
else                                → orange
```

**Blue → green** (the `util <= timePct` branch, also in order):

```
if util >= 1                        → red        # a just-reset 100% window reads as on-pace
if !blueAllowed                     → green      # blue is not offered here — see the three reasons below
if elapsed <= 20 min from the start → green      # early on, almost anything reads as a large surplus
if surplus > behindThreshold        → blue       # 2 h for 5h (0.40), 2 days for 7d (≈0.286)
else                                → green
```

**The zeroth branch is idle, and it is in neither of the two blocks.** If `reset` is empty or fails
to parse, there is no pacing geometry at all: `BarLayout` is not built, `timePct` is recorded as
zero, both 20-minute overrides and `blueAllowed` are inert, and the verdict comes from utilization
alone:

```
if reset does not parse   → (util >= 100 ? red : green)   # and no branch below runs
```

This is not rare: on the August series that is what **1,551 of 5,789** 5-hour windows look like
(27%), and 56% on the Pro series. A naive recomputation that runs them through the ordinary branches
will spoil more lines than it fixes. And separately: `timePct == 0` here means "there is no window
state", **not** "the window just started" — the only way to tell them apart is by an empty `reset`.

The two 20-minute overrides are **symmetric**: one guards the end of the window (so a gap right
before the reset is not missed), the other the beginning (so blue does not blink right after the
reset).

**`blueAllowed` is not cosmetics but a fact about the data**, and it has **three** reasons, not one
([ADR-0115](../adr/0115-no-blue-on-per-model-windows.md)). Blue says "the week has headroom you are
not using", so it is `false` whenever that statement is untrue, addressed to nobody, or meaningless:

| Bar | `blueAllowed` | Why |
|---|---|---|
| `d7` | `true` always | it does not gate itself |
| `h5` | `weeklyHasHeadroom` | the week must genuinely have headroom, otherwise the advice is unfunded |
| `opus` / `sonnet` / `scoped` | **`false`** | they **are** slices of that week — the advice is addressed to itself |
| credits, idle | `false` | they give no pacing advice at all |

The source of truth is `PacingBucket.of(_:)` and the `PacingModel` constants; when reproducing this
in analysis, port **all** the branches, otherwise the distributions will diverge from what the user
saw.

### The signal must not blink — and this is measurable

**A rule that switches back and forth on ordinary fluctuations is worse than no rule.** The user
stops reading it, and in the menu bar the blinking is physically distracting on top of that. So any
threshold is checked not only for accuracy but for **stability**.

Three metrics to compute before proposing a formula:

| Metric | How to compute it | What is bad |
|---|---|---|
| **Total switches** | how many times the state changed across the whole series | more than episodes × 2 |
| **Windows with flapping** | windows with ≥ 3 switches | any at all |
| **Median episode** | how long one activation lasts | shorter than ~20 min |

The last is the most important: an episode shorter than the time it takes to read the message does
not manage to say anything. On the measured series there was a window where the rule switched
**eight times** and the median episode dropped to **8 minutes** — the bar would have been blinking
for a quarter of an hour straight.

### What causes flapping

- **Division by a small quantity.** Rules of the form `util / timePct` are unstable at the start of
  a window: at 5% of elapsed time the denominator is tiny, and a single counter step throws the
  result across the threshold. The cure is a guard like `util ≥ 0.4`, not hysteresis.
- **A threshold in a dense region of the data.** A static threshold that lands on a typical level
  jitters on every poll. A dynamic threshold that moves away from the data is more stable — which is
  exactly why the current `0.16·(1−t)` flaps less than a static `0.10` despite worse accuracy.
  (Only the threshold branch is being compared — the overrides are identical in every variant.)
- **A window reset.** The state resets along with the counter; this is not flapping and hysteresis
  will not cure it — transitions across a window boundary have to be excluded.

### Thresholds do not carry across windows — not even derived ones

The incomparability of 5h and 7d applies not only to `util` but to **every derived quantity**,
color thresholds included. `behindThreshold` is **0.400 for the 5-hour** window (2 h) and **0.286
for the weekly** one (2 days): the same fixed width in real time, divided by different durations.

> **A trap that has already sprung.** The blue hysteresis was specified as a fixed pair, "enter 0.40
> / exit 0.35". The number 0.40 is the **5-hour** window's threshold; applied to the weekly one, it
> raised that threshold by **11.4 pp** and made blue there effectively unreachable. It showed up
> nowhere near the mistake: the `7d = blue` column vanished from the matrix, and with it the
> marginal cell for "5h blue" — which looked like 15 hours of blue disappearing from 5h.
>
> **The right way:** hysteresis is **relative to the window's threshold**, not absolute.
>
> ```python
> base = behind_threshold(window_seconds)      # 0.400 (5h) / 0.286 (7d)
> thr  = base * 0.875 if state == "blue" else base
> ```

The rule is broader than this case: **any constant taken from one window needs recomputing for the
other.** If a literal like `0.40` has appeared in the code, it almost certainly belongs to one
window — and it should be a function of `windowDurationSeconds`.

### Diagram axes come from the full set of states, not from the data at hand

An adjacent lesson from the same incident. The matrix axes were built from the list of
**intersections present**:

```js
const cols = SEV.filter(s => matrix.some(x => x.b === s));   // ✗ brittle
```

When one combination disappeared, a whole column disappeared — **together with a marginal cell that
did not belong to it**. The symptom pointed away from the site of the mistake, and finding it took
time.

```js
const cols = SEV.filter(s => matrix.some(x => x.b === s) || marginal7.some(x => x.k === s)); // ✓
```

The general principle: **the axis of a categorical diagram is derived from the domain, not from the
sample.** An empty row or column is information ("that state did not occur"), whereas a vanished
axis is lost context and a wrong conclusion about the neighboring data.

### Hysteresis: when it works and when it doesn't

Different thresholds for switching on and off ("enter 0.90 / exit 0.80") help only against jitter
**right at the boundary**. Measured on two rules:

| Rule | Without hysteresis | With hysteresis |
|---|---|---|
| the current rule (threshold branch) | 2 flap windows, median episode 19 min | **1 window, 62 min** |
| `forecast u/t ≥ 0.9` | 2 flap windows, 49 min | **no change** |

On the second rule hysteresis gave nothing, because its switching is caused not by jitter but by the
window reset. **Before adding hysteresis, work out what is actually switching the state.**

### Consequence for comparing formulas

Accuracy and stability often pull in different directions, and a win on one dimension is not a
victory:

| Rule | Accuracy | Coverage | Flap windows |
|---|---|---|---|
| the current rule | 40% | 50% | **0** |
| threshold replaced with a static `0.10` | 50% | 75% | 1 (8 switches) |
| threshold replaced with `util/timePct ≥ 0.9` AND `util ≥ 0.4` | **67%** | **100%** | 1 |

So a formula comparison table **must include a flapping column** — otherwise the choice is made
blind.

### The mandatory condition on color rules

Separately, because this is not about stability but about truthfulness: **an alarm rule must include
the "ahead of pace" condition (`util > timePct`)**. Without it, states arise that flatly lie.

Measured on the `util ≥ 70%` rule without that condition: **43% of firings landed on moments when
the user was in fact behind** an even pace. The worst case — `util 71%` at `92%` of time elapsed:
the person is underusing the window by 21 points, and the bar is demanding they slow down.

The check is simple and belongs in every comparison: **the share of firings where `util ≤ timePct`
must equal zero.**

### An example of how this looks in practice

A request to "twiddle the color switching thresholds" fails step 1: stretching `aheadThreshold` from
0.16 to 0.25 (by 56%) removes **less than half a point** of orange — the parameter is nearly
insensitive in the direction you would want to turn it — and moving the boundary changes the verdict
without changing the spending, contradicting the "value is input, color is output" principle from
[users-and-goals.md](users-and-goals.md).

**A replacement that yields an action instead:** a "how close to the threshold" panel — the
distribution of `lead = util − timePct` against the dynamic threshold curve. On the two series its
median came out opposite (**31%** of the threshold on one, typically far from the boundary; **174%**
on the other, typically already past it and effectively the normal working state) — both readings
are actionable, unlike a bare accuracy number.

## Which charts to build, and when

The form is chosen by the **reader's task**, not by what data happens to exist. Below are the types
tested on these series, with a note on what each one proves and where it lies.

> General plotting rules (palette, labels, legends, dark theme) live in the `dataviz` skill.
> This section covers what is specific to journal data.

### Time series / window trajectory

**When:** you need to show *how a value developed* inside a window — where work stalled, where it
spiked.

**Example:** weekly limit remaining versus fraction of elapsed time; a flat stretch = idle, a steep
descent = an intense session.

**Caveat:** prefer `timePct` on the X axis over absolute time — that makes windows of different
lengths comparable. Gaps in the data (the app was off) **must not** be joined with a straight line —
that draws in work that never happened; leave the gap, or use a dashed segment.

### Scatter

**When:** you are testing a relationship between two values at the level of individual windows.

**Example:** idle time before the reset × final `util`.

**Caveat:** both axes are often quantized (see above), so points land on a lattice — that is normal,
but do not add jitter: it hides the real discreteness. Compute correlation on logarithms if the
value has a heavy tail.

### CCDF in log-log coordinates

**When:** you need to answer whether the value — pauses, durations, gaps — **has a characteristic
size**.

This is the main instrument for these data. A straight line = a power law = no characteristic size;
a bend = a scale exists.

**Why CCDF and not a histogram:** a histogram of a heavy tail depends on the choice of bins, and the
tail always looks empty. A CCDF has no bins at all, so it does not have that freedom either.

**Caveat:** the slope is sensitive to the lower cutoff; report it together with R² and the range the
fit was done over.

### Histogram in logarithmic bins

**When:** you need to show **how much of what occurs**, and the value spans several orders of
magnitude.

**Caveat:** for durations, bin by polling steps, not geometrically (see the § on quantization). For
non-temporal values, geometric bins are fine.

### Spectrogram / "parameter × distribution" map

**When:** the result depends on a processing parameter, and you need to show that dependence itself
instead of hiding the choice of parameter.

**Example:** session count and duration as a function of the merge threshold; a two-dimensional
"threshold × duration" map.

**This is the most honest way to present a parameterized metric** — the reader sees what changes
with the threshold and can pick for themselves. The alternative (one number plus a footnote about
the threshold) hides the magnitude of the dependence.

**Caveat:** the map must mark the **resolution limit** — the zone where no values can exist.

### Bars split into "used / burned"

**When:** you need to show a share of a fixed whole — how much of the limit was consumed.

**Caveat:** show incomplete windows in a separate style (dashed, muted color) and label them as a
forecast, otherwise they read as a failure.

### Periodogram

**When:** you are testing a hypothesis about periodicity.

**Always with a noise floor** from shuffles — without it any spectrum has peaks, and they mean
nothing.

### Profile by hour of day / day of week

**When:** you need to show **when** the work happens.

**Caveat:** requires ≥ 5 observations per cell, otherwise the median is not trustworthy; empty hours
are better left empty than drawn as zero. Always check whether the sample covers every day of the
week — a 10-day series may contain no Sunday at all, and "zero on Sunday" will be an artifact rather
than behavior.

### State shares: a 5h × 7d matrix with marginal bands

**When:** you need to show how much time the bars spent in each color — separately and together.

This form has been tested on real series and answers a question two separate stacked bars do not.
Its parts, each with its reason:

**The 5h × 7d intersection matrix.** A row is the five-hour bar's state, a column is the weekly
bar's, a cell is the fraction of time when they coincided in exactly that way. It shows what the
separate distributions do not: **whether the bars alarm together or in turn**. On the measured
series — in turn: the alarming state on both at once takes fractions of a percent, while on at least
one of them it is an order of magnitude more. That directly justifies the "hide the calm bar"
default: at the moment it is calm, it really does carry no information.

**Marginal bands — the first row and the first column.** The same bar independently of the other
one: the row sum and the column sum. They stand **before** the intersection block and are separated
by a gap, because they are read first — first "how is each bar distributed", then "how do they
combine". The corner where they meet stays empty: the intersection of two marginals has no meaning.

> **The empty row between the marginal row and the matrix has to be added as its own `<tr>`** —
> the empty column falls out naturally from an HTML table, but the row does not, and without it the
> "total" band reads as an ordinary state row.
>
> **The corner cell (marginal row × marginal column) has no meaning but still takes up width.**
> Absorb it with `colspan="2"` on the marginal row's header so the "total" band starts exactly where
> the intersection block starts. Side effect: the header is now twice as wide, so `text-align: right`
> pushes the label to the edge of the doubled width — fix with an inner `<span>` of the track's fixed
> width, not a change of alignment.
>
> **Set track widths via `<colgroup>`, not `width` on cells.** Under `table-layout: fixed` the
> browser takes widths from the first row, and the spacer column — the only track with no content of
> its own — absorbs any leftover width. `<col>` plus `min-width`/`max-width` on the spacer removes
> that freedom entirely.

**The horizontal axis label is centered over the grid, not over the container.** It describes the
intersection columns, so pushed to the left it ends up over the row-name column, which it has
nothing to do with.

**Both axes are labeled — otherwise the matrix cannot be read at all.** The row and the column are
different entities here (the five-hour window versus the weekly one), and they carry identical state
names, so without labels there is no way to say which bar is where. This is not cosmetics: without
them the table turns into a grid of numbers with identical headers along both axes. The label goes
**on the axis itself**, not merely into the text under the chart — the reader is looking at the
grid, not at the caption. With a direction arrow (`7-day window →`, `5-hour window ↓`) the binding
is unambiguous.

**A cell must have a popup, and not via `title`.** The number in a cell is a share of the sample,
but it shows neither which two states met (the color blend is ambiguous) nor how many hours that
was. The native `title` is no good for this: it appears only after a one-second delay, cannot be
styled, and on a published page reads as the **absence** of a popup. What is needed is a custom
element showing both states with their swatches, the percentage, the absolute hours, and one
sentence about what the cell means. It has to be attached to `mouseenter` **and** `focus` (cells get
`tabindex="0"`), otherwise the matrix is inaccessible from the keyboard.
>
> **Positioning:** a popup above the cell covers the column headers when the cell is in the first
> row. The rule — if the computed top goes above the top of the table, show the popup **below** the
> cell; if it does not fit below, flip it back up.

**Color mixing in OKLab.** The cell fill is a blend of two severities: **the hue says which two
states met, the lightness says how long it lasted**. The marginal bands are painted in the pure
color of their state — but **saturation there encodes magnitude just as it does in the cells**: a
band at 71% and a band at 2.6%, filled equally bright, make the marginals the one place on the chart
where color carries no information, and the eye reads a weak state as equally important. Their
domain is wider than the cells' (marginals sum to 100, cells rarely exceed 40), so the ramp is their
own; a lower floor (~0.18) is needed, otherwise a band of a few percent dissolves into the card's
background. The digit's color changes along with the fill: when the fill dims below ~55%, the
surface shows through it, and white/dark text picked for a solid swatch stops being legible — below
that boundary the text is taken from the primary-ink token. The mixing has to happen in a perceptual
space: in RGB the midpoint between green and orange gives a muddy color, while in OKLab it gives a
legible intermediate. It has been verified that the pairs stay distinguishable (minimum chromatic
distance ≈ 2.6 given that numeric labels are present).

**A time-sample switch above the chart.** The three modes from the § above. Without it the chart
silently answers a question the reader never asked.

**A per-day breakdown under the matrix.** A stack of states for each day, where the **height of the
band** is how many hours of the day fell into the sample. It shows whether the observation is evenly
distributed, and keeps you from taking a day with two hours of data for a full one.

**Caveat:** it requires the "working with Claude" sample and is **not suitable for red** — that
needs the form below.

### Matrix requirements: run through the list before showing it

All eight were earned on real iterations of this chart — every one had to be fixed after the
finished matrix had already been shown to a reader. The prose above is enough to understand **why**;
this list is so you do not miss **what**.

| # | Requirement | Symptom if violated |
|---|---|---|
| 1 | **Both axes labeled** — which window is on the rows, which on the columns, with a direction arrow | A grid of numbers with identical state names on both axes; no way to say which bar is where |
| 2 | **Horizontal axis label centered over the grid**, not over the container | It ends up over the row-name column, which it has nothing to do with |
| 3 | **Marginal bands separated by a gap along both axes** — a column and a dedicated `<tr>` | The "total" band sticks to the intersections and reads as a combination that does not exist |
| 4 | **Both gaps equal to the eye**, set via `<colgroup>` | The horizontal break is several times larger; the grid reads as two tables side by side |
| 5 | **The empty corner absorbed** (`colspan` on the marginal row's header) | An empty cell the full width of the marginal column holds ~90 px of emptiness |
| 6 | **The marginal row's label on the same line as the rest** — an inner `<span>` of fixed width | After `colspan`, `text-align: right` pushes it to the edge of the doubled width |
| 7 | **Marginal bands encode magnitude by saturation**, with a lower floor and a digit-color switch | A 71% band and a 2.6% band are equally loud; the marginals are the one place where color carries no information |
| 8 | **Cells have their own popup** (not `title`), on `mouseenter` **and** `focus`, flipping below the cell near the top | The native tooltip on a published page reads as the absence of a popup; the matrix is inaccessible from the keyboard |

**A method, not a list item:** verify **by measuring geometry** (`getBoundingClientRect()` across
the cells of a row) and **in the published artifact**, not only in the local render. On this chart
four consecutive "fixes" went nowhere for exactly that reason: locally the break was correct, and
the reader was seeing a different one.

### Blocking: a timeline of events, not a share

**When:** you need to show idle time caused by an exhausted window.

**Why separately:** blocking is **an event with a duration**, not a state with a share. A two-hour
stall, dissolved into hundreds of observed hours, gives a share of 1%, and the reader concludes "it
practically never happens" — when for the person those were two hours with work at a standstill.

**Form:** a timeline of episodes (when it started, how long it lasted), or a distribution of
durations if there are many episodes. A useful extra dimension is how much time was left until the
reset at the start of the episode: it distinguishes "hit the wall 10 min before the reset" from "hit
the wall at the start of the window".

### What is not worth building

- **Pie charts** for shares — on these data they always lose to bars.
- **Dual Y axes** — never; two values of different magnitude mean two charts.
- **The curve of the ratio of two counters over time** — it is a nearly horizontal line that adds
  nothing to the number itself (verified on N).
- **Moving-average smoothing** without an explicit marker — it hides quantization and creates a
  false impression of continuity.

## Series length overturns conclusions — record what got refuted

The most expensive mistake in this work is not a computation error but **a confident conclusion from
a short series**. The journal grows, and what looked like a regime over one day turns out to be an
outlier over two weeks.

Verified in practice: the same journal was re-read three times — **1 day → 3.5 days → 11 days** —
and six conclusions flipped:

| On the short slice | After accumulation | What it actually was |
|---|---|---|
| "A 92% peak is the typical regime" | a one-off outlier, the rest of the cycles ≤ 57% | a sample of 3 events |
| "The pace exceeds what is allowed" (1.72 windows/day) | fits with 21% to spare (1.07) | a one-day spike taken for the norm |
| "The 5-hour window is the constraint" | the **week** is the constraint, the 5h ceiling does not press | there had not been a single complete 7d cycle |
| "Don't do a weekly projection" | do it — after the first completed `d7` cycle | the cone was wider than the window |
| "Incidents are visible in latency" | refuted three times | a coincidence on a small sample |
| "Transcripts are not needed" | they are, but **only the structural fields** | field types were not being distinguished |

**Practical rule:** record not only the conclusion but also **the slice it was obtained on**, and on
every re-read explicitly re-check the earlier ones. The phrasing "over 3 days it looked like this,
over 11 it looks different" is worth more than either statement on its own.

### "Not enough history" is a feature, not a placeholder

Every metric should have a **maturity threshold**, and until it is reached the app says "still
computing" rather than showing a premature number:

| Metric | Matures at | Why there |
|---|---|---|
| Coefficient N | 10–15 `d7` ticks | the weekly counter moves rarely |
| Weekly projection | ≥ 1 completed `d7` cycle | over 1 day the cone was 4.0–8.7 days — **wider than the window itself** |
| Distribution of "how far into the window I take it" | ~a week | 3 cycles do not make a distribution |
| Day profile | ≥ 5–7 days | 1 day = 1 observation per hour |
| Day × hour heatmap | ≥ 14 days | 2 rows of a grid are not a grid |
| The "1.4× your usual" baseline | ≥ 14 days | there is no distribution for "usual" yet |

> **The worst kind of widget** is the one that "looks convincing and means nothing". A projection on
> a single day is exactly that: it draws a handsome cone whose width exceeds the value it forecasts.

### Three transformations for when the series outgrows the chart

As data accumulates, the form has to change — otherwise the chart degrades:

- **event → distribution**: show 32 resets as a histogram, not a list of lollipops;
- **day → facet**: 12 daily bands of 0–24 h instead of one continuous time axis;
- **window → object**: weeks overlaid in "day since reset" coordinates — the axis stays 7-day long
  no matter how long the journal is.

The last trick is especially valuable: **overlaid cycles in normalized coordinates** ("fraction of
the window" × `util`) are not a time series, so they scale without caveats up to ~40–50 cycles on one
canvas.

## Checklist before showing a result

1. Did you deduplicate resets (rounding to the minute / to the day)?
2. Is a reset identified by **both the instant AND the drop**, not by one of the two? Is an empty
   `reset` handled as window identity rather than as a gap?
3. Are observation gaps left unjoined by a line? Are "across the hole" events marked and left
   undated?
4. Did you filter out windows with insufficient observation? Did you extrapolate the incomplete ones
   and mark them?
5. Are the histogram bins consistent with the polling step?
6. Is the session merge threshold named next to the number?
7. Are cross-user comparisons made at scales larger than the coarser polling step?
8. For the "how much time the bar spent in state X" metric — did you take the "working with Claude"
   sample rather than the whole journal? Are blocked states pulled out into a separate metric
   instead of being drowned in the shares?
9. Did you take the peak rather than the last value?
10. Was N measured from this same series rather than borrowed?
11. Was the effect checked against a null model? Does the point estimate come with a CI or a "not
    enough data" mark?
12. **Is the slice the conclusion was obtained on named explicitly?** Have earlier conclusions from
    shorter slices been re-checked?
13. Does the signal clear the [users-and-goals.md](users-and-goals.md) bar: is there an action the
    user would take differently after seeing it?
14. **Does the artifact have a section on the signal's usefulness** — what to act on, what not to
    do, and what is proposed if there is no signal? Was the question asked **before** building it,
    not after?
15. Has any constant been carried between 5h and 7d without recomputation? Are the axes of
    categorical charts built from the full domain of states rather than from the sample at hand?
16. **Has the two-dimensional matrix passed its list of eight requirements**
    ([§ "Matrix requirements"](#matrix-requirements-run-through-the-list-before-showing-it)) — axes,
    gaps, corner, labels, marginal band saturation, popups? Was it verified **by measuring
    geometry** and **in the published artifact**, not only in the local render?
17. **Is the status recomputation applied conditionally?** The current color algorithm is run over
    the data **only if the slice contains samples written by an out-of-date algorithm** — that is,
    rows whose `sevV` is lower than the model's current generation (or missing). If the whole slice
    is already migrated, `sev` is taken as-is: a redundant recomputation fixes nothing, while adding
    the risk of diverging at threshold boundaries from what the user actually saw — journal
    `util`/`timePct` are rounded on write, and the live poll computed the color before rounding.

The last item filters out the most. A statistically flawless result that changes no decision does
not make it into Insights.

## How to reproduce the measurements

All the numbers in this file come from two series: `usage-journal-2026-08.jsonl` (Max, ~5,760
`usage` records as of August 20, 2026) and a Pro series supplied by a second user (862 records,
August 4–15, 2026 — a school-holiday period, so the shape of the week in it is atypical).

**Absolute counters grow** with every poll, so a discrepancy of a few hundred records on a repeat
run is expected. Shares, medians and distribution statistics are stable; if *those* diverge, it is a
signal that either the behavior or the API itself has changed.

```sh
python3 - <<'PY'
import json, datetime

def P(t):
    """Tolerant parser: empty / malformed timestamp -> None, not an exception."""
    try:
        d = datetime.datetime.fromisoformat((t or "").replace("Z", "+00:00"))
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=datetime.timezone.utc)

rows = []
with open("usage-journal-2026-08.jsonl") as f:
    for line in f:
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get("kind") != "usage":
            continue
        h5 = o.get("h5") or {}
        t, reset = P(o.get("t")), P(h5.get("reset"))
        if t is None or h5.get("util") is None:
            continue
        rows.append((t, float(h5["util"]), reset))   # reset may be None
rows.sort(key=lambda r: r[0])

gaps = [(rows[i][0] - rows[i - 1][0]).total_seconds() / 60 for i in range(1, len(rows))]
gaps.sort()
print("samples:", len(rows))
print("median interval, min:", gaps[len(gaps) // 2])
print("share > 20 min: %.1f%%" % (100 * sum(1 for g in gaps if g > 20) / len(gaps)))
PY
```

> **Tolerant parsing is mandatory — this is not a rare case.** An empty `reset` is present in **27%
> of rows in the Max series** (1,550 out of 5,760) and **56% in the Pro series** (481 out of 862).
> The cause is windows for which the API did not return `resets_at`
> ([usage-api-quirks.md § "Every week, the API stops returning `seven_day.resets_at` for 4-6 hours"](usage-api-quirks.md#every-week-the-api-stops-returning-seven_dayresets_at-for-4-6-hours)).
> A naive `fromisoformat` blows up on them with `ValueError`, and the script breaks off mid-run —
> often after it has already printed part of the results, so the error is easy to miss.
>
> Such rows should be **skipped or kept with `reset = None`** rather than treated as corrupted:
> their `util` and `t` are perfectly usable for pace analysis, and there is no reason to throw away
> a quarter of the series. They are unusable only where grouping by window is required.
