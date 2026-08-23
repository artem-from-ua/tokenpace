---
status: accepted
date: 2026-08-02
superseded_by: [0064]
---

# ADR-0060: A unified palette — system semantic colours shared by the menu bar and the popup (except the Claude brand)

> **Extends [ADR-0059](0059-menu-bar-native-semantic-colours.md)** to the popup **and merges the
> color roles of both surfaces**. ADR-0059 moved only the **menu bar** to system semantic colors,
> deliberately leaving the popup palette on fixed values. This ADR (a) extends that same philosophy
> to the popup and (b) **merges duplicated menu-vs-popup roles into one flat set of semantic
> colors** — one color per tone, shared by both surfaces' pacing bars and service dots.
> **Partially superseded by [ADR-0064](0064-popup-translucent-card-and-glow-bars.md)**, which takes
> only the cross-link to ADR-0022's solid opaque background: the popup is now unconditionally
> translucent. **The decision itself stands** — the popup draws in system semantic colors, and the
> menu-vs-popup roles are one flat set. `ColorRole` is read at 44 sites in `PopupViewController`.

## Context

After ADR-0059 the menu bar draws exclusively with system semantic colors (`.system*`,
`labelColor@alpha`), while the popup palette stayed a mix: the service dots and the on-pace green
were already `.system*`, but the **ahead-of-pace trio** (`popupGapRed/Yellow/Orange`) and the
**greys** (track, tick, the indicator ring) were numeric sRGB constants or appearance-branched raw
greys in `PopupBarView`.

ADR-0022 §4.3 already envisioned popup pacing as "systemic" (`.systemGreen/Red/Yellow/Orange`), but
the implementation lived through **numeric sRGB approximations** of those system colors in
`ColorRole.defaultColor` — hand-tuned `#E12D23`/`#E6B419`/`#F8760F`. Consequence: the popup **didn't
flip** its light/dark variant and carried no Increase Contrast, unlike the menu bar, which already
reads those same `.menuGap*` as `.systemRed/Yellow/Orange`. Likewise, the popup's track
(`monochromeGrey`) was an **opaque** grey (ADR-0022 §4.2), while the menu-bar track had moved to a
translucent `labelColor@0.22` that breathes with the material underneath it.

Question (#217): whether to bring the popup palette to the same native adaptivity as the menu bar —
that is, replace the numeric approximations with real system colors and see live how it flips
themes.

An additional finding during the work: after the switch, both surfaces default to the **same**
`.system*` colors, but `ColorRole` kept **separate** roles for each (`menuGapRed` vs `popupGapRed`,
`menuStatusYellow` vs `popupServiceYellow`, and so on) — ~40 roles, many pairs resolving to the same
color. This was confusing (changing a menu role in the tuner didn't change the popup and vice
versa) with no real benefit. So the decision was expanded to **full unification**: one flat set of
semantic roles, shared by both surfaces.

## Decision

**The popup palette draws with system/semantic colors, like the menu bar. The exception is the
Claude brand.**

1. **The ahead-of-pace trio → `.system*`.** `popupGapRed → .systemRed`,
   `popupGapYellow → .systemYellow`, `popupGapOrange → .systemOrange` in
   `ColorRole.defaultColor`. This aligns the popup with the menu bar (where `.menuGapRed/Yellow/
   Orange` are already system colors) — both surfaces now take the same system tone, which flips
   themes and carries Increase Contrast. The numeric approximations `#E12D23`/`#E6B419`/`#F8760F`
   are removed.
2. **Greys → semantic.** Providers in `PopupBarView`:
   - `defaultIndicatorStroke` → `.separatorColor` (the same hairline as the menu-bar ring
     `.menuIndicatorStroke`);
   - `defaultTick` → `.tertiaryLabelColor` (a dimmed neutral, weaker than the dot);
   - `defaultMonochromeGrey` → `labelColor.withAlphaComponent(0.22)` — **the same track tone as the
     menu bar** (`.menuUnusedGrey`). This **reverses the opacity** of the popup bar from ADR-0022
     §4.2: the track becomes translucent and composites with the popup's NSMenu material (breathes
     with it), instead of a solid grey.
3. **The Claude brand stays numeric.** `popupClaudeBrand` (`#D97757`) — Claude's signature
   terracotta; there's no system semantic equivalent, so it's deliberately kept as an sRGB
   constant.
4. **Dead code removed.** After the greys moved to semantic, the only callers of `paletteGray(_:)`
   and `paletteDynamic(_:)` disappeared — both helpers were removed.
