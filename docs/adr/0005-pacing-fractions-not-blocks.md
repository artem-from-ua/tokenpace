---
status: accepted
date: 2026-06-21
superseded_by: [0059]
---

# ADR-0005: PacingModel — zones as fractions, not discrete blocks

> **Partially superseded by [ADR-0059](0059-menu-bar-native-semantic-colours.md):** the
> "PacingState → RGB" color binding (dark_gray=236/green=71/red=167/blue=23, the statusline's
> xterm-256 palette, see "Consequences") is gone — the menu bar widget now draws with the system's
> semantic colors rather than fixed sRGB lifted from the statusline. The rest of this ADR (zones as
> fractions in [0,1] rather than discrete blocks) still stands.

## Context

`statusline.sh` draws the pacing bar in the terminal as a sequence of N discrete block characters
(`■`/`■̿`). `build_progress_bar` takes `u_pct`/`t_pct` as percentages and quantizes them into block
indices, rounding half up: `u_blocks = (u_pct * total + 50) / 100`, where `total` is 28–30 depending
on the window. `ind_pos` (4 branches) then decides which block becomes the current-time indicator.

Issue #6 ("PacingModel + unit tests") formally calls for "a 1:1 port of `build_progress_bar`", but
the macOS menu bar draws the bar as a custom `NSView` with pixel drawing (`NSBezierPath`/`NSRect`).
In that context block quantization is a **terminal rendering artifact**, not domain logic.

Two approaches were considered:

| | Blocks (literal port) | Fractions (our choice) |
|---|---|---|
| What the model returns | `u_blocks`, `t_blocks`, `ind_pos` (integers) | `usageFraction`, `timeFraction`, `pacing` (Double [0,1]) |
| Domain clarity | Mixes business logic with a rendering artifact | Pure pixel geometry |
| Rendering quality | Jumps of 1/30 (~3.3%) | Smooth, subpixel |
| Testability | Tests bound to the bar's width (30 / 28) | Tests check the real relationship between use and time |
| Future (popup) | Blocks are not needed in popup text | Can quantize via `blockIndex()` when needed |

The decision was agreed with Artem explicitly during the session that implemented issue #6.

## Decision

`PacingModel` returns **continuous fractions in [0,1]** via `BarLayout`:

- `usageFraction` — the usage fraction (clamped `utilization / 100`, no truncation — pixel rendering
  keeps the precision).
- `timeFraction` — the fraction of the window's elapsed time (ported from `calc_time_pct`, but as an
  exact `Double` rather than integer-truncated; the divergence is < 1% and does not affect the
  indicator's thresholds).
- `pacing: PacingState` — `.ahead` / `.onPaceOrBehind` (the binary color choice for the gap, an exact
  port of the `u_blocks <= t_blocks` dispatch).

The threshold logic of `get_limit_indicator` is ported **literally**: both arguments truncate to int
before comparison (`Int(max(0, x))`), and the 100 / 90 thresholds are preserved 1:1.

Block quantization survives as an **optional derivative**, `PacingModel.blockIndex(fraction:cells:)` —
it ports `(pct * total + 50) / 100` round-half-up from `build_progress_bar` — for the future popup
(#11), which may need to show positions on a grid. The menu bar bar never calls it.

## Consequences

- The bar in the menu bar moves smoothly, without 3.3% jumps.
- `StatusItemView` (#10) gets clean geometry: three zones and the indicator's position as Double
  [0,1], and maps `PacingState → RGB` (dark_gray=236, bright_green=71, bright_red=167,
  dark_blue=23).
- `get_limit_indicator` is reproduced point for point from bash (every threshold is covered by unit
  tests, including the boundary cases `99.9999 → neutral / 91 && time 90 → warning`).
- The divergence between `elapsedFraction` and `calc_time_pct` is < 1% — it does not affect any
  visible threshold; documented in `PacingModel`'s doc comments.
- `blockIndex` is there if the popup (#11) decides to show a block grid; the exact cell count is
  passed as the `cells:` argument rather than baked into the model.
