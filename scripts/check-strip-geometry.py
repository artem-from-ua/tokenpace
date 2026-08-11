#!/usr/bin/env python3
"""Check the Progress strip's start-pinning invariant over the whole (usage, time) grid.

`PopupBarView.stripRect` lives in the AppKit executable target, which SwiftPM cannot reach from
`TokenPaceKitTests`, so this mirrors its geometry and asserts the one property that broke in #323:

    the coloured strip never starts left of `gapStart = min(usage, time)`

Everything left of the strip reads as "already spent" (Progress draws a capsule over the gap, not a
fill from zero — see docs/reference/ui-state-truth.md), so colour bleeding past `gapStart` claims
spending that never happened.

This is not a zero-spend edge case. The min-width floor fires on any gap narrower than
`minStripWidth`, i.e. whenever spending tracks the clock closely, and expanding it about the centre
always drags the left edge back. `usage = 0` is only where it is loudest, because the left cap then
also lands inside the band that used to be snapped flush to `minX`.

Run: python3 scripts/check-strip-geometry.py
"""

import sys

# PopupBarView.Metrics.barHeight, and a representative popup bar width.
BAR_HEIGHT = 6.0
BAR_WIDTH = 505.0
MIN_X = 0.0

MIN_STRIP_WIDTH = 0.75 * BAR_HEIGHT      # PopupBarView.minStripWidth
INSET = MIN_STRIP_WIDTH / 2              # the `bs` reserved for the pill's caps


def scale_x(f):
    """PopupBarView.scaleX — fraction to x, inset by a cap radius on each end."""
    return MIN_X + INSET + f * (BAR_WIDTH - 2 * INSET)


def strip_rect(frm, to, pins_start):
    """PopupBarView.stripRect — returns (x0, x1) or None for a degenerate span."""
    x0, x1 = scale_x(frm), scale_x(to)
    if x1 <= x0:
        return None
    if x1 - x0 < MIN_STRIP_WIDTH:
        if pins_start:
            x1 = x0 + MIN_STRIP_WIDTH            # grow rightwards; the left edge is data
        else:
            c = (x0 + x1) / 2
            x0, x1 = c - MIN_STRIP_WIDTH / 2, c + MIN_STRIP_WIDTH / 2
    band = BAR_HEIGHT / 2
    if not pins_start and x0 - MIN_X <= band:
        x0 = MIN_X
    if MIN_X + BAR_WIDTH - x1 <= band:
        x1 = MIN_X + BAR_WIDTH
    return x0, x1


def scan(pins_start, steps=1000):
    """Count states whose strip starts left of gapStart. Returns (count, worst_pt, examples)."""
    bad, worst, examples = 0, 0.0, []
    for i in range(steps + 1):
        for j in range(steps + 1):
            usage, time = i / steps, j / steps
            gap_start, gap_end = min(usage, time), max(usage, time)
            rect = strip_rect(gap_start, gap_end, pins_start)
            if rect is None:
                continue
            x0, _ = rect
            edge = scale_x(gap_start)
            if x0 < edge - 1e-9:
                bad += 1
                overshoot = edge - x0
                worst = max(worst, overshoot)
                if len(examples) < 5 and usage > 0:
                    examples.append((usage, time, round(overshoot, 2)))
    return bad, worst, examples


def main():
    unpinned = scan(pins_start=False)
    pinned = scan(pins_start=True)

    print(f"unpinned (pre-#323): {unpinned[0]} states bleed left of gapStart, "
          f"worst {unpinned[1]:.2f} pt")
    print(f"  non-zero-usage examples (usage, time, overshoot pt): {unpinned[2]}")
    print(f"pinned   (current):  {pinned[0]} states bleed left of gapStart")

    if pinned[0] != 0:
        print("FAIL: the pinned geometry still paints left of gapStart", file=sys.stderr)
        return 1
    if unpinned[0] == 0:
        print("FAIL: the unpinned geometry no longer reproduces the bug — "
              "this check has stopped testing anything", file=sys.stderr)
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
