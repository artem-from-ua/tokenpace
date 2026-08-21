---
status: accepted
date: 2026-07-25
superseded_by: [0040, 0042, 0069]
---

# ADR-0035: Settings window — sidebar navigation and grouped-inset cards

> **Partially revised by [ADR-0040](0040-native-system-metrics-no-hardcoded-ui.md) (#156):** a pass
> for parity with System Settings refined the card and metrics *implementation*: a manual
> `controlBackgroundColor` fill (which gave a purely white card) was replaced with a dynamic grouped
> color (242/43 light/dark), plus a material and measured row-height/corner-radius, sidebar icons at
> the system size, `NSStackView.firstBaseline` alignment, an `NSPathControl` for the path. The overall
> structure (sidebar + grouped-inset cards, eager build, the `AppDelegate` contract) still stands;
> this ADR's body is historical.
>
> **Further revised by [ADR-0042](0042-settings-swiftui-form.md) (#168):** the *implementation* was
> rewritten from manual AppKit (`SettingsCard`/`NSSplitViewController`/source list) to SwiftUI
> `Form.formStyle(.grouped)` + `NavigationSplitView` via `NSHostingController`; the eager build was
> removed (state now lives in `@Observable SettingsModel`). **The public `AppDelegate` contract and
> sidebar navigation as an idea remain** — only the rendering approach changed. `NSSwitch`/radio
> mentions in the body below are historical (now SwiftUI `Toggle`/`Picker`).

## Context

The Settings window (issue #14, ADR-0012) started as a single flat vertical `NSStackView` inside an
`NSScrollView`: sections separated by bold headers and `NSBox` dividers, all controls left-aligned
checkboxes. Over several releases it accumulated options (#89 monitored services, #103 reset
countdown, #105 calm colors, #110 session logs, #114 pause-on-lock, #37 updates) and turned into a
long scroll across six sections.

Two problems:

1. **It doesn't scale.** Every new option lengthens the single scroll; navigating it gets harder, and
   more options are still ahead (#130, etc.).
2. **It doesn't look native.** Modern macOS System Settings (Ventura+) uses sidebar navigation and
   grouped-inset cards, not flat sections with horizontal rules.

The maintainer asked for a redesign following System Settings guidelines, with a sidebar section
picker (since the number of options keeps growing) and native group styling.

## Decision

Rewrite the window as an **`NSSplitViewController`**: a sidebar list of sections on the left + a
detail pane of grouped-inset cards on the right.

1. **Sidebar** (`SettingsSidebarController`, a source-list `NSTableView`) — 5 items with colored
   SF Symbol chips: **General**, **Menu Bar**, **Monitored Services**, **Session Logs**, **About**.
   Small sections were merged: the former **Updates** was folded into **About**. Items scale with
   growing options where a single scroll didn't.

2. **Grouped-inset cards** (`SettingsCard`) — AppKit has no native rounded container matching Sequoia,
   so a card is a layer-backed `NSView`: a `controlBackgroundColor` fill on the window's
   `windowBackgroundColor` background, a 10 pt `cornerRadius`, inset hairline dividers (`DividerView`,
   `separatorColor`, height `1/backingScaleFactor`) between rows. Since `CGColor` is **not** dynamic,
   the fill and dividers are reset in `updateLayer()` (with `wantsUpdateLayer`), which AppKit calls on
   every appearance change — so dark/light mode stays correct.

3. **`NSSwitch` instead of checkboxes.** Toggle controls became `NSSwitch` on the right edge of a row
   (as in System Settings). Radios stay radios (exclusive choice, not a toggle). Since `NSSwitch` has
   no title/subtitle, all hints and the gray "always monitored" marker are separate labels in the row.

4. **Panes are built eagerly, not lazily.** `updateAvailability(_:)` and `updateArchiveStatus()` are
   called from background poll completions while the window is closed; a lazy pane would give a nil
   outlet. `SettingsSplitViewController.buildAllPanes()` materializes all 5 panes at once in `init`.

**Preserved verbatim** is the public contract that `AppDelegate.openSettings` depends on: 8
`on…Change`/provider callbacks + `updateAvailability(_:)` + `updateArchiveStatus()` + `show()`. All
the sync-on-show logic, conditional enablement (WEB/Desktop mode radios ↔ switch; "include distant
7d" ↔ the smart radio; archive buttons ↔ enabled+folder), the exclusive reset-countdown group (4
modes ↔ 3 radios + 1 nested checkbox), and the live `SMAppService` launch-at-login logic (with a
collapse-on-empty hint, the `isAppBundle` gate, rollback on failure) were carried over with no change
in behavior. No log message changed.

The window remains single-instance (`isReleasedWhenClosed = false`), `.floating`-level (pops up over
a menu-bar app with no Dock icon, ADR-0012 §6), now resizable with `setFrameAutosaveName`; it centers
once on first display if autosave didn't restore a position.

> **Partially revised by [ADR-0069](0069-settings-window-height-resizable.md).** The decision below —
> "position persistence deliberately removed" — is **canceled**: the frame is saved between launches
> again. Reason (1) — going off-screen through `center()` at zero width — was fixed here already and
> stays fixed (size is always set **before** position). Reason (2) — AppKit doesn't re-validate a
> restored frame against the current display layout — is confirmed as still true, and that's exactly
> why persistence comes back **together with** explicit validation: a pure `WindowFrameValidator` in
> `TokenPaceKit` checks the saved frame against the live `NSScreen.visibleFrame` and discards it (→ a
> centered default) if it doesn't fit any screen. The rest of ADR-0035 still stands.

> **Postscript (a fix for the off-screen position).** The window **no longer** saves/restores its frame
> between launches (`setFrameAutosaveName` was removed) — it **always opens centered** on the
> session's first display. Two reasons: (1) the root cause of the off-screen bug — the
> `NSHostingController` content had no intrinsic size, so on first display the window was still zero
> width; `center()`, computed for zero width, put the left edge near the screen's center, and the
> subsequent expand to 857 pushed the right half off-screen. Now `setContentSize(857×480)` is called
> **before** `center()`, so centering is correct. (2) The saved frame was also unreliable on its own —
> it survives display configuration changes (a disconnected monitor, a different resolution/scale)
> and would open the window off-screen, and AppKit doesn't re-validate a restored frame against the
> current layout. Centering is always within the screen and needs no validation, so position
> persistence was deliberately removed.

### Alternatives considered

- **Top tabs (toolbar tabs)** — a valid pre-Ventura style, but the maintainer chose sidebar
  specifically for better scalability as options grow.
- **Grouped-inset with no navigation** (a single scroll of cards) — doesn't solve the scale problem.
- **`NSBox` `.custom` for the card** — its rounding is a legacy mechanism and doesn't match Sequoia;
  the radius would still need manual adjustment, so a layer-backed `NSView` is simpler.

## Consequences

- The window looks like a System Settings pane; adding a new section = adding one `Section`
  descriptor (title + SF Symbol + tint + builder), with no lengthening of the scroll.
- Three new types in the shell: `SettingsCard`/`DividerView`/`FlippedView` (`SettingsCard.swift`),
  `SettingsSplitViewController`, `SettingsSidebarController`. `SettingsWindowController` now hosts the
  split VC instead of a flat stack.
- `SettingsRow` centralizes row builders (switch row, button row, label+hint, link), so new rows are
  consistent in padding and behavior.
- Corner radius (10 pt) and divider inset (~14 pt) are undocumented by Apple, tuned by eye; may need
  correction on future macOS releases.
- This is a UI redesign with no change to the data model: `PersistedConfig` keys, Kit tests (593, all
  green), and logging are untouched. ADR-0012 remains a historical record (a separate window, opt-out,
  best-effort on unsigned — all still stands); only the window's **presentation** changed, so no
  formal supersession is added — this ADR complements 0012 along the layout axis.
