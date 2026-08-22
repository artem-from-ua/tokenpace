# Claude usage API quirks

Measured properties of `GET /api/oauth/usage` that affect what the app can and can't show. Not
guesses, not Anthropic's documentation — measurements taken from live responses and from our own
journal.

> Related: [ADR-0103](../adr/0103-weekly-utilization-reconstructed-from-the-five-hour-counter.md) —
> the **decision** to work around 7d quantization, and
> [design/weekly-interpolation.md](../design/weekly-interpolation.md) — **exactly how** it's computed;
> [ADR-0067](../adr/0067-local-usage-journal.md) — the journal the statistics are drawn from;
> [ADR-0008](../adr/0008-usageclient-pure-backoff-and-transport-seam.md) — the transport;
> [architecture/data-flow.md](architecture/data-flow.md) — where these values flow next.

## Token windows' `utilization` is quantized to a whole percent

**The server returns `utilization` for `five_hour` and `seven_day` rounded to an integer.** This
isn't error within ±1 pp — the value is exact, but it has a **step of 1 percentage point**, and no
intermediate states exist.

### Evidence

| Source | Volume | Result |
|---|---|---|
| `usage-journal-2026-08.jsonl` | 6,204 records | 80 unique `util` values, **none fractional** |
| Saved live responses (5) | 8 window measurements | `18.0`, `72.0`, `16.0`, `66.0`, `22.0`, `67.0`, `21.0` — all whole numbers |

The rounding happens **on the server, not on our side**: in that same journal record, the neighboring
fields keep full precision —

```json
{"gap": 8.20887208101216, "timePct": 0.9620887208101216, "util": 88, "sev": "green"}
```

`gap` and `timePct` carry 15 digits; `util` is exactly `88`. If the journal were doing the rounding,
there wouldn't be fractions sitting right next to it.

### The server can return fractions — just not for these windows

In those same responses, `extra_usage.utilization` comes back as `71.8` and even
`97.9090909090909`. So the `Double` type on ``UsageWindow/utilization`` isn't decorative, and the
field itself **has no quantization built in**. The limitation applies specifically to the token
windows.

## How much one step costs — and why 5h and 7d aren't comparable

A step of 1 pp is `windowDurationSeconds / 100` of real work:

| Window | Length | Step of 1 pp |
|---|---|---|
| `five_hour` | 5 h | **3 min** |
| `seven_day` | 7 days | **1 h 40 min** |

The ratio is **33.6x**. The same "one-percent error" is invisible on the five-hour window, but on
the seven-day one it hides nearly two hours of work.

### Measured consequence: 7d sits still, then jumps

Across 3,983 consecutive pairs of seven-day-window records:

- **96.4%** — `util` **didn't change at all**;
- it rose 140 times, of which **137 were exactly 1 pp** (3 times, 2 pp).

So the weekly figure sits still for hours, then jumps by 1 h 40 min of work all at once. **The field
itself carries no smooth motion** — that has to be reconstructed from another counter (below).

## Workaround: weekly pace is reconstructed from the five-hour counter

> Implemented for every consumer. The decision is
> [ADR-0103](../adr/0103-weekly-utilization-reconstructed-from-the-five-hour-counter.md); the
> algorithm is [design/weekly-interpolation.md](../design/weekly-interpolation.md).

7d quantization isn't insurmountable. `h5_util` has a step of **3 min** instead of 101 min, and both
counters measure the same spend — so the weekly scale can be read **through the five-hour one**.

**How much better depends on the polling cadence, not on the plan.** At an active poll cadence
(193 s), `h5` grows ≈1 pp per poll, which gives a weekly step of ≈10 min — a tenfold improvement. At
a sparse cadence (900 s), the growth is ≈5 pp and the step is ≈50 min — only a twofold improvement.
The feature should be described by its lower bound.

