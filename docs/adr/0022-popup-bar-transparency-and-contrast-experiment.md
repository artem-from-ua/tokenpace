---
status: accepted
date: 2026-07-23
superseded_by: [0059, 0060, 0064]
---

# ADR-0022: Popup pacing-bar appearance — opaque monochrome bars on a solid background

> **Partially superseded by [ADR-0059](0059-menu-bar-native-semantic-colours.md):** the clause in
> "Consequences" that the **menu-bar bar** stays on fixed statusline values (ADR-0005) is revoked —
> the menu bar now draws with system semantic colors (track = `labelColor@0.22`, accents =
> `.system*`).
>
> **Partially superseded by [ADR-0060](0060-popup-native-semantic-colours.md):** the popup pacing
> palette also moved to system semantic colors — the trio `.systemRed/Yellow/Orange` (instead of
> numeric approximations) and a **semi-transparent** track, `labelColor@0.22` (a reversal of the
> opaque monochrome bar, §4.2). The Claude brand color stays sRGB.

> **Superseded by [ADR-0064](0064-popup-translucent-card-and-glow-bars.md) (#188):** the decision
> for a **solid opaque background** across the whole dropdown (`SolidBackdropView` + an overlay for
> native items, #86) **is revoked**. The popup is now **unconditionally** translucent: the "Claude"
> section sits on a rounded card (`CardBackdropView`) over the native menu material;
> `SolidBackdropView` and the opaque mode were removed. The bars were also rebuilt (capsule colored
> strips + glow) — see ADR-0064.

## Context

The popup dropdown (`PopupViewController`) **does not draw its own opaque background** — its
content is hosted inside `NSMenuItem.view`, with `NSMenu`'s own vibrancy material showing through
underneath. When we tried making the pacing bars semi-transparent (so the pacing accent would read
against a softer base), an **arbitrary background under the popup** (other windows, the wallpaper)
started showing through the bar's zones — and the contrast of both the bars and the text became
unstable: the same color looks different on a light patch versus a dark one.

Guaranteeing a minimum contrast over an *arbitrary* background we don't control is impossible:
AppKit gives no access to whatever the system composites under the vibrancy layer.

To find a workable appearance, we ran a **live A/B experiment** — temporarily adding toggles for
several axes to the dev dropdown (bar-zone transparency, contrast strategy, forced light/dark) and
compared approaches against a real, mottled background in both themes. This ADR records the
experiment's **outcome** and the final decision; the toggles themselves were removed after the
choice was made.

## What we tested (historical context)

These existed temporarily (all in the dev dropdown, with env seeds):

- **Bar-zone transparency** (`BarAppearance`, `TOKENPACE_BAR_ALPHA`): `opaque` / `all` (the whole
  bar) / `gap` (the pacing gap only) / `background` (used+future+ticks) / `opaqueSolid` (everything
  opaque + a solid backing plate). Transparency was 0.8 / 0.75 for the gap.
- **Contrast/backing** (`BarContrast`, `TOKENPACE_POPUP_CONTRAST`): `none` / `backingPlate` (an
  opaque plate under the bar) / `vibrancy` (`NSVisualEffectView`). The **`adaptive halo`** prototype
  (a background-colored outline around the bars) was rejected — it read as "muddy" and didn't solve
  the problem.
- **Monochrome bars** — both used+future in light gray instead of dark-used + a teal tail.
- **Force light/dark** (`ThemeOverride`, `TOKENPACE_THEME`) — a forced popup theme, to check colors
  in both appearances without switching the whole system.

## Key findings

1. **A transparent bar over an arbitrary background is unstable** — so the final decision is
   opaque.
2. **`opaqueSolid` + an overlay covers the whole dropdown.** `SolidBackdropView`, inserted as the
   lowest subview of `NSPopupMenuWindow.contentView` (verified on macOS 15 — issue #86), makes the
   **entire** dropdown solid, including the native `Settings…`/`Quit` items. This relies on a
   private menu hierarchy — fragile, but with graceful degradation (a guard that finds nothing is a
   no-op).
3. **Monochrome bars read best** — used+future in a solid appearance-aware gray, with the
   pacing gap + dot as the sole color accent.
4. **`ThemeOverride` ran into an NSMenu limitation:** forcing the menu/window appearance recolors
   the items' **background**, but `NSMenu` draws their **text** itself and **ignores** both the
   forced appearance and an explicit `attributedTitle` foreground for enabled items (verified by
   diagnostics — the color on the object is correct, visually it isn't). So a fully consistent
   forced-dark look with readable text on native items is unreachable. The toggle was removed;
   themes are tested via the system's own System Settings.

## Decision

1. **Hardcode a single behavior, remove all toggles and axes.** `BarAppearance`, `BarContrast`,
   `ThemeOverride`, `adaptive halo`, the hover preview, and the env vars `TOKENPACE_BAR_ALPHA` /
   `TOKENPACE_POPUP_CONTRAST` / `TOKENPACE_THEME` / `TOKENPACE_FUTURE_GREY` were all removed.
2. **The fixed appearance:** opaque **monochrome** bars (used+future — a solid gray,
   `Palette.monochromeGrey`), a solid opaque background across the **whole** dropdown
   (`SolidBackdropView` + an overlay for native items), no contrast effects.
3. **Pacing colors are system colors** (`.systemGreen/.systemRed/.systemYellow/.systemOrange`), the
   same ones used in the service status dots. Ahead-of-pace grades by how far ahead: below the
   dynamic threshold `0.16·(1−timeFraction)` is yellow, at/above it (or a reset `≤ 20 min` away) is
   orange, exhausted is red (`PopupBarView.aheadColor`; the threshold is from ADR-0044, historically
   a static `15` points).
4. **`dimmedLabelColor` is now dynamic**, an `NSColor(name:)` (blending in the target appearance),
   rather than `static let .blended(...)`, which baked in the appearance from the first access and
   came out near-black in dark mode.

## Consequences

- The release build has a stable, predictable appearance; no "experimental" menu.
- The menu-bar bar (`StatusItemView`) draws the same monochrome zones; its pacing colors there stay
  on fixed statusline values (ADR-0005), because the menu bar has no mottled background.
  _(Superseded by ADR-0059/0060: both surfaces now draw with system semantic colors.)_
- Full background coverage via the private NSMenu hierarchy remains a documented risk
  ([issue #86](https://github.com/artem-from-ua/tokenpace/issues/86)); it degrades safely.
- If a forced theme with read-only native items is ever needed, it will require
  `popUpMenuPositioningItem:inView:` with a separate window (Apple DTS forums 106894), not
  `item.menu`.

## Related

- [ADR-0021](0021-popup-two-column-layout-and-uniform-dropdown-typography.md) — the popup's
  two-column layout and `addSplitLine`, on top of which these bars are drawn.
- [ADR-0005](0005-pacing-fractions-not-blocks.md) / [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md)
  — the pacing bars' geometry and colors (`Palette`).
