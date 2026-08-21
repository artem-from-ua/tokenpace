---
status: accepted
date: 2026-08-07
supersedes: [0006]
---

# ADR-0074: One "time to reset" format on both surfaces — the 90-minute threshold is gone

## Context

The menu bar and the popup answered the same question — "when does this window reset" — with two
different rules.

The popup was already unified in [#167](https://github.com/artem-from-ua/tokenpace/issues/167)
([ADR-0043](0043-unified-reset-line-and-remove-resetnow.md)): `ResetClock.resetLine` **always** leads
with a number from `relativeRounded` and only adds a distance-dependent qualifier — `15d`, `5d on
Friday`, `20h at 03:00`. The number is always there; only the tail changes.

The menu bar kept its own fork, adopted in [ADR-0006](0006-reset-time-absolute-vs-relative.md):
`ResetClock.timeToReset` switched formats at a **90-minute** threshold — beyond it → the wall clock
`20:40`, closer than it → `1h29m`. So the same reset, in the same minute, read as `20:40` in the bar
and `5h at 20:40` in the popup.

Spotted by [@kintecus](https://github.com/kintecus) in his 2026-08-04 menu bar review (§6 "One time
rule, keyed to cadence," invariant C4). The diagnosis is right; his proposed fix is not the one taken
(see "Alternatives considered").

### The threshold's cost — not just inconsistency

The menu bar's width is measured with the same font the label is drawn in
(`monospacedDigitSystemFont(ofSize: 11)`, [users-and-goals.md](../reference/users-and-goals.md)):

| State | Before | After |
|---|---|---|
| **Widest label anywhere** | **37.2 pt** (`1h29m`) | **23.6 pt** (`10m`) |
| Reset in 4 h 41 m | `20:40` · 31.3 pt | `5h` · 13 pt |
| 89 min — just under the threshold | `1h29m` · 37.2 pt | `1h` · 13 pt |
| 91 min — just over it | `20:40` · 31.3 pt | `2h` · 13 pt |
| 45 min · 20 min | `45m` · 23 pt | `45m` · 23 pt — unchanged |

**The widest state shrinks by 13.6 pt, and nothing gets wider.**

Separately — **a width jump**: the sequence `1h29m` (37.2 pt) → `1h30m` (37.2 pt) → `20:40` (31.3 pt)
shifted the widget by ~6 pt as the reset approached. This is exactly the "reset label format band"
that already sat as the last row in the jitter-source table in
[ADR-0073](0073-awaiting-icon-reserved-slot-and-slide.md)
([#283](https://github.com/artem-from-ua/tokenpace/issues/283)) — only there it was judged
low-frequency and left alone. With no threshold, the format never changes at all, so the source
disappears rather than being merely softened.

## Decision

**The menu bar formats its label with the same `relativeRounded` that produces the popup's numeric
core.** The 90-minute threshold and the wall clock in the bar are gone
([#284](https://github.com/artem-from-ua/tokenpace/issues/284)).

Consequences in code, all deliberate:

- **`enum TimeToReset` is removed; the label is a plain `String`.** There are no longer two formats
  to distinguish between: the only `switch` over it (`StatusItemView.resetText`) returned identically
  from both branches, and the case never affected color, position, or width. A two-case type would
  have documented a fork that no longer exists. The removal leaves no external trace —
  `TimeToReset` was never serialized, logged, or persisted anywhere.
- **`timeToResetCompactDays` merged into `timeToReset`.** Compact days
  ([#100](https://github.com/artem-from-ua/tokenpace/issues/100),
  [ADR-0027](0027-session-idle-no-phantom-reset.md)) existed **only** because `timeToReset` switched to
  the clock past 90 minutes, and `20:40` for a reset several days out reads as nonsense. With the
  threshold gone, `timeToReset` **became** `relativeRounded` — exactly what the compact variant already
  did. Verified empirically over the 22–26 h range: the `≥ 24 h` branch added nothing,
  `relativeRounded` already produces `Nd` on its own.
- **`relativeString` (the combined `1h29m`) was deleted** — nothing calls it anymore.
- **`absoluteString` stays alive:** `resetLine` still calls it for the popup's `at 03:00`. Only the
  menu bar's path to it went dead.
- **The `locale`/`timeZone` parameters were removed** from `timeToReset` / `resetDisplay` /
  `MenuBarLayout.selectReset`: a bare duration is locale-invariant, and they were only needed by the
  now-deleted clock branch.

### What this costs the user

- **The bar loses its tie to the wall clock.** At 4 hours out, `5h` no longer says the reset lands at
  20:40. Two things soften this: the clock survives in the popup one click away (`5h at 20:40`), where
  there is room for it; and `20:40` in the bar was already **incomplete** — it never said *which day*.
- **Minutes disappear in the 50–90 min band:** `1h29m` → `1h`. Accepted deliberately: below 50
  minutes `relativeRounded` returns to minutes on its own (`49m`, `45m`), so precision is present
  exactly where it matters — the last hour before the reset.

## Consequences

- **Invariant C4 holds:** one reset instant produces the same number on both surfaces in the same
  minute; the popup differs only by its added qualifier. Locked in by a test,
  `menuBarAgreesWithPopupNumber`, which runs both functions across every band.
- **The format never changes shape** anywhere in the 1 min – 7 d range; only the unit changes (`m` →
  `h` → `d`). The width jump at the format boundary is gone along with the boundary.
- **DST and 12/24-hour coverage is preserved, but moved.** The cases from the deleted
  `timeToReset.absolute` suite (`en_US` meridiem, `en_GB`, `uk_UA`, both sides of the
  `America/New_York` 2026-03-08 transition) were moved into `ResetLineClockTests` — they now exercise
  the live `absoluteString` through the popup. This is the project's **only** DST coverage, so
  deleting them along with the suite would have been a silent loss;
  `ResetLineTests.clockRespectsLocaleHourCycle` does not replace them, since it only asserts "gb ≠ us,"
  not a specific hour.
- **A risk the automated tests do not catch:** the project has no menu bar width tests (`Tests/`
  covers `TokenPaceKit` only; `StatusItemView` is untested). A width regression is only visible on a
  screenshot of the real bar — which is why the `mid-band-reset` stub was added for the 90 min – 24 h
  band, which until now had no way to be checked live.

## Alternatives considered

**§6 of the review — three rules keyed to window type** (a duration for 5h, weekday + time for 7d,
days for credits). Rejected:

- **`Wed 23:00` — 57.8 pt**, the widest of the measured options, and it would have landed exactly on
  7d. 20 minutes before the weekly reset it would show a day of the week instead of `20m` — exactly the
  mental arithmetic the review argues against elsewhere.
- **Credits lose the clock in the final day:** `1d left` does not distinguish "tomorrow morning" from
  "in 40 minutes."
- **It reintroduces C4 along a different axis:** 12 hours before a reset, the three windows would
  print three different shapes for the same distance.

**Remove only the clock branch, keeping `1h29m`.** Fails to reach the invariant exactly where the
least time is left (bar `1h29m` versus popup `1h at 20:40`), and buys no width win — the maximum
stays at 37.2 pt.

**Keep `TimeToReset` with a single case.** A halfway form: effectively the same `String` in a wrapper.
Since the tests had to be rewritten anyway, the diff savings vanished.

See also: [#284](https://github.com/artem-from-ua/tokenpace/issues/284) (this ticket),
[ADR-0006](0006-reset-time-absolute-vs-relative.md) (the decision this supersedes),
[ADR-0043](0043-unified-reset-line-and-remove-resetnow.md) (popup unification, #167),
[ADR-0027](0027-session-idle-no-phantom-reset.md) (compact days, #100),
[ADR-0073](0073-awaiting-icon-reserved-slot-and-slide.md) (width jitter sources, #283).