5. **Preview-only chrome untouched.** `popupMenuMatchedBackground` (`#212121`) and
   `popupMenuBorder` (`#4D4D4D`/`#C4C4C4`) are the material match and hairline for the dev tuner's
   **preview**, never drawn in the live UI (audit #206); they stayed fixed. Both were removed along
   with the tuner ([ADR-0106](0106-remove-dev-color-tuner-and-dissolve-colorstore.md)); the
   measured `#212121` lives on as a methodology reference (CLAUDE.md, the colors section).
6. **Full role unification (~40 → 18).** Duplicated menu-vs-popup roles merged into one flat set:
   - **6 semantic tones** — `green/yellow/orange/red/blue/gray` — one per tone, shared by both
     surfaces' pacing gaps **and** service status dots (e.g. `.systemGreen` now serves menu
     on-pace, popup on-pace, credits-¤, and the operational dot — one role, `green`).
   - **Chrome:** `barTrack` (`labelColor@0.22`), `indicatorRing` (`separatorColor`), `tick`
     (`tertiaryLabelColor`), `inUsePill`.
   - **Text/calm/brand** stay (`foreground`, `label`, `link`, `dimmedLabel`, `pillText`,
     `calmWhite`, `idleCalmGrey`, `claudeBrand`).
   Both private `Palette` accessors now point at the same role; the tuner shows each color **once**
   with a neutral name. The override layer is ephemeral (in-memory), so renaming/removing roles
   orphaned nothing.
7. **Idle-blue desaturation removed.** The `defaultIdleBlue` provider desaturated `.systemBlue` by
   ~15% toward grey (+~22% toward white on the light theme). It has been **removed** — popup idle
   now draws **pure** `.systemBlue`, identical to the menu bar. This is a **deliberate visual
   change** (per the maintainer's decision: "just without the desaturation"): on the light theme,
   the popup idle bar becomes more saturated/heavier.
8. **Trivial providers inlined.** `defaultIndicatorStroke/Tick/MonochromeGrey` (one-liners after
   unification) were inlined directly into `ColorRole.defaultColor` and removed; only
   `defaultDimmedLabel` remains (a per-appearance blend). Together with `defaultIdleBlue` and the
   `paletteGray`/`paletteDynamic` helpers, this removed all of the popup's per-element color
   plumbing.

**The rule (ADR-0046/0059) is honored:** changing the `Palette` accessors and
`ColorRole.defaultColor` happens in one commit. (This rule itself later became moot — after
[ADR-0106](0106-remove-dev-color-tuner-and-dissolve-colorstore.md) the value is stored in one
place, so there's nothing left to diverge.)

## Consequences

- **+** The popup palette flips light/dark and carries Increase Contrast automatically, like the
  menu bar and native icons; the popup and menu bar now match in pacing tone (both `.system*`).
- **+** Removed the numeric sRGB approximations and appearance branching of raw greys, plus the
  associated dead code.
- **−** The system `.systemRed/Yellow/Orange` differ from the hand-tuned tones (`.systemYellow` in
  particular may read paler/greener than the manual amber) — a deliberate trade of a hand-tuned
  tone for native adaptation; finalized by a live check.
- **−** The popup's track becomes translucent (reversing ADR-0022 §4.2): now depends on
  alpha-compositing with the NSMenu material. The exact alpha (0.22) was matched against the menu
  bar, but on the popup it may need tuning; the fallback is `.secondaryLabelColor` (an opaque
  semantic).
- **+** One flat set of roles instead of ~40 duplicated ones: the tuner shows each color once, and
  changing a tone applies to both surfaces at once — consistent by construction.
- **−** Lost the ability to tune menu vs popup (or pacing vs status) **independently** — that is the
  point of the unification, but anyone who relied on separate tuning no longer has it. Since the
  override layer is ephemeral and never ships, this has no effect on a normal launch.
- **−** Popup idle-blue loses its desaturation → becomes pure `.systemBlue` (the one deliberate
  visual change; the menu-bar idle was already pure). Noticeably more saturated on the light theme.
- **Experimental:** the rest of the merges are pixel-for-pixel (all absorbed roles already had the
  same `.system*` default), so the only real visual shift is idle-blue; that's what's being checked
  live.

## Related

- [ADR-0059](0059-menu-bar-native-semantic-colours.md) — menu-bar semantic colors; this ADR extends
  the same decision to the popup.
- [ADR-0022](0022-popup-bar-transparency-and-contrast-experiment.md) — the look of the popup bars;
  the clause on the **opaque monochrome** track (§4.2) and the numeric implementation of pacing
  colors (§4.3) are superseded by this ADR; the decision on the dropdown's solid backdrop
  (`SolidBackdropView`) is further superseded by
  [ADR-0064](0064-popup-translucent-card-and-glow-bars.md) — the popup is now always translucent
  (a card), and `SolidBackdropView` was removed.
- [ADR-0046](0046-dev-color-tuner-override-layer.md) — ColorStore/ColorRole, which this decision
  extends. The observation that the tuner "flattens" system-color adaptation, and that the
  experiment was done by editing `defaultColor` rather than through the tuner, later became the
  basis for removing it entirely ([ADR-0106](0106-remove-dev-color-tuner-and-dissolve-colorstore.md)).
