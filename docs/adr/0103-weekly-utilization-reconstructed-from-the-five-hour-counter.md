---
status: accepted
date: 2026-08-17
supersedes: []
superseded_by: []
---

# ADR-0103: Weekly `utilization` is reconstructed from the five-hour counter

> Refines [ADR-0102](0102-stand-by-line-for-the-seven-day-bar.md): `standByFloorSeconds` is no
> longer "deliberately unreachable." The threshold does come into play — but not the way that ADR
> predicted (not through a finer step, but because the reconstruction drives the value into a narrow
> band a whole number never lands in). Details in §Consequences.

> The algorithm's formal description lives in
> [docs/design/weekly-interpolation.md](../design/weekly-interpolation.md). This ADR records **the
> decision and why**; that document covers **exactly how it's computed**, with invariants and
> measurements.

## Context

The API rounds `seven_day.utilization` to a whole percent. On the seven-day window, one point is
**1 hour 40 minutes** of work, so the reading sits still for hours, then jumps.

Measured on a live journal (4,327 entries, August 2026):

- **96.4%** of consecutive pairs don't change at all;
- 137 of 140 increases are exactly 1 pp;
- the weekly scale doesn't show **~88%** of spend movement: 747 upward `h5` steps occurred while
  `d7` stood still.

This isn't a cosmetic flaw. The 1 pp quantum runs through the whole pacing model: it determines the
width of the pacing zone, the moment the color changes, and when thresholds fire. It's worst at the
end of the window, where the `(1 − t)` denominator amplifies the step: the same unit costs 2% of the
bar's width at mid-week and **41.5%** in the `t ≥ 90%` zone (measured on the Pro journal).

The five-hour counter is quantized the same way, but its point is **3 minutes** — 33.6 times finer.
Both measure the same spend.

## Decision

**Read the weekly scale through the five-hour one**, with a conversion coefficient `N` computed from
the user's own data.

Three pure types in Kit — `WeeklyRatio` (a rolling median estimate of `N`), `WeeklyInterpolator`
(the reconstruction itself), and `WeeklyUtilization` (the carrier for both values) — plus one
overlay on the snapshot in `App.render`, following the pattern of `ResetClock.optimisticReset`.

### The reconstruction is always on, with no toggle

This is a fix for a flaw in the source, not a matter of taste. A toggle would mean two behavior
branches forever and the question "which one is correct" — which has no answer.

Safety is held by **a clip at the bucket's ceiling**: the reconstruction can never get more than half
a quantum ahead of reality, and it never crosses the exhaustion boundary at all. An ablation across
nine variants (both journals) produced **0 monotonicity violations and 0 out-of-quantum excursions**
in every one — the invariants are held by the clip, not by any of the other details.

### `N` is estimated by a median over a rolling window, not hardcoded

`N` is a property of the **plan**, not of the app: it travels with the subscription tier, the model
mix, and Anthropic promotions. Critically: `GET /api/oauth/usage` **has no field** that would declare
this — verified, `tier` never changed once across 4,327 entries while a "+50% weekly limit" promotion
was active. So a shift in `N` is the only observable trace of a rate change.

Median, not mean or least squares: both series are quantized, so any single segment carries ±50%
error. Measured: individual `localN` values are scattered **3–24**, the mean wanders 8.4–11.7, the
median holds steady at **10.0** on both journals.

**The seed `N = 10` is measured, not guessed**: the median came out exactly 10.0 on both Max 5x and
Pro, meaning plans scale both windows proportionally. But the seed is displaced by the **very first**
segment: a simulation against the real spread showed even one measurement beats the seed for any rate
other than exactly 10 (10% error versus 43% at `N = 7`).

### The anchor depends on what we actually know

- **a bump was observed** → anchor at the bucket's **exact lower bound** (`k − 0.5`): we saw the
  transition, so the value just crossed it;
- **the anchor was inherited** (first launch, a long gap) → **the bucket's center**: the position
  inside it isn't observable, and across 4,295 samples with a known `t₀` it's uniformly distributed
  (median 0.500).

This is the one choice that actually matters: `k` instead of `k − 0.5` shifts the result by
**0.37–0.42 pp** — an order of magnitude more than any other component.

### State survives a restart, but accumulation doesn't

The `N` window fills over ~20 hours of active work, so in-memory state would leave the feature cold
most of the time. It's persisted as a Codable blob in `UserDefaults`, following the pattern of
`episodeSubscription`.

After a long gap, **`N` is kept** (the rate doesn't degrade from idle time), while **accumulation
resets to zero** (it's tied to a bucket `h5` left long ago).

## Alternatives considered

**Hardcode `N = 10`.** Promotions and plan tiers shift the rate, and the API says nothing about it —
the reconstruction would then silently lie exactly when the limits changed.

**A threshold: "turn on after N segments."** Measured: the always-on scheme produced *fewer* clips
(4.5% versus 7.2%) and cost nothing beyond up to 20 hours of cold start after each app launch.

**A ratchet (`max` against the previous value).** Turned out to be **unreachable by construction**:
`N` never changes within a segment, because a new estimate is only added by the bump that closes the
segment. So the expression is monotonic arithmetically. What exists instead is `shownFloor`, which
solves a different problem — not letting a degradation roll back what's already been shown.

**Store `elapsed` in seconds instead of a fraction.** Would give 1 s precision with no rounding rule
at all, but `timePct` is dimensionless: a reader multiplies by 100 and doesn't need to know the
window's length — which matters for `scoped` rows that borrow the seven-day scale.

## Consequences

**Most points of the issue fix themselves.** `signedLead`, `pressureLength`, `gaugeOffset`,
`severity`, `PacingBucket.of` — **zero code changes**: they read `usageFraction`, which is now
continuous. The doc comment's promise of continuity (`PacingModel.swift`) starts being true.

**No constant moves.** `aheadThreshold`, `behindThreshold`, the three 20-minute overrides,
`standByFloorSeconds` — all stay. The yellow state near the end of the window comes back to life on
its own.

**`standByFloorSeconds` does come into play — but not for the reason ADR-0102 anticipated.** That ADR
expected the step to become ~10 minutes and the threshold to start catching real values. What
actually happens is different: `standBy` and the time to reset grow **together**, so the 20-minute
end-of-window override eats every frame with a small lead. Scanning the whole `(u, reset)` space
finds a suppressed stand-by in **18 of 10,064** combinations — all at `u` within **99.15–99.40%**,
exactly where a whole number never lands but the in-bucket reconstruction does. The `standby-floor`
stub is rebuilt around a whole `utilization = 99` accordingly.

**Text percentages don't change.** The popup's formatter rounds to a whole number, so "80%" stays
"80%" — the bar, the color, and the verdict move; the number doesn't. There's no false precision in
the text.

**Scoped models stay raw.** Opus / Sonnet / Fable have their own weekly windows but no five-hour
windows of their own, so a single `N` doesn't fit them by construction. The visible effect: the
weekly bar crawls while the model rows jump.

**The gain is proportional to the polling cadence, not the plan.** The median `h5` gain per poll:
+1 pp at 193 s → a weekly step of ≈10 min (~10 positions per bucket); +5 pp at 900 s → ≈50 min
(**2** positions). At a sparse polling cadence, that's "twice as good," not "ten times as good" — and
that's how the feature should be described.

**The journal will get both values** (`raw`, `src`, `n`) — as a separate step, together with a format
version bump.
