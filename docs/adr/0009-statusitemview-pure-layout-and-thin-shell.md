---
status: accepted
date: 2026-06-22
superseded_by: [0015, 0059]
---

# ADR-0009: StatusItemView — a pure MenuBarLayout plus a thin AppKit shell

> **Partially superseded by [ADR-0015](0015-no-idle-mode.md):** the decisions in §2 (the 5% idle
> threshold) and §4 (the `*` idle glyph) are gone — there is no compact/idle mode any more. The rest
> of this ADR (the pure/shell split, `MenuBarMode` as an open enum, drawing the bars, the monochrome
> ⚠️) still stands.
>
> **Partially superseded by [ADR-0059](0059-menu-bar-native-semantic-colours.md):** §5–§9 (display
> through a non-template `NSImage` with fixed sRGB, the exact statusline 256-color palette, and the
> claim that "`labelColor` yields the wrong RGB in an off-screen image") are gone — the colors are now
> system semantic ones (the `labelColor` family plus `.system*`), resolved eagerly against
> `button.effectiveAppearance`; the false premise about `labelColor` has been disproved (it was an
> artifact of drawing lazily in the wrong appearance). The pure/shell split and the geometry still
> stand.

## Context

Issue #10 ("StatusItemView — bars + idle") introduces the first visible UI: custom menu bar drawing
(two pacing bars plus the time to reset) with a compact idle mode. Unlike the previous modules
(`PacingModel`, `ResetClock`, `TokenProvider`, `UsageClient`), this is the first time an AppKit
dependency appears — one that **is not covered by unit tests** under SPM without a full Xcode.

Three module-boundary decisions follow — the same class as in
[ADR-0005](0005-pacing-fractions-not-blocks.md),
[ADR-0007](0007-token-provider-throws-and-scope-split.md) and
[ADR-0008](0008-usageclient-pure-backoff-and-transport-seam.md):

1. **Where the "what to draw" computation lives.** If all of the logic (idle vs expanded, which bars,
   which time) sits inside the `NSView`, it is beyond the reach of tests and tangled up with drawing.
