---
status: superseded
date: 2026-06-22
superseded_by: [0074]
---

# ADR-0006: ResetClock — absolute `hh:mm` for distant resets, not relative time only

> **SUPERSEDED (2026-08-07, [ADR-0074](0074-one-reset-format-on-both-surfaces.md),
> [#284](https://github.com/artem-from-ua/tokenpace/issues/284)):** this ADR's central decision —
> **the 90-minute threshold and an absolute `hh:mm` in the menu bar** — is gone. The menu bar now
> formats its label with the same `relativeRounded` that produces the popup's numeric core, so one
> reset reads identically on both surfaces (`5h` in the bar, `5h at 20:40` in the popup). The wall
> clock survived **only** in the popup, as the `resetLine` qualifier. About the only thing that still
> stands in this document is the description of `parse(_:)` (the port of `parse_reset_epoch`) — read
> the rest as history.

> **Postscript (2026-07-25, [ADR-0030](0030-optimistic-reset-and-exact-timer.md)):** the `(0, 60)` s
> seconds band (`40s`/`1s`) decided here has been **removed**. The menu bar only redraws on a ~30 s
> cadence, so a per-second countdown stuttered; sub-minute now renders as `"<1m"`, and `[60 s, 90 min]`
> rounds to the nearest minute (instead of truncating down). The rest of the decision (absolute
> `hh:mm` for distant resets, the 90-minute threshold, dropping zero minutes) still stands — which is
> why the status stayed `accepted`.

> **Postscript (2026-07-27, [ADR-0043](0043-unified-reset-line-and-remove-resetnow.md), #167):** the
> `.resetNow` case (the table rows below: `≤ 0 → .resetNow`, "the View picks the glyph") has been
> **deleted** — a past reset is rolled forward before formatting, and a broken `resets_at` goes to the
> ⚠️ error state. `TimeToReset` now has only `.absolute`/`.relative`. The principle "a logic layer
> without UI glyphs, the View picks the string" still stands.

## Context

`statusline.sh` formats the time to reset with `format_time_remaining`, which **always** returns a
**relative** duration and has two branches around a `threshold_hours` (2 hours for the 5h window, 48
hours for the 7d one):

- far from the reset (`total_hours >= threshold_hours`) → coarse and approximate: `~3h`, `~7d`
  (rounding ≥30 min up to an hour, ≥12 h up to a day);
- close to it (`< threshold_hours`) → exact: `${h}h${m}m` / `${m}m` (e.g. `1h10m`, `45m`);
- reset in the past (`diff <= 0`) → the ⏰ emoji.

SPEC issue #7 ("Agent behavior — time") calls for **different** behavior in the menu bar: when the
reset is **more than 90 minutes** away, show the **absolute** local time `hh:mm` in the user's locale
(12/24-hour) and local time zone with automatic DST; when it is **90 minutes or less**, show the
relative `1h10m`. So a literal port of `format_time_remaining` is impossible here: its "far" branch
(`~Nh`/`~Nd`) contradicts the requirement to show the exact reset time.

This is the same class of decision as [ADR-0005](0005-pacing-fractions-not-blocks.md) (PacingModel
deliberately departing from a literal port of `build_progress_bar`): the port is kept where it fits
the product and replaced where it does not. The decision was agreed with Artem explicitly during the
session that implemented issue #7; the format's edge cases (zero minutes, seconds, the boundary) are
his calls too.

## Decision

`ResetClock.timeToReset(resetsAt:now:locale:timeZone:)` returns a type-safe `TimeToReset` with three
bands:

| Time left to reset | `statusline.sh` (`format_time_remaining`) | cc-timer (`ResetClock`) |
|---|---|---|
| `≤ 0` | `⏰` (hardcoded glyph) | `.resetNow` (the View picks the glyph) |
| `(0, 60)` s | — (bash rounds to `0m`) | `.relative("\(s)s")` — a **new** seconds band |
| `[60 s, 90 min]` | `${h}h${m}m` / `${m}m` | the same, but with **zero minutes dropped** (`2h`, not `2h0m`) |
| `> 90 min` | coarse `~Nh` / `~Nd` | `.absolute(hh:mm)` — the **absolute** local time |

The specific decisions (all covered by unit tests):

- **The absolute/relative threshold is a flat 90 minutes**, not the per-window `threshold_hours`
  (2 h / 48 h). One threshold for both windows is simpler and matches the SPEC.
- **The comparison is strict `>`:** exactly 90 minutes stays **relative** (`1h30m`) — near the
  threshold a live `Nh Nm` countdown is more useful than a static clock.
- **The relative format has no spaces and no zero padding**, and drops zero minutes: `1h10m`, `45m`,
  `1h` (exactly one hour → `1h`, not `1h0m`).
- **A seconds band** for `(0, 60)` s (`40s`, `1s`) — more honest than `0m` right before a reset; the
  statusline has nothing like it. The seconds↔minutes threshold is exactly 60 s (`60s → 1m`).
- **The absolute branch** is formatted through
  `DateFormatter.setLocalizedDateFormatFromTemplate("jmm")` (`j` is the locale-dependent hour cycle:
  12-hour with AM/PM, or 24-hour) with injected `locale`/`timeZone`; Foundation applies DST from the
  time zone's name.
- **`.resetNow` carries no glyph.** The logic layer stays free of UI dependencies; the ⏰ glyph is the
  View's choice (issue #10), and an out-of-band usage API poll on that signal is the polling
  coordinator's job (a separate ticket). `ResetClock` stays pure, with no network and no timers.

Parsing (`parse(_:)`) ports `parse_reset_epoch` literally in intent: strip microseconds before the
offset (like the `sed` in bash, because `ISO8601DateFormatter.withFractionalSeconds` only handles
milliseconds), then parse with the offset applied → the correct absolute instant for `+00:00` / `Z` /
non-UTC.

## Consequences

- The user sees the **exact time** of the next reset (`17:30` / `5:30 PM`) when it is far away — more
  useful than the statusline's coarse `~3h`/`~7d`.
- The format depends on locale and DST deterministically: `locale`/`timeZone` are parameters, so unit
  tests pin 12/24-hour (`en_US` vs `en_GB`/`uk_UA`) and DST transitions (`America/New_York`,
  spring-forward 2026-03-08 / fall-back 2026-11-01) without depending on the environment.
- `TimeToReset` is a discriminated enum, so `StatusItemView` (#10) maps the bands onto
  representations (`.resetNow → ⏰` among them), and the tests assert the case plus its value rather
  than a styled UI string.
- The divergence from `statusline.sh` is recorded both here and in `ResetClock`'s doc comments; future
  changes to the statusline do not oblige us to change this module, or the other way round.
- The seconds band and dropping zero minutes are extra divergences beyond the SPEC, taken
  deliberately; narrowing them back to a literal `${m}m`/`${h}h${m}m` would be easy if needed.
