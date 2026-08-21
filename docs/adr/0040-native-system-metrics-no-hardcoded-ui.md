---
status: accepted
date: 2026-07-27
superseded_by: [0042, 0059, 0069]
---

# ADR-0040: A native UI look via system mechanisms, not hardcoded metrics

> **Partially revised by [ADR-0042](0042-settings-swiftui-form.md) (#168):** §2 (hardcode exceptions
> for the grouped-inset container, chip, and time picker) and §4 ("for now we keep AppKit
> hand-drawing") were carried out — the Settings window was rewritten to SwiftUI
> `Form.formStyle(.grouped)` + `NavigationSplitView`, so the grouped-inset/chip/time-picker cases are
> **no longer** manual exceptions (Form/List/DatePicker supply them via system defaults), and the
> measured constants were removed. The §1 principle ("zero hardcode for system elements") still
> stands.
>
> **Partially revised by [ADR-0059](0059-menu-bar-native-semantic-colours.md):** the §3 exception —
> "the menu-bar `StatusItemView` uses a fixed sRGB because `labelColor` gives the wrong RGB" — is
> **withdrawn**: the bar now falls under §1 (zero hardcode) — system semantic colors (the
> `labelColor` family + `.system*`). The exception for the **popup**'s pacing bars (ADR-0022) still
> stands.
>
> **Partially clarified by [ADR-0069](0069-settings-window-height-resizable.md):** the §1 clause "the
> window → fixed at 857 pt" now applies only to **width** — the Settings window's height is
> user-resizable and persisted. This does not violate the §1 principle but rather fulfills it: the
> resize actually removes hardcode, since manual bumps to the fixed height for every new Appearance
> option are no longer needed — content scrolls via the system `Form.grouped`. The 258 pt sidebar
> stays fixed.

## Context

The product goal is for **TokenPace to follow the native macOS app design as closely as possible**
(System Settings above all). During a big parity pass (#156, on top of the redesign #131 /
ADR-0035) it turned out the Settings window was riddled with **hardcoded** sizes, fonts, spacing,
and colors picked "by eye." This produced drift from System Settings, which then got endlessly
"tuned" number by number.

The root cause: the code **hand-draws grouped-inset UI** (a custom `SettingsCard`, a custom chip
behind the sidebar icon, its own `NSTableView`, manual row constraints), bypassing the system
mechanisms AppKit already offers that produce a native look on their own.

This called for the same class of decision as ADR-0009…0011 (where the boundary between system and
custom sits): **what to take from the system, what to keep custom — and how to avoid hardcoding
what the system already gives you.**

## Decision

**1. For standard system elements — zero hardcoded metrics.** Use what AppKit provides rather than
picking numbers:

- Sidebar icon size → read `NSTableViewDefaultSizeMode` (`NSGlobalDomain`), react to changes via
  `DistributedNotificationCenter` (`AppleSideBarDefaultIconSizeChanged`). `effectiveRowSizeStyle`
  does **not** resolve `.large` for a source list — don't rely on it.
- Switches → `NSSwitch.controlSize = .mini`; popup buttons → `.flexiblePush` + `.small` +
  `showsBorderOnlyWhileMouseInside`; fonts → `NSFont.systemFontSize`/`smallSystemFontSize`/text
  styles.
- Row alignment → `NSStackView.alignment = .firstBaseline` + `edgeInsets` (row height = content +
  a symmetric inset), not manual top/bottom centering (which makes text top-heavy).
- Section symbols → the exact ones from System Settings' `.appex Info.plist`
  (General=`gear`, Notifications=`bell.badge.fill`, weight `.regular`). Long labels → truncate +
  `allowsExpansionToolTips`. A folder path → `NSPathControl`. The window → fixed at 857 pt (like
  System Settings), sidebar fixed at 258.

**2. Exceptions — where AppKit has NO API (hardcode is unavoidable, but MEASURED, not guessed).**
AppKit has no iOS-like grouped primitives; System Settings renders via SwiftUI/private APIs, and
there is no pure AppKit equivalent. In these spots we hand-draw, but the values are **measured from
a live System Settings** (AX `AXSize` / Retina ÷2) and documented:

- **Card/background color** — there is no semantic grouped-background (neither an `NSColor` nor a
  material with a correct light↔dark flip) → a fixed dynamic `NSColor` (card 242/43, background
  246/40).
- **Grouped-inset container** (`SettingsCard` row height, corner radius, padding) — AppKit has no
  container with these defaults → hand-drawn with measured values.
- **Rounded time picker** — `NSDatePicker` doesn't round its own bezel → a bezelless picker inside a
  custom `RoundedFieldBox`.
- **Colored sidebar chip** — the standard `.imageView` outlet applies source-list tint/vibrancy (it
  fades, disappears on an inactive window) → a custom chip, sized from a measured table.

**3. Deliberate custom exceptions (not System Settings elements).** A fixed palette stays:
- The menu-bar widget (`StatusItemView`) — a fixed sRGB, because `labelColor` gives the wrong RGB
  in an off-screen `NSImage` (ADR-0009).
- The popup's pacing bars — a fixed palette, shared with the statusline (ADR-0022).

**4. Final parity without constants — a SwiftUI Form.** System Settings is a SwiftUI
`Form { Section }.formStyle(.grouped)` (verified: both the shell and the pane extensions link
SwiftUI). This is the only way to get row height/padding/corner radius/dividers from **system
defaults** with zero constants. Rewrite `SettingsCard` as a SwiftUI Form via `NSHostingView` (#168);
for now, keep AppKit hand-drawing with measured values (lower risk, phased).

## Consequences

- **The verification process is tightened:** any UI change is checked in **both** themes
  (light+dark) and **every** state (sidebar icon size 1/2/3, dev build/`.app`) with screenshots
  before a PR. Skipping this was the most common cause of regressions in #156 (see
  [system-settings-parity.md](../reference/system-settings-parity.md)).
- Part of ADR-0035 is revised: the card's manual `controlBackgroundColor` fill → a dynamic grouped
  color / material approach; the checkbox-disable logic is extended to "Back to work" for dev
  builds.
- Where hardcode is unavoidable — it is **named, measured, and documented**, not a "magic number."
- A detailed breakdown (lessons, the measurement method, common mistakes) lives in
  [docs/reference/system-settings-parity.md](../reference/system-settings-parity.md).

## Related

- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — pure-core/thin-shell; the menu
  bar's fixed color (the §3 exception).
- [ADR-0021](0021-popup-two-column-layout-and-uniform-dropdown-typography.md) — the HIG check before
  a commit; "don't eyeball a size."
- [ADR-0022](0022-popup-bar-transparency-and-contrast-experiment.md) — the pacing bars' fixed
  palette.
- [ADR-0035](0035-settings-window-sidebar-grouped-inset.md) — the initial Settings redesign
  (partially revised here).
- Issue #156.