The conversion factor is already documented as
**N ≈ 9.8** (see [users-and-goals § "The ratio between the windows' quotas"](users-and-goals.md#the-ratio-between-the-windows-quotas-n--computed-not-hardcoded)):
how many points of the five-hour scale correspond to one point of the weekly one.

**Independent check on the August journal** (a different series, a different method — sum of
positive increments instead of least squares): `h5` grew by 1,396 pp against `d7`'s 143 pp →
**N = 9.76**. Agreement with 9.8 to the second decimal place means the ratio is real, not an artifact
of a single measurement.

| Path | Weekly-scale step |
|---|---|
| directly from `d7_util` | 1 pp = **101 min** of work |
| via `h5_util` / N, active polling (193 s) | ≈**10 min** |
| via `h5_util` / N, sparse polling (900 s) | ≈**50 min** |

In the app, `N` isn't hardcoded — `WeeklyRatio` estimates it as a median over a sliding window of the
user's own series, since it's a property of the plan and any active promotions
([ADR-0103](../adr/0103-weekly-utilization-reconstructed-from-the-five-hour-counter.md)).

### How much motion the weekly scale hides

Across 3,986 August records:

- **747** upward steps of `h5_util` happened while `d7_util` **stayed motionless**;
- only **106** steps are visible to both counters.

That means **~88% of spend motion the weekly scale doesn't show at all**. The median run of `d7`
staying still is 16 consecutive records; the maximum is 366.

### Caveats without which the reconstruction lies

- **`h5_util` isn't cumulative** — it resets on each of ~33.6 resets per week. Only **positive
  increments** can be taken; a drop means a reset, not quota returning.
- **N is a property of the plan, not a constant.** It depends on the plan tier, the model mix, and
  any active Anthropic promotions, so it's computed **from the user's own series** rather than
  hardcoded (`WeeklyRatio`, median over a sliding window). Promotions carry no field of their own in
  the payload: `tier` didn't change across all 4,327 records while the "+50% weekly limit" promotion
  was active — so a shift in `N` is the **only** observable trace of it, and that's what
  [#389](https://github.com/artem-from-ua/tokenpace/issues/389) rests on.
- **History is required.** N is derived from accumulated sums; on a cold start there aren't enough
  ticks yet, so until accumulation happens the app returns the raw value instead of noise.
- **This is an estimate, not a measurement.** Accuracy is bounded by N's confidence interval
  (8.9–10.8) and the bucket width, so derived quantities aren't presented as accurate to the minute —
  they're accurate to ~10%.
- **Scoped models break a single N** — Opus / Sonnet / Fable have their own weekly windows but no
  five-hour ones, so the reconstruction **doesn't apply** to them at all.

## What this means for the UI

> The app hands the UI the **reconstructed** weekly value
> ([ADR-0103](../adr/0103-weekly-utilization-reconstructed-from-the-five-hour-counter.md), algorithm
> in [design/weekly-interpolation.md](../design/weekly-interpolation.md)), so the constraints below
> split into two states: what's true for the **raw** `util`, and what changed after reconstruction.

### Still true after reconstruction

- **Don't promise precision the data doesn't have.** The reconstruction places the value **inside the
  bucket**, which is 1 pp wide — it doesn't add measurements, it distributes a known increment. The
  error is bounded by the bucket width and N's confidence interval, so anything derived from the
  weekly `util` remains an **estimate**.
- **The gain is proportional to the polling cadence, not the plan.** At an active poll cadence
  (193 s) the weekly step is ≈10 min; at a sparse one (900 s) it's ≈50 min — "twice as good," not
  "ten times as good." That's exactly how the feature should be described
  ([ADR-0103](../adr/0103-weekly-utilization-reconstructed-from-the-five-hour-counter.md)).
- **The step is a property of the *chosen source*, not of the quantity itself.** This is the main
  lesson and it hasn't aged: "a threshold smaller than the step" diagnoses not a nonsensical
  threshold but a counter that's too coarse. Before removing a threshold as dead, check whether the
  source needs sharpening instead.
- **The five-hour window has almost none of these constraints.** At 3 min, its step is finer than any
  threshold we work with, so quantization can be ignored there.
- **Scoped models (Opus / Sonnet / Fable) remain raw** — they have their own weekly windows but
  **not** five-hour ones, so a single `N` is incorrect for them by construction. The consequence is
  visible: the weekly bar creeps while the model rows jump. A deliberate decision, not an oversight.

### Applies only to the raw `util`

- **Fine-grained 7d states were unreachable.** On the raw value, the smallest nonzero lead was the
  same 1 pp, i.e. 101 min, and a state like "15 minutes ahead" **didn't exist**. After
  reconstruction, the value lands inside the bucket, so such states **are** reachable — which is
  exactly why the [`standby-floor`](../guides/ui-verification.md) stub was rebuilt from a fractional
  `99.5536%` to the **integer `utilization = 99`** that the server actually returns.
- **Thresholds smaller than the step were catching nothing.** True for the raw value:
  `standByFloorSeconds` (20 min) could never fire, because every value was either 0 or ≥ 101 min. The
  threshold is now **alive** — but only barely: scanning the `(u, reset)` space finds the stand-by
  suppressed in **18 of 10,064** combinations, all with `u` between 99.15% and 99.40%.

  The cause isn't what [ADR-0102](../adr/0102-stand-by-line-for-the-seven-day-bar.md) anticipated
  ("the step will become ~10 min"): `standBy` and the time to reset grow **together**, so the
  20-minute `pacingOrangeOverrideSeconds` eats every frame with a small lead, and only this narrow
  band survives.

## Every week, the API stops returning `seven_day.resets_at` for 4-6 hours

At the moment of the weekly reset, **both** date sources vanish at once: the object itself comes back
`null`, and the `weekly_all` entry in `limits[]` also has no `resets_at` of its own. This state holds
until the first token spend materializes a new five-hour session — meaning the server appears to
create the weekly window **lazily**, on the same principle as the five-hour one
([ADR-0027](../adr/0027-session-idle-no-phantom-reset.md)).

The payload during the blackout (the shape reproduced in the `weekly-reset-blackout` /
`weekly-reset-unknown` stubs):

```jsonc
{"five_hour": {"utilization": 0.0, "resets_at": null},
 "seven_day": null,
 "limits": [{"kind": "weekly_all", "percent": 0, "severity": "normal",
             "scope": null, "is_active": true}]}   // ← no resets_at
```

Measurements from two independent journals (August 2026):

| Series | `d7` records | Episodes | Duration | Share of records |
|---|---:|---:|---|---:|
| Max 5x | 5,029 | 3 | 264, 253, 306 min | 4.0% |
| Pro | 862 | 2 | 611, 54 min | 6.5% |

### The reset grid is stable, but **different across plans**

| Series | Day of week | Time | Intervals |
|---|---|---|---|
| Max 5x | Tuesday | 07:00:00 UTC (±1 s jitter) | exactly 7 days |
| Pro | Wednesday | 21:00:00 UTC (±1 s jitter) | exactly 7 days |

This regularity is exactly what makes reconstruction possible: "last real reset + N weeks"
reproduces the same grid to within **±0.25 s** (measured across all five episodes in both series).
But the grid **can't be hardcoded** — it's a property of the plan, and guessing the day of the week
would break on Pro.

> ⚠️ The grid isn't immutable: [#389](https://github.com/artem-from-ua/tokenpace/issues/389)
> documents `resets_at` shifting **backward** (−10.33 h and −1.00 h in the Pro series). Anchor-based
> reconstruction survives this — the very next real reset overwrites it — but the forecast for the
> next blackout will be wrong by the amount of the shift.

### The 10-minute grid in the data is **ours**, not the server's

The easiest trap when reading the journal. A genuine `resets_at` **always** has fractional seconds
(`06:59:59.764448+00:00`); values that land exactly on a 10-minute boundary with no fractional part
are the old local fallback `ResetClock.nextReset` (`now + 7d`, rounded up by `ceilTo10Minutes`).

This distinction is a reliable signal: across 5,029 + 862 records, there's no overlap at all. But it
has to be checked against the **raw line**: `ResetClock.parse` discards the fractional part, so after
parsing, a genuine reset looks synthesized. The drift was never server-side; after
[ADR-0107](../adr/0107-weekly-reset-reconstructed-from-the-last-known-one.md) the local fallback that
produced it is gone.

## How to re-verify

The journal accumulates on its own, so the measurements are reproducible:

```sh
python3 - <<'PY'
import json, collections
p = '~/Library/Application Support/com.artem-n.tokenpace/usage-journal-2026-08.jsonl'
import os; p = os.path.expanduser(p)
vals, prev, same, jumps = collections.Counter(), None, 0, []
for line in open(p):
    line = line.strip()
    if not line: continue
    w = json.loads(line).get('d7')
    if not isinstance(w, dict) or 'util' not in w: continue
    v = w['util']; vals[v] += 1
    if prev is not None:
        if v == prev: same += 1
        elif v > prev: jumps.append(v - prev)
    prev = v
print('non-integer:', [v for v in vals if v != int(v)])
print('unchanged:', same, 'jumps:', collections.Counter(jumps))
PY
```

Raw responses live outside the repository (`~/.tokenpace-usage-payloads/`) — they contain private
data and never make it into git.
