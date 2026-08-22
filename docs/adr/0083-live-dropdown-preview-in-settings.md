---
status: accepted
date: 2026-08-12
superseded_by: [0099]
---

# ADR-0083: A live dropdown preview next to the Settings window

> The "Visible in every section" section was superseded by
> [ADR-0099](0099-appearance-nests-its-two-surfaces.md): the preview is now tied to the pane
> (`Appearance` and its two children), not just to the window's openness, and `occupiedWidth` returns
> **0** while it's hidden. The rest of the decision — a separate borderless child window, the shared
> `PopupLayout`, the ⌥ monitor, the menu material, the parking — stands in full.

## Context

The `Appearance` / `Appearance › Menu bar` / `Appearance › Dropdown`
([#333](https://github.com/artem-from-ua/tokenpace/issues/333)) panes configure what the dropdown
draws: `Bar style`, ticks, `Show model & service limits`, `Show extra usage`, presets. But **seeing the
result while flipping toggles is impossible**: the dropdown lives in the status item's `NSMenu`, and a
menu can't stay open while the user is working in the Settings window. So the one surface being
configured here is the one you can't see.

The verification loop looked like this: flip a toggle → close Settings → open the dropdown → look →
go back. On every iteration.

The mechanics of "draw the popup outside the menu" already exist in the project — the color tuner's
preview ([#185](https://github.com/artem-from-ua/tokenpace/issues/185), `DevToolsWindowController`) —
but it's dev-only and deliberately incomplete: it doesn't proxy `optionHeld` or either visibility
handle.

## Decision

**A separate borderless child window next to Settings**, with its own `PopupViewController`, mirroring
the same `PopupLayout` the live dropdown uses.

### 1. A separate window, not a block inside the pane

The Settings window's width is pinned ([ADR-0069](0069-settings-window-height-resizable.md), which
holds `windowWillResize`), while the popup is a fixed 312 pt. An embedded preview would either crowd
out the detail column or require unpinning the width — walking back ADR-0069 for the sake of a
preview. A child window costs the layout nothing and rides along with its parent for free.

### 2. Shown the entire time Settings is open — not per section

The plan was originally to enable the preview on only three UI panes. Rejected: tying it to
`model.selection` would mean maintaining a registry of "which sections show the preview," kept in sync
with `SettingsSection` — and a whole class of "added a pane, forgot to add it to the registry" bugs.

Consequence: a future Guide/Legend page ([#261](https://github.com/artem-from-ua/tokenpace/issues/261))
gets the preview **with zero lines of code**.

### 3. Mirroring from one point

`AppDelegate.setPopupLayout` is the single place every popup change flows through: polling,
`reRenderForCurrentTime()`, the animation frame, every appearance callback, applying a preset
(`fireAppearanceCallbacks`). One line there covers everything — **none of the ~22 `openSettings`
callbacks had to be touched**.

The `lastPopupLayout` latch seeds a window opened **between** renders: those happen every 30 s
(`ageTimer`), and without the latch the card would sit empty.

Cold start isn't a problem: `setPopupLayout` is called with `PopupLayout.make(from: nil, …)` before the
menu is even assembled, so `layout` is never `nil` — the preview shows the same idle frame the
dropdown would show at that same instant.

### 4. A shared `ColorAnimator`, not its own

The preview gets the same instance the two live surfaces use. This is safe by construction:
`ColorTweenSet.update` only updates `touchedAt` when the target is unchanged, and `pruneStale` is
deliberately age-based — its doc comment states directly that a set-based prune "would let one surface
evict another's keys." So multiple surfaces on one registry is a design built into the architecture
([ADR-0070](0070-smooth-bar-colour-transitions.md)), not a hack.

A dedicated animator would mean a second 30 fps timer and visually desynchronized transitions across
two windows on the same screen.

### 5. ⌥ Option — a local monitor, not a timer

`PopupViewController.optionHeld` rebuilds sections. `NSMenu` uses a timer for this because menu
tracking spins a modal `NSEventTrackingRunLoopMode`, which starves monitors
([ADR-0020 §3](0020-troubleshoot-window-and-diagnostics-pipeline.md)). An ordinary window has no such
mode, so a monitor works fine.

A global monitor is **not** added — it requires Accessibility permission (a system prompt) just to
react to ⌥ while the user is looking at someone else's window.

`return event` in the monitor is mandatory: `nil` would swallow `.flagsChanged` for the entire process
and silently break ⌥ in the dropdown itself.

### 6. Background: the menu material, which fades along with focus

Active window — a plain `.menu` / `.behindWindow`, just like a real dropdown (the popup card draws
with partial alpha and expects material underneath it).

Inactive — the material turns off (`state = .inactive`), and an opaque backing shows instead.
Transparency in macOS signals "this surface is alive"; a preview you can see the wallpaper through
while no one is using it competes with the window that has focus.

Two traps, both of which cost iterations:

- **The backing must be a separate view under the material.** Drawing `layer.backgroundColor` on the
  `NSVisualEffectView` itself takes away the layer it renders its blur through — the result is
  transparency **with no blur**.
- **Corners are rounded with `maskImage`, not `cornerRadius`.** `NSVisualEffectView` composites its
  material past the ordinary layer path, so `cornerRadius` + `masksToBounds` only clips the subview —
  square material with a rounded frame inside it.

The inactive-state color is `NSColor.previewInactiveBackground`: in dark mode this is
`underPageBackgroundColor`, which resolves to exactly `#282828`; in light mode the same constant gives
`#969696` at α 0.9 (too dark for the card), so the light branch takes `windowBackgroundColor`. Both
values are **measured** by resolving under each appearance, not assumed.

### 7. No footer with mock rows

The dev preview has two mock update rows with colored dots — they exist to expose those two colors to
the tuner. Here they would read as a fake notification the user would take for a real one.

### 8. The sidebar narrowed, and the window along with it

Sidebar 275 → **210** pt: seven short labels don't need the room System Settings reserves for its
longer list. The window's width was reduced by exactly the same difference (857 → **792**), so that
**the detail column stays the one the panes were laid out for**. Changing one without the other would
silently change the width of every pane.

### 9. The sidebar divider: width by constraint, cursor by isa-swizzling the delegate

Width is held by a hard Auto Layout constraint on the sidebar's view. No lighter lever worked, and
that's worth recording so the next session doesn't walk the same loop:

| Attempt | Result |
|---|---|
| `.navigationSplitViewColumnWidth` | unreliable for a `.sidebar` List (measured: 307 pt for a 259 request) |
| `.frame(width:)` alone | doesn't scale — snaps between a handful of states (200→307, 240→243, 340→243) |
| `NSSplitView.delegate = …` | **an exception**: *"A SplitView managed by a SplitViewController cannot have its delegate modified"* |
| `NSSplitViewItem.min/max/canCollapse` | accepted, then SwiftUI reapplies its own; has no effect on the cursor |

**The ↔ cursor is a separate mechanism.** Established through instrumentation (logging
`addCursorRect` via a swizzle): `-[NSSplitView resetCursorRects]` sets a cursor rect
`(sidebarWidth, 0, 5, H)` with `resizeLeftRight`, taken from the delegate's
`splitView:effectiveRect:forDrawnRect:ofDividerAtIndex:`. Returning `.zero` there removes the zone
entirely (zero calls to `addCursorRect`), along with the drag zone.

Cursor rects are geometry registered **with the window**: they don't go through `hitTest` and have no
z-order. So an overlay on top with its own cursor rect / `NSTrackingArea` could never win in
principle — checked, didn't work.

The delegate is SwiftUI's `NavigationSplitViewController`, a genuine `NSSplitViewController` subclass.
It can't be replaced, but its method can be overridden by moving **one instance** into a generated
subclass (`objc_allocateClassPair` + `object_setClass`).

Deliberately an **isa-swizzle of one object**, not a method swizzle on `NSSplitView`: nothing outside
this window is touched. The split itself can't be touched — it's already
`NSKVONotifying_NSSplitView`, and an isa-swizzle would break its KVO. The private class's name is
nowhere hardcoded (the class is read off the live delegate), so a rename in a future macOS degrades to
a cosmetic flaw rather than a break.

## Consequences

- **+** Dropdown settings finally have feedback: the result is visible the moment you flip a toggle.
- **+** Guide/Legend gets a preview for free.
- **+** The dev preview picked up a theme-change fix: a shared `PreviewChrome` now holds the
  Vibrant appearance and the corner radius, and the title pill became plain text in both.
- **−** The Vibrant appearance has to be **reassigned on every show**, not just on the event. The
  window outlives its own visibility (`isReleasedWhenClosed = false`), while the KVO on
  `NSApp.effectiveAppearance` only lives between `attach(to:)` and `detach()`. So a theme change
  **while Settings is closed** never reaches anyone, and the window stays in whatever vibrancy it last
  had patched in: a preview built at night still draws dark in the morning. The same applies to the
  dev tuner's preview, which is built once and shown many times. Both now reassign the appearance at
  the moment of showing.
- **−** An isa-swizzle of a private SwiftUI class showed up in the code. Scoped to one instance,
  idempotent, the class name isn't hardcoded — but it's a dependency on SwiftUI's internal structure,
  and it needs a live check on every macOS update.
- **−** Two surfaces now draw the popup (the live one + the preview). Thanks to the shared animator and
  the single mirroring point this doesn't double the work, but every new `PopupViewController` handle
  now has to land in `syncPresentation()` too.
- **−** The sidebar's width and the window's width are now linked manually: changing one without the
  other silently relays out the panes.

## What was deliberately not done

- **No "show preview" toggle.** It would drag in a key in `PersistedConfig`, a field in
  `AppearanceConfigExport`, and a column in `AppearancePreset` for a fact that's entirely derived from
  "Settings is open."
- **State is not persisted** — the window is borderless, can't be closed on its own, so there's
  nothing to remember.
- **`onToggleSubscription` isn't wired up** — the preview is a mirror, not a second control surface.
  The subscription row draws (it's in the layout), but clicking it does nothing.
- **No menu bar strip in the preview** — the content deliberately mirrors the dropdown; the menu bar
  is already visible on screen anyway.
