---
status: accepted
date: 2026-08-14
supersedes: []
superseded_by: []
---

# ADR-0097: The bar style preview is rendered at runtime, not shipped as snapshots

> **Postscript ([#381](https://github.com/artem-from-ua/cc-timer/issues/381)) — decision
> confirmed.** §1 ("the reference frame is fixed, not a mirror of settings") passed the test of a
> release in which the `Colors tell me` row became conditional: the tiles **do not** react to it —
> neither to the chosen value nor to the fact that the row goes inactive under Pressure. A tile
> shows the **anatomy of a style**, not the current palette, so a single picture stays valid for
> comparison across every settings state. §3 (`blueAllowed: false` is set explicitly) becomes even
> more necessary as a result — it is now the only input that keeps the specimen's color independent
> of the live model.

## Context

The **Settings → Menu bar → Bar style** row is chosen via three picture tiles
([ADR-0093](0093-bar-style-picked-by-picture.md)). The pictures themselves were static PNGs —
snapshots of the real widget taken with `screencapture` in windowed mode and dropped into the
resource bundle.

ADR-0093 §1 chose this **deliberately as an interim step** and named its cost right there: PNGs
freeze geometry and palette, so "a change to `Metrics.barWidth`/`barHeight`/`barGap` or the pacing
colors will make them lie with no signal from the compiler." The mitigation was a doc comment
listing the constants the snapshots depend on.

**The mitigation did not work, and the bill came due faster than anyone expected.**
[#371](https://github.com/artem-from-ua/tokenpace/pull/371) gave the Pressure style a static zero
tick, and [#372](https://github.com/artem-from-ua/tokenpace/pull/372) widened it to 1.5 pt. The
snapshots in the repository were taken **before** both. In other words, the Pressure tile
**advertised a bar the app no longer draws, for two releases in a row** — exactly the silent defect
ADR-0093 described as hypothetical. No test, no build check, and no review caught it: a picture has
no way to loudly diverge from the code.

The second, independent cost of the snapshots was the resource bundle itself. It caused the 0.94.0
crash on an installed `.app` ([ADR-0095](0095-own-resource-bundle-lookup.md)): `Bundle.module`
looked for resources in the wrong place and called `fatalError` the first time the panel opened.

## Decision

**The tiles are rendered at runtime by the widget's own drawing code** — `BarStylePreviewRenderer`
builds a `StatusItemView`, feeds it a synthetic `MenuBarLayout` and `barStyle`, and takes a
`snapshotImage()`. This is the same `render(in:)` that draws the menu bar, so a tile and the bar
**cannot** diverge by construction.

The seam ADR-0093 left behind turned out to be sufficient: `render(in:)` did not need moving "into
a portable context," `Metrics` stayed `private`, and `snapshotImage()` was already public and
already shared the drawing code with `draw(_:)`. The entire change on the picker's side is swapping
one property.

### 1. The reference frame is fixed, not a mirror of settings

The tiles show **one unchanging frame** — the same one regardless of `Calm non-critical colors` and
`Hide 5h (top) bar`. Mirroring the current settings and live data was considered and rejected:

- **Mirroring settings** — then two unrelated toggles would move the picture in all three tiles at
  once, and the picker would stop answering its single question. The tiles must differ **only in
  style**, or the comparison isn't fair.
- **Mirroring live data** — in the calm state all three tiles are nearly empty, and idle is drawn
  identically across styles ([ADR-0078](0078-idle-drawn-as-zero-in-both-styles.md)), so the picker
  would stop distinguishing the variants at exactly the moment someone is looking at it.

The frame is the first poll of the `climbing` stub — the same one the earlier PNGs were captured
from: the 5-hour window at 20% over 60% of the window's time, the 7-day window at 55% over 28.6%.
This is deliberate: the transition should be invisible everywhere **except** where the snapshots had
already gone stale — otherwise the change would be impossible to review. The geometry was checked
pixel by pixel: an orange 7d strip at 34 px @2x and a green 5h pill at 6 px — matching in both.

**The zero-length 5h in Pressure is meaningful, not a defect.** In this frame `r = −1`, so the strip
clips to zero and draws as a bare minimum pill. That is exactly what the style demonstrates:
Pressure spends its entire width on the lead side and says nothing about headroom. Progress on the
same numbers draws a gap in the middle of the bar with a marker; Gauge fills the entire left half.
Three shapes from one set of numbers — and the difference between the scales is visible without a
word.

### 2. Baked under `.vibrantDark` — always

Not under the current theme, and not under `.darkAqua`.

**Dark** — because the tile's backing plate is black in both themes (see §4), and the menu bar stays
dark even in light mode. Light neutrals on a black backing would give near-black ticks on a
near-black background.

**Vibrant** — because the menu bar is a vibrant surface, and system colors resolve differently
there. Measured: `labelColor` has α 0.847 under DarkAqua versus 0.898 under VibrantDark, `systemGreen`
is `32D74B` versus `3CE155`. The project already paid for this lesson once: `PreviewChromeViews`
forces vibrancy in the dropdown preview for exactly this reason — "without forcing vibrancy, the
neutrals in the preview read noticeably lighter than the live menu, and that's the one thing a
preview must never do" ([ADR-0083](0083-live-dropdown-preview-in-settings.md)).

Drawing must happen **inside** `performAsCurrentDrawingAppearance`: `snapshotImage()` renders eagerly
for exactly this reason — so every semantic color bakes under the intended appearance, not whichever
one happens to be active later.

**For the dropdown this will be different.** Its preview (a separate PR) does not sit on black and
changes theme dynamically, so copying this file's hardcoded `.vibrantDark` there would be wrong. The
two surfaces deliberately follow different rules — this is not an overlooked asymmetry.

### 3. `blueAllowed: false` is set explicitly

Not tuning toward a desired color, but what the app actually computes for this frame:
`PacingModel.weeklyHasHeadroom` closes the blue gate while the weekly window is running ahead of
pace — and here it is ahead (55% versus 28.6%).

Being explicit removes a real fragility. The 5h surplus is `0.60 − 0.20 = 0.40`, and
`behindThreshold` for the 5-hour window is `3600/18000 = 0.40` too. The comparison is strict (`>`),
and in double the difference comes out to −5.5e−17: the color would be decided by a seventeenth-digit
rounding error. The `if !blueAllowed { return .calm }` branch sits **first** in `severity`, so green
becomes deterministic, not lucky.

### 4. The black backing plate stays, but for a different reason

ADR-0093 §2 justified the black background as a hedge against the shadow from windowed
`screencapture` (α ≤ 24), which on a light surface would have produced a gray halo. **The snapshots
are gone, the shadow is gone — and the plate stays**, now load-bearing for a different reason:

`.lighten` is compared against whatever sits underneath it, and the live render has an **alpha
channel**. Over a transparent pixel, the blend would emit `pressGrey` directly and flood the tile
with solid gray. An opaque plate flattens the render **before** the blend sees anything — and that
is exactly what keeps Press as a floor over black rather than a wash over everything. Verified with
a compiled compositing probe: over the plate, an opaque image and an alpha image give a **bit-for-bit
identical** result.

So removing the plate isn't simplifying the tile — it's breaking the click feedback. This is written
into the code right next to it, because the argument isn't obvious and invites "simplification."

A side effect required one more step down in gray: 0.16 → **0.12**. The specimen is smaller than the
snapshot it replaced (38×22 pt versus 54×33), so the bare-plate fraction of the tile grew — and the
same gray value came to cover more area and read louder, even though the value itself didn't change.

### 5. The resource bundle is removed entirely

There is no PNG fallback: the renderer never reads from disk, so it has no realistic failure path,
and a dead fallback would go stale silently, the same way the snapshots did. Gone along with the
PNGs are `resources:` in `Package.swift`, the bundle-copy step in `scripts/build-app.sh` with its
"at least three PNGs" check, and `BarStylePicker`'s own `resourceBundle` resolver.

## Consequences

**The whole class of bugs from ADR-0095 is gone along with the bundle.** The app no longer has any
resources, so `Bundle.module` has nowhere to misfire. That same rule still stands for future
resources — it has been rewritten as a conditional in
[conventions.md](../reference/conventions.md), because the next resource will step on the same mine.

**The compile-time guard is lost.** `resourceName(for:)` was a `switch` with no `default`: a fourth
`BarStyle` would fail to compile until it got a picture. The renderer draws any case, so that net is
gone. This is an acceptable trade — a new case will have to learn to draw in `StatusItemView` anyway,
and it will show up louder there — but the loss is deliberate, not overlooked.

**The tile doesn't show vibrancy's "breathing."** `Palette.unusedGrey` is `labelColor` at 22% alpha,
and on the real bar the wallpaper breathes through the track. Over the flat black plate it comes out
exactly `0x38`. The preview honestly shows geometry and palette, but not transparency — there's
nothing for it to reflect on a black plate. This is not a regression: the earlier snapshots were just
as opaque.

**A trap for the future: the yellow frame.** `fillZone` under the yellow strip cuts a **fully
transparent** groove (`compositingOperation = .copy` + `NSColor.clear`) so the wallpaper shows through
it on the real bar. On the tile, what's underneath is black, so the effect inverts into a black tick.
On the current reference frame this doesn't fire (7d here is `systemOrange`, not `systemYellow`), but
switching the frame to a yellow state will expose the cutouts.

**The preview can no longer go stale.** The main win, and it's structural: the next change to
`Metrics` or the palette carries into the tiles by itself.

## Alternatives considered

**Keep the PNGs and just reshoot them.** Would fix today's mismatch and not fix the cause — the next
geometry change would start the clock over, with the same absence of any signal.

**Keep the PNGs as a fallback ahead of the renderer.** Code that never runs but has to be
maintained — and that drags along the entire resource bundle and its trap.

**Cache three `NSImage`s in a `static let`.** That's what the earlier code did (there it was
justified by reading from disk). Rejected twice for the renderer: `NSView` inherits `@MainActor`, so
a lazily initialized `static let` would run on whichever thread accessed it first; and a cache would
freeze the colors against live edits from the dev tuner (`ColorStore.onChange`). Three 38×22 pt
canvases cost microseconds.

## Related

- [ADR-0093](0093-bar-style-picked-by-picture.md) — the picker's shape; §1 and §3 are superseded by
  this ADR.
- [ADR-0096](0096-zero-tick-on-pressure.md) — the zero tick in Pressure; the very thing that made the
  snapshots stale and turned ADR-0093's hypothetical cost into a fact.
- [ADR-0095](0095-own-resource-bundle-lookup.md) — bundle resolution; its only consumer is gone.
- [ADR-0083](0083-live-dropdown-preview-in-settings.md) — the precedent for forcing vibrancy.
- [ADR-0080](0080-per-surface-bar-style.md) — the style is chosen separately per surface.
