---
status: accepted
date: 2026-08-02
superseded_by: [0106]
---

# ADR-0059: Menu-bar widget — native semantic colours, not statusline-fixed sRGB

> **Partially superseded by [ADR-0106](0106-remove-dev-color-tuner-and-dissolve-colorstore.md).**
> Only what concerns the **access layer** is superseded: `ColorStore` and the tuner were removed,
> so the phrases "extends ColorStore/ColorRole", "the Tuner and the override layer work as before"
> and the rule "update `ColorRole.defaultColor` in the same commit" no longer describe the code —
> the value is now stored in one place, with no desync to have. **The decision itself still stands
> in full**: the menu bar draws with system semantic colors, `labelColor@0.22` for the track,
> bright-alpha 0.865, resolved against `button.effectiveAppearance`.

> This ADR supersedes the colour clauses of [ADR-0005](0005-pacing-fractions-not-blocks.md),
> [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) §5–§9,
> [ADR-0022](0022-popup-bar-transparency-and-contrast-experiment.md) (menu-bar clause),
> [ADR-0027](0027-session-idle-no-phantom-reset.md) D7 (menu-bar blue), and reverses the
> [ADR-0040](0040-native-system-metrics-no-hardcoded-ui.md) §3 exception. It **extends**
> [ADR-0046](0046-dev-color-tuner-override-layer.md) (ColorStore/ColorRole) rather than replacing it.
> The bright-tone alpha (a single 0.865) is derived from live eyedropper measurement; the maintainer
> confirmed the on-bar render.

## Context

The menu-bar widget (`StatusItemView`) historically drew with **fixed sRGB** — the exact xterm-256
palette from the statusline (ADR-0005/0009): used `#303030`, gap-green `#5faf5f`, gap-red
`#d75f5f`, idle `#005f5f`, and so on. The rationale (ADR-0009 §9, ADR-0040 §3): the image is a
**non-template `NSImage`**, and `NSColor.labelColor` inside an off-screen image supposedly resolves
to the wrong RGB (dark text on a dark bar), so semantic colours "don't work" and a hardcode was
needed. The statusline was the reference so the bar would match the terminal one-to-one.

This model has three flaws that showed up on the live bar:
1. **It doesn't "breathe".** Native menu-bar icons (the moon, Wi-Fi, battery) pick up the
   wallpaper's tint through the vibrancy material and flip light/dark along with the bar. Our fixed
   grey stayed the same on any wallpaper — noticeably "dead" next to its system neighbors.
2. **The statusline is no longer the reference.** Tying the bar to the xterm palette was the
   initial idea; the product has moved past it. Keeping the bar's color a slave to the terminal
   theme is an arbitrary constraint.
