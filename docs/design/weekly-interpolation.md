# Design: reconstructing the weekly `utilization` from the five-hour counter

A formal description of the algorithm implemented in [#386](https://github.com/artem-from-ua/tokenpace/issues/386).
A companion to [ADR-0103](../adr/0103-weekly-utilization-reconstructed-from-the-five-hour-counter.md): the ADR
records **what** we decided and **why**, this document records **how it is actually computed**, with the
invariants, the edge cases and the measurements the constants rest on.

> Related: [usage-api-quirks](../reference/usage-api-quirks.md) — the quantization measurement everything
> stands on; [users-and-goals § "The ratio between the windows' quotas"](../reference/users-and-goals.md) — where the
> coefficient `N` comes from.

## Problem

The API rounds `seven_day.utilization` to a whole percent. On the seven-day window one point is
**1 h 40 min** of work. Measured against a live journal (4,327 records, August):

- **96.4%** of consecutive pairs do not change at all;
- the weekly scale shows nothing for **~88%** of spending movement;
- 137 of 140 increases are exactly 1 pp.

The five-hour counter is quantized the same way, but its point is **3 min** — 33.6× finer. Both measure
the same spending. Hence the idea: read the weekly scale **through** the five-hour one.

## The quantization model

An observed integer `k` is not a value but an **interval**. The edge buckets are half as wide, because
the scale is bounded on both ends:

| observed `k` | true value | width |
|---|---|---|
| `0` | `[0, 0.5)` | 0.5 |
| `1…99` | `[k − 0.5, k + 0.5)` | 1.0 |
| `100` | `[99.5, 100]` | 0.5 |

`ceiling(100) == 100` is not a detail but the **protection for every exhaustion detector**: the
reconstruction cannot carry a value across the 100 boundary, so `CreditsPacing`, `BlockingReset`,
`MenuBarLayout` and `PacingModel.limitIndicator` stay untouched.

## Two anchors

This is the algorithm's main fork, and it is about **what we actually know**.

```
   A. Bump observed (firm)                 B. Anchor inherited (inherited)

   k−0.5        k+0.5                      k−0.5    k    k+0.5
     |============|                          |=======|=======|
     ^                                               ^
     anchor: the exact lower bound                   anchor: the bucket's center
     (we saw the k−1 → k transition,                 (t₀ is unknown, the position
      so the value has just crossed it)               in the bucket is not observable)
```

**A — bump observed.** We saw the `k−1 → k` transition between two polls ourselves. At that moment the
true value had just crossed `k − 0.5`, so that boundary is the anchor. No assumptions.

**B — anchor inherited.** First launch, or a return after a long break: `k` is known, but when it became
`k` is not. The position inside the bucket is not observable from any available signal (`h5` does not help
either — its phase within the five-hour window does not correlate with the position in the weekly bucket).
The anchor is the center.

**Why the center.** Across 4,295 samples where the moment of the bump **was** known, the distribution of
the position inside the bucket turned out to be practically uniform: a median of exactly **0.500**,
quartiles 0.20 / 0.50 / 0.70. So the center minimizes the expected error. And it is **no worse than what
we had before #386**: we used to show `k` while the truth was in `[k−0.5, k+0.5)` — the same 0.5 pp error
bound, only the value sat still.

This is the one choice that genuinely matters: replacing `k − 0.5` with `k` shifts the result by
**0.37–0.42 pp** on average — an order of magnitude more than any other component (see "What was measured"
below).

## Estimating `N`

The unit of observation is a **segment**: the span between two consecutive `d7` jumps. Within a segment we
accumulate the sum of the **positive** `h5` increments.

```
on every poll:
    if h5 ≥ h5_previous:        Δ = h5 − h5_previous          // an ordinary increment
    else if the poll is fresh:  Δ = min(h5, ceiling(gap))     // a 5h reset between polls: the new value
                                                              // is the spending after it, but no more
                                                              // than the window could have burned
    else (a gap):               Δ = 0, degraded = true        // a gap may have held more than one reset
    acc += Δ

when d7 increased:
    localN = acc / (d7 − d7_previous)
    segments.append(localN)        // a ring buffer of 15
    acc = 0;  anchor = floor(d7);  firm = true

N = segments.isEmpty ? 10.0 : median(segments)
```

**Why a drop in `h5` is capped.** The rule "it dropped on a fresh poll → the new value is the spending
after the reset" holds when the drop lands near zero — and that is what a real reset looks like (measured:
median 0, p90 2). But a drop is **not proof** of a reset: the same journal holds `49 → 42`, `67 → 21` and
`53 → 51` minutes apart — that is the server lowering the counter itself, not 42 points of spending in
three minutes. Counting them would be inventing work that never happened. So the increment is bounded by
what the five-hour window could physically have burned over the interval: almost every post-reset value
passes through untouched, and those three get trimmed to an honest few points.

