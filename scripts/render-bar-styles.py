#!/usr/bin/env python3
"""Render the doc illustrations for docs/reference/bar-styles.md.

The geometry mirrors the shipped renderers so the pictures cannot drift from the
app by hand-editing:

  r      = (u - t) / (1 - t)            BarLayout.signedLead
  gauge  = clamp(r, -1, +1)             BarLayout.gaugeOffset
  press  = max(0, gauge)                BarLayout.pressureLength      (ADR-0101)

  scaleX / minStripWidth / the pill floor mirror PopupBarView.

Run from the repo root:  python3 scripts/render-bar-styles.py
Writes docs/assets/bar-styles/*.svg
"""
import os

OUT = os.path.join("docs", "assets", "bar-styles")

# Menu-bar metrics, in points (StatusItemView.Metrics / PopupBarView).
BAR_W, BAR_H = 34.0, 5.0
MIN_STRIP = 0.75 * BAR_H - 1          # 2.75 pt
CORNER = 1.5
TICK_W, TICK_H = 1.5, 10.0
MARKER_W, MARKER_H = 5.0, 9.0
CANVAS_H = 12.0                        # room for the zero tick above/below

SCALE = 4                              # svg is drawn at 4x for crisp rendering

# Palette — the app's pacing colours (dark menu bar rendition).
IDLE_TRACK = "#525252"
INK = {
    "blue": "#0a84ff",
    "green": "#30d158",
    "yellow": "#ffd60a",
    "orange": "#ff9f0a",
    "red": "#ff453a",
}
# calm ink (0.865) × zeroTickAlpha (0.55) ≈ 0.476. At 4× the tips read heavier
# than on a real 34 pt bar, so the illustrations use the product rather than the
# calm ink alone — same relationship the widget draws, legible at this size.
TICK_INK = "rgba(255,255,255,0.40)"


def signed_lead(t, u):
    if u >= 1 or 1 - t <= 0:
        return None
    return (u - t) / (1 - t)


def gauge_offset(t, u):
    r = signed_lead(t, u)
    return 1.0 if r is None else max(-1.0, min(1.0, r))


def pressure_length(t, u):
    return max(0.0, gauge_offset(t, u))


def scale_x(f):
    bs = MIN_STRIP / 2
    return bs + f * (BAR_W - 2 * bs)


def rect(x, y, w, h, fill, rx=None):
    r = f' rx="{rx:.2f}"' if rx is not None else ""
    return f'<rect x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}"{r} fill="{fill}"/>'


PAD = 3.0                              # menu-bar plate around the bar
PLATE = "#212121"                      # NSMenu material, dark (see CLAUDE.md)


def frame(body, w=BAR_W):
    """Wrap the bar in a menu-bar-coloured plate.

    The bars are drawn in their menu-bar rendition, so a bare SVG would put a
    dark-grey track straight onto GitHub's white page and read as broken. The
    plate is what the widget actually sits on.
    """
    tw, th = w + PAD * 2, CANVAS_H + PAD * 2
    plate = rect(0, 0, tw, th, PLATE, 2.5)
    shifted = f'<g transform="translate({PAD},{PAD})">{body}</g>'
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {tw} {th}" '
        f'width="{tw * SCALE:.0f}" height="{th * SCALE:.0f}" '
        f'role="img" shape-rendering="geometricPrecision">{plate}{shifted}</svg>'
    )


def track(y):
    return rect(0, y, BAR_W, BAR_H, IDLE_TRACK, CORNER)


def zero_tick(cx, y):
    return rect(cx - TICK_W / 2, y - (TICK_H - BAR_H) / 2, TICK_W, TICK_H, TICK_INK)


def pill_or_strip(x0, x1, colour, y):
    """The coloured ribbon, floored to the minimum pill and clipped to the track.

    `CORNER` (not half the height) is the shipped radius: the menu bar clamps to
    `Metrics.barCorner`, so a short strip is a rounded rectangle, not a capsule.
    """
    w = max(MIN_STRIP, x1 - x0)
    x0 = max(0.0, min(x0, BAR_W - w))          # never overhang the track
    r = min(CORNER, min(w, BAR_H) / 2)
    return rect(x0, y, w, BAR_H, colour, r)


def pressure_svg(t, u, colour):
    y = (CANVAS_H - BAR_H) / 2
    length = pressure_length(t, u)
    x1 = BAR_W if length >= 1.0 else scale_x(length)
    body = zero_tick(scale_x(0), y) + track(y) + pill_or_strip(0, x1, INK[colour], y)
    return frame(body)