2. **What the idle threshold is and where to pin it.** The SPEC gives only a rough guide ("both limits
   < ~5% and no pacing warning"); the exact number is left to the implementation.
3. **How to show fully custom color graphics in an `NSStatusItem`** in a way that stops the system
   from recoloring them under Dark/Light tinting.

## Decision

1. **A pure-core plus thin-shell split — `MenuBarLayout` (in `CCTimerKit`) separate from
   `StatusItemView` (in `cc-timer`).** `MenuBarLayout.make(from:now:)` is a pure, deterministic
   (injected `now`) `UsageSnapshot → MenuBarMode` function that **adds no new arithmetic**: it reuses
   `PacingModel.barLayout`/`limitIndicator` (bar geometry plus severity) and `ResetClock.resetDisplay`
   (the nearest reset plus its format). Its only decision of its own is idle vs expanded. This mirrors
   `BarLayout` (ADR-0005) and `PollingBackoff` (ADR-0008): all of the view's computable logic lives in
   the library and is unit-tested, while `StatusItemView` stays a thin `NSView` that only draws a
   finished model. The view's data is tested in `MenuBarLayoutTests` without AppKit; the drawing itself
   is verified by hand (`swift run` / the `.app`).

2. **The idle threshold is `5.0%`, with a strict `<`.** `idle` ⇔ both windows have `utilization < 5`.
   The SPEC's "no pacing warning" half is **automatic**: both `LimitIndicator` alerts require
   `utilization > 90` (`.warning`) or `== 100` (`.critical`) — far above 5%, so any warned window is
   already non-idle. There is no separate condition on warnings (it would be a dead branch). The
   boundary is strict (`<`), like `OAuthCredentials.isExpired`'s `<=` and `PacingModel`'s `> 90` —
   exactly 5% is already expanded.

3. **`MenuBarMode` stays an open enum.** Two branches in #10 (`idle`, `expanded`); the error states
   (`⚠️` / stale data) are a separate branch in #12, so the enum is not overloaded now.

4. **The idle glyph is a bold monospaced `*`.** The SPEC asks for "a small icon without full bars"; a
   simple glyph, readable in both themes, was chosen. Its color (`NSColor.labelColor`) does **not**
   adapt automatically inside a non-template `NSImage` — it is resolved in the menu bar's appearance
   by hand, see point 9.

5. **Display through a finished non-template `NSImage` (`button.image`), not a subview.** Nesting a
   custom `NSView` as a subview of the `NSStatusItem` button is unreliable (the system button owns its
   layout and draws over anything you add). The reliable route for fully custom graphics is to hand
   the button a finished image, rendered eagerly (`lockFocusFlipped`). `image.isTemplate = false` stops
   the pacing colors from being recolored under Dark/Light tinting (SPEC "Technical notes").

6. **The colors are the exact `statusline` 256-color palette (fixed sRGB), not system semantic ones.**
   The zones map 1:1 onto the xterm-256 RGB of the statusline's codes (ADR-0005): used `dark_gray` 236
   = `#303030`, gap-green `bright_green` 71 = `#5faf5f`, gap-red `bright_red` 167 = `#d75f5f`, future
   `dark_blue` 23 = `#005f5f` (in fact a **dark teal**, not blue — that is what code 23 maps to),
   darkened further to `#004c4c` so the tail recedes like a background. Fixed RGB rather than
   `systemGreen` and friends: the goal is for the menu bar to reproduce the terminal statusline's look
   exactly in any theme; the image is non-template, so macOS does not recolor it.

7. **The time indicator is a dot in the pacing color with a dark outline, not a vertical tick.** The
   dot at position `timeFraction` is colored by the **raw** use-versus-time relationship (a finer
   distinction than the binary `PacingState`, where equality folds into green): `usage < time` → green
   (behind), `usage > time` → red (ahead), `usage == time` → teal (`future`). A dark ring (`#181818`)
   separates the dot from whatever color zone is underneath it.

8. **Redraw only when the data changes.** `StatusItemView.layout { didSet { … } }` updates the image
   only when the model actually changed (`layout != oldValue`) — no timer at all (architecture.md:
   energy efficiency). The polling layer (#13) will set `layout` after every poll; in #10 the
   `AppDelegate` sets it once from a mock snapshot.

9. **The semantic text color is resolved in the menu bar's appearance by hand (found and fixed in
   #11).** Because the image is non-template (point 5), macOS does **not** recolor it for the menu
   bar's theme — and `NSColor.labelColor` inside an off-screen `NSImage` resolves to RGB in the
   *ambient* appearance (Aqua by default), producing dark text on a dark menu bar. The fix:
   `snapshotImage(appearance:)` draws inside `appearance.performAsCurrentDrawingAppearance { … }`,
   and the `AppDelegate` passes `button.effectiveAppearance` and **re-renders the image when the theme
   changes** (KVO on the button's `effectiveAppearance`). This applies only to *text* (the
   `labelColor` of the idle glyph and of the reset time) — the fixed sRGB pacing colors (point 6) are
   deliberately theme-independent. The insets were tightened so the item does not "bloat" next to
   native ones: the inner horizontal inset is `hPadding = 2` (the menu bar adds its own gap between
   items), and the vertical gap between bars is `barGap = 4` (a more compact stack). The text (the idle
   glyph, the reset time) stays rasterized in the same `NSImage` as the bars — after these touch-ups it
   reads at the same scale as native items (the clock, the battery), so switching to a native
   `button.attributedTitle` was deemed unnecessary (#26 closed as resolved by these changes).

## Consequences

- All of the view's logic (the idle threshold, choosing bars and time) is covered by unit tests
  (`MenuBarLayoutTests`: idle/expanded, the 5% boundary, agreement with `PacingModel`/`ResetClock`, the
  `.resetNow` fallback) without waiting for AppKit. `StatusItemView` carries only the drawing, which is
  verified by eye.
- `CCTimerKit` stays free of AppKit — `MenuBarLayout`/`BarView`/`MenuBarMode` deal purely in semantics
  (`PacingState`/`LimitIndicator`/`TimeToReset`); the mapping to `NSColor` lives in `cc-timer`. That
  keeps the library reusable for Phase 2 (iOS/watchOS, a different renderer).
- `AppLogger` gains a fourth category, `ui` (idle↔expanded mode transitions). Drawing is not logged
  (too high-frequency); no secrets touch this layer.
- `MenuBarMode` is ready to gain `.error` in #12 without changing the existing branches.
- The mock snapshot in `AppDelegate` is temporary; #13 replaces it with live `Keychain → UsageClient`
  polling, leaving `StatusItemView`/`MenuBarLayout` untouched (they already take a finished
  `UsageSnapshot`).
- If Phase 2 renders through SwiftUI or another framework — `MenuBarLayout` is reused as is, and a new
  thin shell replaces `StatusItemView`; that is a new decision → a new section here or a separate ADR.
