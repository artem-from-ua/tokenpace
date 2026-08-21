---
status: accepted
date: 2026-07-27
superseded_by: [0069]
---

# ADR-0042: The Settings window — SwiftUI Form.grouped instead of hand-drawn AppKit

> **Partially revised by [ADR-0069](0069-settings-window-height-resizable.md):** §4's clause about
> window geometry ("857×480 fixed … hidden zoom/miniaturize") no longer stands — the window is now
> **resizable in height** (the 857 width stays pinned), zoom and miniaturize are **shown**, the green
> button stretches vertically, and the frame is persisted with validation against the current screen
> configuration. In the process it turned out `NSHostingController` clobbers all of a window's size
> constraints during the first layout pass, so the width pin is held by `windowWillResize`, not
> `contentMinSize`/`contentMaxSize`. The rest of the decision (the SwiftUI `Form.formStyle(.grouped)`,
> `NavigationSplitView`, `@Observable SettingsModel`, the verbatim-preserved
> `AppDelegate.openSettings` contract) still stands.

## Context

ADR-0035 rewrote the Settings window as a sidebar plus grouped-inset cards, implemented **by hand
in AppKit** (`SettingsCard`/`SettingsRow`/`RoundedFieldBox`/`DividerView`, a source-list
`NSTableView`). The parity pass #156 (ADR-0040) proved out this approximation of System Settings
with **measured** constants (row 37 pt, corner 4 pt, inset 12/11 pt, divider inset 10 pt, hairline
0.5 pt — see [system-settings-parity.md](../reference/system-settings-parity.md)).

This works and is close to the system look, but has the root flaw ADR-0040 named outright (§4):
AppKit has **no** grouped-inset container (`NSTableViewStyle.insetGrouped` is iOS-only; `NSBox`
only gives you `.custom`, which is hand-drawing all over again). System Settings renders its cards
via SwiftUI `Form { Section }.formStyle(.grouped)` (verified: both the shell and the pane
extensions link SwiftUI). So our constants:

- can drift from future macOS versions (they're a snapshot of one System Settings version);
- are not a "system default" but a reverse-engineered approximation;
- contradict ADR-0040's core principle — "zero hardcode for system elements."

ADR-0040 §4 already **explicitly authorized** the eventual fix: rewrite the panels as a SwiftUI
Form via `NSHostingView`, "for now keep AppKit hand-drawing (lower risk, phased)." This ADR
records the decision to carry out that transition (#168).

## Decision

**1. The Settings window's detail panels and sidebar are rewritten in SwiftUI**, embedded in the
existing `NSWindow` via `NSHostingController`. `Form { Section }.formStyle(.grouped)` gives row
height, padding, corner radius, dividers, and card spacing from **system defaults** — zero
constants. Sidebar → `NavigationSplitView` + `List(.sidebar)` (replacing the source-list
`NSTableView` + custom chip). This is the project's first SwiftUI foothold (previously pure
AppKit); the `.macOS(.v15)` target + Swift 6.1 make `@Observable` and a modern SwiftUI Form
available with no `Package.swift` changes.

**2. State lives in an `@Observable SettingsModel`, outside the SwiftUI view.** Previously state
lived in AppKit outlets, which made **eager building** of every panel unavoidable: background
callbacks (`updateAvailability`/`updateArchiveStatus`, from poll completions while the window is
**closed**) touched outlets → a nil crash under lazy construction. Now these methods mutate a model
that lives as long as `SettingsWindowController` does — so eager building is **removed**, and the
SwiftUI panels build lazily with no risk. This is both a simplification and a preserved invariant.

**3. The public `AppDelegate.openSettings` contract is preserved verbatim.** `SettingsWindowController`
becomes a thin hosting wrapper: the same 10 closure properties + `archiveSummaryProvider` +
`updateAvailability(_:)` + `updateArchiveStatus()` + `show()` + `convenience init()`, now forwarded
into `SettingsModel`. `App.swift` (the contract wiring + background call sites) is **not changed by
a single line** — this is the refactor's central protective invariant. Every setter on the model
preserves the **persist-then-callback** order (`PersistedConfig` first, then `onXChange?`), matching
today's `@objc` actions; a resync on `show()` is guarded by `isSyncing` against re-triggering
callbacks.

**4. Tricky AppKit spots are bridged, not blindly rewritten:**
- "Choose…" for the archive folder → an imperative `NSOpenPanel().runModal()` inside a model
  method (preserving the `prompt`/`message`/seed-`directoryURL` and the "toggle-on with no
  destination → prompt immediately" behavior); `.fileImporter` doesn't offer a prompt/message.
- The allowed-hours time → `DatePicker(.hourMinute)` via a `Binding<Date>`↔minute-of-day adapter
  (`date(fromMinuteOfDay:)`/`minuteOfDay(from:)` carried over verbatim), replacing the bezelless
  `NSDatePicker` in `RoundedFieldBox`.
- Suppress days → `Picker(.menu)` (sizes itself to the selection), replacing the `NSPopUpButton` +
  `resizeSuppressPopup()` width hack.
- The window (857×480 fixed, `.floating`, `isReleasedWhenClosed=false`, hidden zoom/miniaturize,
  width pin, `NSApp.activate`) — stays pure AppKit in the controller. The fixed width is held by an
  NSWindow pin (authoritative); inside it, `.navigationSplitViewColumnWidth(258)` sets the sidebar.

## Consequences

- **The card's table of measured constants disappears from the code and the docs.**
  `SettingsCard`/`SettingsRow`/`RoundedFieldBox`/`DividerView`/`FlippedView`/`SettingsColors`,
  `SettingsSplitViewController`, `SettingsSidebarController` (+`ChipView`/`iconMetrics`/the
  `AppleSideBarDefaultIconSizeChanged` observer) — **removed**. `system-settings-parity.md` loses
  the "Measured card metrics" table and the section on the grouped-inset exception (now supplied by
  the SwiftUI Form).  `SettingsWindowController` shrinks from ~1172 to ~90 lines.
- **Part of ADR-0035 and ADR-0040 is further revised:** the grouped-inset container, chip, and time
  picker are **no longer** manual AppKit exceptions — SwiftUI Form/List/DatePicker supply them from
  system defaults. The deliberate exceptions from ADR-0040 §3 (the menu-bar `StatusItemView`, the
  popup's pacing bars) still stand — they aren't System Settings elements.
- **Verification stays strict** (ADR-0040): any UI change — in both themes (light+dark) and every
  state (sidebar icon size is now the system List, dev build/`.app`) — with screenshots before a PR.
  Greenfield SwiftUI parity is proven precisely by screenshots side by side with System Settings.
- **There are no UI tests** (existing tests target only `TokenPaceKit`), so the model's pure logic
  (`ResetCountdownMode` ↔ radio+checkbox fold, minute-of-day↔Date, computed enablement) is factored
  into static functions and covered by new Kit unit tests.
- **`App.swift` is zero-diff.** `git diff Sources/TokenPace/App.swift` must be empty across the
  contract's scope.

## Related

- [ADR-0035](0035-settings-window-sidebar-grouped-inset.md) — the initial sidebar+grouped-inset
  redesign (its body is now history; this ADR completes the transition 0040 §4 foresaw).
- [ADR-0040](0040-native-system-metrics-no-hardcoded-ui.md) — the "zero hardcode" principle; §4
  authorized exactly this SwiftUI-Form transition.
- [ADR-0012](0012-configure-window-and-launch-at-login.md) — the floating-level accessory window
  (preserved).
- [system-settings-parity.md](../reference/system-settings-parity.md) — the measured constants this
  transition removes.
- Issue #168 (the rewrite), #156 (parity).