def gauge_svg(t, u, colour):
    y = (CANVAS_H - BAR_H) / 2
    offset = gauge_offset(t, u)
    centre = scale_x(0.5)
    far = scale_x(0.5 + offset / 2)
    x0, x1 = min(centre, far), max(centre, far)
    if x1 - x0 < MIN_STRIP:
        x0, x1 = centre - MIN_STRIP / 2, centre + MIN_STRIP / 2
    body = zero_tick(centre, y) + track(y) + pill_or_strip(x0, x1, INK[colour], y)
    return frame(body)


def progress_svg(t, u, colour):
    """Progress: the gap between time and usage, plus the time marker."""
    y = (CANVAS_H - BAR_H) / 2
    lo, hi = min(t, u), max(t, u)
    x0, x1 = scale_x(lo), scale_x(hi)
    mx = scale_x(t)
    # The marker is drawn on top, unclipped, in the gap's own colour — no gutter
    # is carved for it (that trick belongs to the yellow ribbon alone). It stands
    # proud of the track, which is what makes it read as "you are here".
    body = track(y) + pill_or_strip(x0, x1, INK[colour], y)
    body += rect(mx - MARKER_W / 2, (CANVAS_H - MARKER_H) / 2, MARKER_W, MARKER_H,
                 INK[colour], CORNER)
    return frame(body)


# (filename, t%, u%, colour, which styles to draw)
SCENES = [
    ("pressure-calm", 30, 20, "green", ["pressure"]),
    ("pressure-mild-lead", 30, 38, "yellow", ["pressure"]),
    ("pressure-ahead", 93, 97, "orange", ["pressure"]),
    ("pressure-exhausted", 70, 100, "red", ["pressure"]),
    # A left ribbon needs a span wider than the min pill, or the floor collapses
    # it onto the on-pace pill and the illustration says nothing: at t=30 % a
    # 10 pp surplus is only 2.2 pt. Half the window spent at 30 % gives 6.3 pt.
    ("gauge-calm", 50, 30, "green", ["gauge"]),
    ("gauge-deep-surplus", 90, 70, "blue", ["gauge"]),
    ("gauge-on-pace", 55, 55, "green", ["gauge"]),
    ("gauge-ahead", 93, 97, "orange", ["gauge"]),
    ("progress-mid", 50, 70, "orange", ["progress"]),
    ("progress-behind", 60, 40, "green", ["progress"]),
]

RENDER = {"pressure": pressure_svg, "gauge": gauge_svg, "progress": progress_svg}


def floored(style, t, u):
    """True when the ribbon is narrower than the pill, i.e. indistinguishable
    from the zero state of that style.

    Worth checking per scene: a scene that floors renders *correctly* but
    illustrates nothing — two captions promising different things would sit
    above byte-identical pictures.
    """
    if style == "gauge":
        span = abs(scale_x(0.5 + gauge_offset(t, u) / 2) - scale_x(0.5))
    elif style == "pressure":
        span = scale_x(pressure_length(t, u))
    else:
        return False
    return span < MIN_STRIP


def main():
    os.makedirs(OUT, exist_ok=True)
    written = []
    # Scenes whose whole point IS the floored pill — everything else must not be.
    EXPECT_FLOORED = {"pressure-calm", "gauge-on-pace"}
    surprises = []

    for name, tp, up, colour, styles in SCENES:
        t, u = tp / 100, up / 100
        for style in styles:
            if floored(style, t, u) and name not in EXPECT_FLOORED:
                surprises.append(f"{name} ({style}, t={tp} u={up})")
            svg = RENDER[style](t, u, colour)
            path = os.path.join(OUT, f"{name}.svg")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(svg + "\n")
            written.append((name, tp, up,
                            f"{pressure_length(t, u) * 100:.0f}%",
                            f"{gauge_offset(t, u) * 100:+.0f}%"))
    print(f"{'file':24s} {'t':>4s} {'u':>4s} {'pressure':>9s} {'gauge':>7s}")
    for row in written:
        print(f"{row[0]:24s} {row[1]:4d} {row[2]:4d} {row[3]:>9s} {row[4]:>7s}")
    print(f"\n{len(written)} files → {OUT}/")
    if surprises:
        print("\nWARNING — these scenes collapse to the minimum pill, so they")
        print("illustrate nothing beyond the zero state:")
        for s in surprises:
            print(f"  {s}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
