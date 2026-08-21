---
status: superseded
date: 2026-07-30
superseded_by: [0106]
---

# ADR-0046: A centralized `ColorStore` override layer for the dev color tuner

> Superseded by [ADR-0106](0106-remove-dev-color-tuner-and-dissolve-colorstore.md): the tuner and
> `ColorStore` are removed, and both `Palette`s now read `ColorRole.defaultColor` directly. What
> still stands is the **role catalog itself** — but as the app's palette, not as a registry for a UI
> tool; the menu-bar / popup split from "Clarification D2" also lives on, on its own merits.

## Context

TokenPace's UI colors lived in **two independent private `enum Palette`s**: menu bar
(`StatusItemView.Palette`, fixed sRGB — a non-template image) and popup (`PopupBarView.Palette`,
appearance-aware `NSColor(name:dynamicProvider:)`), plus a handful of separate semantic colors
(`claudeBrandColor`, `dimmedLabelColor`). Each color was a `static let` literal, read directly at
its drawing site. The ahead-of-pace grading (yellow/orange/red) was already single-sourced in
`PopupBarView.aheadColor` (already reused cross-file by the menu bar).

Picking a color meant a "edit the literal → `swift build` → look → repeat" loop: no way to see live
how a change affects the menu-bar icon and the popup together. A dev tool was needed (#185) — a
window with a role dropdown plus an **embedded inline color picker** (RGB/HSB sliders + 16-bit
fields) that redraws both surfaces instantly.

The question: how to let such a tool **override** any color at runtime, without affecting ordinary
users and without bloating the hot draw path.

## Alternatives considered

1. **An `#if DEBUG` gate.** The compiler strips the code from release. But: the feature needs to
   work on a notarized/release build too (the maintainer tunes colors on the real installed app),
   which `#if DEBUG` rules out.
2. **A minimal override dict inside each `Palette`.** The least amount of refactoring, but it
   duplicates the logic in two places and gives no single role catalog for the UI (names/groups/
   descriptions/transforms).
3. **A centralized `ColorStore` plus a `ColorRole` catalog (chosen).** One enum of every role and
   one store that both `Palette`s read every color through.

## Decision

**Introduce `ColorRole` (a flat catalog of roles) and `ColorStore` (an `@MainActor` singleton),
through which both `Palette`s read every color.** Every `static let X = <literal>` became
`static var X: NSColor { ColorStore.shared.color(.x) }`; the defaults were carried over 1:1 into
`ColorRole.defaultColor` (appearance-aware providers stayed on the `PopupBarView`/
`PopupViewController` side as `default*` statics, so the per-appearance logic isn't duplicated).
Transforms (`lightened`, alpha, calm-swap) stayed at their call sites — they wrap the value coming
from the store.

**The gate is the env var `TOKENPACE_DEVTOOLS`, not the build type.** When it's empty,
`ColorStore.color(role)` always returns the default and the override dictionary is never even
read — zero impact on the draw path and no risk of accidentally changing a color. Independent of
dev/notarized/release. The same flag gates both the "Development tools…" menu item (plus ⌥ Option)
and the override itself.

Overrides are **ephemeral**: held in memory, never persisted; quitting restores every default.
Changing a color fires `onChange` → `AppDelegate.reRenderForCurrentTime()`, which re-snapshots the
menu bar and rebuilds the popup in one pass (the same path the "Calm colors" toggle already uses).

## Clarification D2: splitting menu-bar / popup pacing

Initially the ahead-of-pace colors (yellow/orange/red) were single-sourced in
`PopupBarView.aheadColor`, and the menu bar pulled them in cross-file. For the tuner this meant one
slider controlled both surfaces — a source of confusion ("where's the separate menu-bar red?").
**Decision:** split them — add separate `menuGapRed/Yellow/Orange` and parameterize `aheadColor` by
`PacingSurface { popup, menuBar }`. Menu-bar call sites pass `.menuBar` (and additionally lighten
~10%), the popup passes `.popup`. The menu constants' defaults start at the same values as the
popup's (so the look doesn't change), then tune independently. The catalog was also expanded to
~35 roles — adding the popup's service dots (separate appearance-aware `.system*` colors, unlike
the menu's fixed-sRGB dots), the popup warning red, the "in use" pill, links, and labels.

## Consequences

- **+** Live tuning of any of the ~20 colors with no rebuild; a single role catalog with names,
  groups, a thorough usage description, and a note on transforms — the source of the tuner's
  labels.
- **+** Colors now have one access layer; if theming/persistence is ever needed, the place for it
  already exists.
- **−** Every `Palette` color is now a computed `var` (a call to `ColorStore.color`) instead of a
  `static let`: a cheap Bool check plus a dictionary lookup only when dev tools are on, otherwise
  just a Bool check plus the default.
- **−** `enum Palette` had to be marked `@MainActor` (the store is `@MainActor`); the draw code was
  already on main.
- Rule: when changing a `Palette` color, update `ColorRole.defaultColor` in the same commit (they
  must match).