**Why a median, not a mean or least squares.** Both series are quantized, so an individual segment carries
a ±0.5 pp error in the denominator — that is ±50% at a step of 1. Measured: individual `localN` values
scatter **3–24** (Max 5x) and **4–30** (Pro), the windowed mean wanders 8.4–11.7, and the **median holds
10.0 steadily** on both journals.

**Why a window, not the whole history.** A sum-over-everything is not rolling: it responds with the inertia
of the entire history, so it would take days to show a promo. A window of 15 segments forgets the old rate
after ≈25 h of active work — the scale on which the plan actually changes.

**Why a segment is used immediately, with no threshold.** A simulation against the real scatter (192
observed `localN` values): the median of even **one** segment beats the seed for any user whose rate is not
exactly 10 — 10% error against 43% (at a true `N = 7`) or 33% (at `N = 15`). The seed only wins when it
happens to be right, and that is exactly what we do not know in advance.

## The reconstruction

```
anchor  = firm ? floor(k) : centre(k)
gained  = acc / N
u       = min(anchor + gained, ceiling(k))
```

The states the computation can return:

| state | when | what we show |
|---|---|---|
| `inherited` | no bump seen yet | center + increment |
| `interpolated` | the normal mode | lower bound + increment |
| `clipped` | `anchor + gained` exceeded the ceiling | the bucket's ceiling |
| `degraded` | a gap in polling | the lower bound, never below what was already shown |

## Invariants

**1. Monotonicity — by construction, not by a check.**

```
before the bump, at raw = k:   u_before ≤ k + 0.5        (the clip)
after the bump to k+1:         u_after  = (k+1) − 0.5 = k + 0.5
                               ⟹ u_after ≥ u_before      always
```

One bucket's ceiling and the next one's floor are **the same point**, so the transition has no
discontinuity. Empirically: 0 violations across 98,599 samples from 44 cold-start points (Max 5x) and 0 on
the Pro journal.

**2. The exhaustion boundary is untouched.** `raw = 100` passes straight through unchanged. Interpolating
inside the top bucket would produce a value in `[99.5, 100)`, and every detector checks `>= 100` — meaning
a reconstructed 99.7 would **silently clear** a blocked week: no red bar, no blocking reset, no switch to
credits.

**3. Zero stays zero.** `raw = 0` → the overlay is a no-op, because several `> 0` predicates rest on it
(`PopupLayout.groupIsAboveZero` among them).

**4. An anchor out of sync → a no-op.** If the window in the snapshot no longer carries the value the
interpolator measured, the overlay is not applied. That is what makes it safe next to
`ResetClock.optimisticReset`, which can zero the weekly window locally ahead of the server.

> **The order of application matters.** The reconstruction runs **before** `optimisticReset`, not after:
> that overlay zeroes the window at the boundary, and invariant 4 would then turn the reconstruction into a
> silent no-op on exactly the boundary polls.

## Gaps in polling

Polling sleeps: 3 min active / 15 min inactive, plus system sleep. Measured: **127 gaps longer than 6 min,
14 over an hour, 5 spanning an entire five-hour window**.

The danger is specific: across a large gap `h5` could have grown **and** reset, so the "positive increments
only" rule would silently lose the spending.

**The threshold is adaptive** — derived from the *actual* interval, not from the baseline 3 min. This is
not cosmetic: on the Pro journal (a 15-minute cadence) a fixed threshold flagged **576 of 862** samples as a
gap instead of 128.

**Degradation does not stick.** A gap spoils the accumulation, not the ability to keep measuring — from the
next poll on, everything is measurable again. Latent degradation until the next bump put 33% and 63% of
samples in the `degraded` state instead of the real 2% and 15%.

**Degradation does not roll the bar back.** The fallback is the bucket's **lower bound**, not the raw `k`.
The raw `k` is the center, i.e. a claim about half a point of spending we never measured; the moment
measurement resumes with an honester lower estimate, the bar would step **down**. Measured on the real
journals: 41 such steps (Pro) and 22 (Max 5x), all on a `degraded → interpolated` transition.

## What was measured (ablation)

Nine variants with components disabled, both journals. **None violated the invariants** — 0 monotonicity
violations and 0 excursions outside the quantum everywhere. Safety is held by the **clip**, and by it alone.

