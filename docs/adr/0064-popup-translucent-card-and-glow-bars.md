---
status: accepted
date: 2026-08-03
supersedes: [0022]
---

# ADR-0064: The popup — unconditionally translucent, a Control Center card, rebuilt bars with glow

## Context

[ADR-0022](0022-popup-bar-transparency-and-contrast-experiment.md) settled on a **solid opaque
background** for the whole dropdown (`SolidBackdropView` under the bar section + an overlay on the
native `Settings…`/`Quit`, #86), because a translucent bar over an *arbitrary* background
(wallpaper/other windows) produced unstable contrast.

At first (#188) we added this as an **optional toggle**, "Translucent system background" (Settings
→ Appearance, default off, outside the presets), which restored the native menu material. Live
verification found:

- The solid background made the popup feel heavy and off-system; users consistently rated the
  translucent menu look better — so the "optionality" was extra complexity for no benefit (two
  modes, a toggle, persistence, a live-re-apply gate).
- The real source of unstable contrast in ADR-0022 was the **translucent bar itself**. If instead
  the whole section sits on its **own card** (a dense, rounded card over the material), the content
  reads against a stable backing, and translucency only lets the material "breathe" at the edges —
  no contrast risk.

At the same time, the popup's bars were being redrawn: the old look (monochrome zones + dark
`indicatorStroke` separators) didn't fit the new card and needed cleaner endcaps/separation.

## Decision

1. **The popup is unconditionally translucent.** The toggle, `PersistedConfig.popupTranslucentBackground`,
   `SolidBackdropView`, the whole-menu overlay (`installOpaqueMenuBackdropIfNeeded`, #86), and the
   entire opaque mode are **removed** (−230 lines). The real menu window (`NSPopupMenuWindow`)
   already draws its own vibrancy material — we no longer cover it with anything else.
2. **A Control Center card** (`CardBackdropView`): the whole Claude section sits on a rounded,
   layer-backed card with a soft shadow, `fill = controlBackgroundColor@0.85`, an inset from the
   edges (the menu material shows through around it), and a hairline border. Its width matches the
   separator between native items; the separator before `Settings…` is removed (the card itself
   sets the section apart).
3. **The bars were rebuilt:** a solid gray track → a colored **strip with capsule endcaps** (both
   ends round; the endcap near the bar's edge blends into it) + an ambient **glow** → a **slider**
   with a filled-frame gray border (rather than a centered stroke, which read crooked) and a
   stronger glow. The idle bar (5h "ready to start") has its own, more compact and stronger glow.
4. **Service status dots** — `GlowDotView` (layer-backed with glow) rather than a baked symbol
   image: the fill and shadow color re-resolve in `updateLayer`, so they **survive a light/dark
   theme switch**. (Rule: no color baking into a bitmap — everything runs on dynamic system
   colors.)
5. **The dev color-tuner preview** forces the **Vibrant** appearance (`vibrantDark`/`vibrantLight`)
   of the current theme, because the real menu window is `NSAppearanceNameVibrantDark`, and system
   label colors resolve differently under vibrancy (e.g. `monochromeGrey` → opaque `#323232` in
   VibrantDark vs. light `white@0.17` in DarkAqua). Without forcing it, neutrals in the preview read
   lighter than the live menu. The preview also reacts to Bar style/ticks changes.

## Consequences

- One mode instead of two — simpler code and UX; the "no baking" convention is honored (theme flips
  work correctly for dots and bars).
- The wallpaper's real tone on the card is **unreachable from inside `NSMenu`** (the window is
  system-owned/opaque — see the #188 investigation): the card takes its tone from the **menu's own
  material**, not the desktop. In the dev preview (our own window), vibrancy is possible, but it
  yields different neutrals — so the preview stays on a flat `#212121` + Vibrant appearance as an
  **exact color reference**, not a demonstration of transparency.
- ADR-0022 (the clause about a solid opaque background) and the cross-link in
  [ADR-0060](0060-popup-native-semantic-colours.md) are superseded by this.

## Related

- [ADR-0022](0022-popup-bar-transparency-and-contrast-experiment.md) — the earlier decision on a
  solid background (superseded by this ADR).
- [ADR-0060](0060-popup-native-semantic-colours.md) — the system semantic colors for popup bars.
- [ADR-0062](0062-configurable-bar-presentation.md) — `barStyle`, which is drawn here on the new
  composition.
- [ADR-0046](0046-dev-color-tuner-override-layer.md) — the dev color tuner, whose preview now forces
  Vibrant.