3. **A false premise.** "`labelColor` gives the wrong RGB in an off-screen image" was an artifact
   of the image being drawn in the **wrong appearance** (the lazy `drawingHandler` resolved colors
   later, under the vibrant material, where `labelColor`'s alpha drops 0.847→0.698). With **eager**
   drawing in `button.effectiveAppearance`, `labelColor` resolves correctly and flips on its own.

The task (reframed with the maintainer): make the bar's mono parts look and behave like native
system icons — flipping, breathing with the wallpaper, dimming the system way — while carrying
color accents the way the battery carries its yellow/red. Only system modifiers (semantic colors),
no fixed sRGB, no manual theme detection, no statusline parity.

## Alternatives considered

1. **Fixed sRGB / `lightened` (status quo).** Doesn't breathe — empirically rejected.
2. **True template vibrancy.** `isTemplate = true` consumes only an alpha mask and **inverts** on a
   dark bar (draws with the light content color → near-white), carrying no color accents.
   `wantsLayer`+a CALayer overlay for color **breaks** vibrancy (Apple Forums thread/776799). No
   real menu-bar app does this — unreachable for our color geometry.
3. **Calibrating against the wallpaper (an eyedropper + brightness/saturation sliders).** Manual
   compensation for "breathing". Built and **rejected**: `labelColor@fixed-alpha` breathes ON ITS
   OWN (see Decision), so sliders/background sampling turned out unnecessary.
4. **Custom-draw semantic (chosen).** A single non-template image, the `labelColor` family +
   `.system*`, resolved eagerly against the real bar. Every real menu-bar app does this
   (Stats/iStat/AlDente).

## Decision

**Draw the bar as one non-template `NSImage`, all colors system semantic, resolved eagerly against
the real bar's appearance. No fixed sRGB, no statusline, no manual theme branching in the render.**

**1. Render — eager against `button.effectiveAppearance`.** `snapshotImage()` draws via
`image.lockFocusFlipped(true)` **inside**
`button.effectiveAppearance.performAsCurrentDrawingAppearance` (in `AppDelegate.refreshStatusImage`),
NOT the lazy `NSImage(size:flipped:drawingHandler:)`. A lazy handler would resolve dynamic colors
later, under the vibrant material (where `labelColor`'s alpha drops). Eager baking bakes each
semantic color against the **real** appearance of the bar the caller set. Re-snapshotting on a
theme flip goes through the existing KVO on `button.effectiveAppearance` (the standard path for
non-template). `button.effectiveAppearance` is the **only** correct source for the bar's lightness
(it detects the bar's tone from the wallpaper even under system Dark); `view/NSApp.effectiveAppearance`
give the system theme, not the bar.

**2. Track (the base rail) = `labelColor.withAlphaComponent(0.22)`.** A semi-transparent silhouette:
the bar's background (wallpaper through vibrancy) shows through at 78%, so the track is both dimmed
LIKE THE MOON and BREATHES with the background's tint. `labelColor` flips itself (white/black). The
model `ink@0.22 over bg` was verified with an eyedropper on teal/blue/white bars (our `3f7070` vs
the moon's `407373`; `445465` vs `455667`; `0xBF` vs `0xC1`). The role is `menuUnusedGrey` in
`ColorRole.defaultColor`.

**3. Bright tones (reset text, ⚠️, tick) = `labelColor` at a fixed alpha.** `bright(_:)` takes
`labelColor`, resolves its RGB into sRGB, and substitutes **one** fixed alpha, **0.865**. With an
eyedropper, the light bar wanted ~0.85 (`1e2423` = the system's), the dark bar ~0.88 (`≈0xE6` vs
`0xE7`), but **the difference between them is invisible to the eye**, so one average value serves
both themes — no switch, no branching. `labelColor` flips its own COLOR; the alpha only equalizes
opacity under the vibrant material (where `labelColor`'s own alpha drops 0.847→0.698).

**4. Color accents = `.system*`.** Pacing gap/marker, the service dot, idle → `.systemGreen/Yellow/
Orange/Red/Blue` via the existing `accent()` (scaled by `accentSaturation`, default 1.0). They are
deliberately **opaque** and not tinted by the wallpaper — the way the battery's yellow stays yellow
on any background; they only flip their light/dark variant and carry Increase Contrast.

**5. No theme switch, calibration, sliders, or background sampling.** `labelColor` flips
light/dark on its own, track@0.22 breathes physically (via translucency), and the bright-alpha is
imperceptible between themes — so no manual brightness control is needed. A "Wallpaper brightness"
switch (Auto/Light/Dark) for a split alpha of 0.85/0.88 was considered but **rejected**: the
difference is invisible to the eye, so it would have added a setting with no benefit. Removed along
with dead code: `monoBrightness`, `calibrationColor`, `monoTintFraction`, the env overrides
`TOKENPACE_MONO_BRIGHTNESS/ACCENT_SATURATION/CALIB_HEX`.

**6. dimmed → we do NOT add it.** The bar has no dimmed state: loss of connectivity is shown via a
content swap to ⚠️ (more informative than dimming, which would hide the signal).
`appearsDisabled` is not applied.

**Relation to ADR-0046.** This decision **extends** ColorStore/ColorRole: the roles stay, only
their `defaultColor` for the menu bar changes (fixed sRGB → semantic). The tuner and the override
layer work as before.

## Consequences

- **+** The mono parts breathe with the wallpaper and flip theme automatically, like native icons;
  accents carry system light/dark + Increase Contrast variants for free.
- **+** Removed the sRGB hardcode, statusline parity, manual calibration, and the associated dead
  code.
- **−** This is a custom-draw **approximation**, not true template vibrancy (unreachable — see
  alternative 2): the mono breathes because it's translucent, not because the system tints our
  image. On **saturated color** bars, the track copies the moon's brightness/breathing, but not its
  undocumented **blue tint** (the system tints dimmed icons toward cool) — deferred to the color
  tuning stage.
- **−** Bright-alpha is one average (0.865) for both themes; on each individual theme the "ideal"
  would be ±0.015 off, but the difference is invisible to the eye, so the trade-off has no visible
  consequence.
- Rule (ADR-0046): when changing a menu `Palette` color, update `ColorRole.defaultColor` in the
  same commit.

## Related

- [ADR-0005](0005-pacing-fractions-not-blocks.md) — fractions in [0,1] stay; the color binding
  (PacingState→RGB, xterm) is superseded.
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — the thin shell/pure layout stays;
  §5–§9 (non-template fixed sRGB, the statusline palette, "labelColor gives the wrong RGB") are
  superseded.
- [ADR-0022](0022-popup-bar-transparency-and-contrast-experiment.md) — popup transparency is
  untouched; the clause "menu-bar stays fixed statusline" is superseded.
- [ADR-0027](0027-session-idle-no-phantom-reset.md) — the idle logic stays; D7's menu-bar fixed blue
  → `.systemBlue`.
- [ADR-0040](0040-native-system-metrics-no-hardcoded-ui.md) — the §3 exception "StatusItemView fixed
  sRGB" is revoked (the bar is now subject to the §1 "zero hardcode" rule).
- [ADR-0046](0046-dev-color-tuner-override-layer.md) — ColorStore/ColorRole, which this decision
  extends.
- [ADR-0060](0060-popup-native-semantic-colours.md) — extends this decision (system semantic
  colors) to the **popup** (a separate follow-on decision, #217).