| component | divergence (mean \|Δ\|, pp) | conclusion |
|---|---|---|
| ratchet | 0.000 / 0.000 | unreachable by construction — see below |
| sanity filters | 0.001 / 0.001 | protection against pathology, not accuracy |
| a seed of 5 or 20 instead of 10 | 0.000 / 0.000 | the first segment displaces it — do not tune |
| median → mean | 0.033 / 0.016 | the median is better, but not dramatically |
| `K = 5` / `K = 40` | 0.05 / 0.01 | the window of 15 is not critical |
| **an anchor of `k` instead of `k−0.5`** | **0.373 / 0.415** | an order of magnitude more than everything else |

**The ratchet is unreachable.** `N` **never** changes inside a segment — a new estimate is only added by a
bump, which closes that segment. So `anchor + acc/N` with an unchanging `anchor`, an unchanging `N` and a
non-decreasing `acc` is monotonic **arithmetically**. That is why it is not in the code; what is there
instead is `shownFloor`, which solves a different problem — keeping degradation from rolling back what has
already been shown.

## The method's limit

Not in the algorithm, but in the **step of `h5` between polls**:

| cadence | median `h5` increment | weekly step | positions per bucket |
|---|---|---|---|
| 193 s (active) | +1 pp | 0.10 pp ≈ **10 min** | ~10 |
| 900 s (inactive) | +5 pp | 0.50 pp ≈ **50 min** | **2** |

So under sparse polling the reconstruction is not "ten times better" but **twice** as good. That is no
reason to turn it off — two states beat one — but it is the number the feature should be described with.

## What is NOT reconstructed

**Scoped models** (Opus / Sonnet / Fable) have their own weekly windows but **not** their own five-hour
ones. A single `N` for them is incorrect by construction, so they stay raw. The consequence is visible to
the eye: the weekly bar creeps, the model rows jump.

**Credits** (`extra_usage`) have no quantization — the server returns fractions there (observed:
`97.9090909090909`), so there is nothing to reconstruct.

## What goes into the journal

Every `usage` line carries **both** numbers and how the second one was obtained:

```jsonc
"v": 3,
"d7": {
  "util":     88.34,          // reconstructed — what the bar drew
  "raw":      88,             // raw from the API, verbatim
  "utilSrc":  "interpolated", // inherited | interpolated | clipped | degraded
  "resetSrc": "server",       // server | limits | reconstructed | unknown (+ a -rolled suffix)
  "n":        9.8,            // the exchange rate at the moment of writing
  "reset":    "2026-08-25T07:00:00.058036+00:00",
  "timePct":  0.962089,
  "sev":      "green"
}
```

**Two source fields, not one.** `utilSrc` (called `src` before v3) describes the reconstruction of the
**percentage**, the subject of this document; `resetSrc` describes the reconstruction of the **reset date**
([ADR-0107](../adr/0107-weekly-reset-reconstructed-from-the-last-known-one.md)). The axes are orthogonal:
across 5,029 records six of the eight intersections are populated, `degraded × reconstructed` among them —
the percentage degraded because of a gap in polling while the date was invented because the API stayed
silent, two different causes on one line. A single field would have had to pick which story to tell.

`n` is written on **every poll**, not only when it changes: the log gets the changes (otherwise it is ~341
lines a day), the journal gets the series, because a series is what can be analyzed later.

The recorded `util` is **what the app acted on**, so `weeklyHasHeadroom`, `blocked`, `brokenReset` and
`blockingReset` on the same line are computed from the reconstructed snapshot too. Otherwise the journal
would describe a state that was never on screen.

The format details, the precision rule (`decimals = ceil(log10(windowSeconds))`) and the migration
procedure are in [ADR-0067 §6](../adr/0067-local-usage-journal.md).

## How to verify

- `TOKENPACE_STUB=weekly-interp` — a sequence of three acts (inherited anchor → bump → creeps up and hits
  the ceiling). The stub runs at the normal cadence, so a full run of 20 polls takes ~60 min; to skip the
  wait, hit **Refresh now** in Troubleshoot — every press advances the sequence by one poll, and all three
  acts are visible within a couple of minutes. On live data the same thing takes hours, because a `d7` bump
  happens there once per 1 h 40 min of work;
- **Troubleshoot** — the line `weekly: 80 % raw → 79.93 % est (N = 7.0, 1 sample)`: the only place where
  both numbers stand side by side on live data;
- **the journal** — the `raw` / `utilSrc` / `n` fields in every sample (see
  [ADR-0067](../adr/0067-local-usage-journal.md)).
