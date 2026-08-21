---
status: accepted
date: 2026-08-04
---

# ADR-0069: The Settings window — height-resizable, vertical zoom, a validated persistent frame

> **Postscript ([ADR-0088](0088-settings-hosting-safe-area-and-manual-separator.md), 2026-08-13).**
> Two clarifications. (1) §2's claim, "below this bound the grouped `Form` scrolls on its own
> (verified live at a height of 300 pt)," described the build **before**
> [#311](https://github.com/artem-from-ua/tokenpace/issues/311): the toolbar added there, with
> `.fullSizeContentView`, triggered a safe-area propagation bug (rdar://122947424), and the pane's
> scrolling broke silently —
> [#346](https://github.com/artem-from-ua/tokenpace/issues/346). (2) The height minimum was
> lowered 480 → **470** — the measured minimum of System Settings (via the window server, window
> squeezed all the way down); the "historical first fixed height" turned out to be taller than the
> system one. The enforcement mechanism (§3, `windowWillResize`) is unchanged.

## Context

The Settings window's height was fixed and grew **by hand**: 480 → 520 (#199) → 560 (#211) → 600
(#215) → 636 → 684 → 776 (#224) → 720 (#224) → 732 (#224). Every new option in Appearance meant
another bump to the constant and another round of checking that all five panes still fit. This is
the same class of problem ADR-0040 §1 calls hardcoding — just with a manual maintenance loop
instead of a single number.

The HIG argument that ADR-0035/0042 used to justify the fixed size ("a settings window
accommodates the size of the current pane") works well for System Settings, where the pane
already takes up most of the screen. We have five panes of very different heights: the tallest
(Appearance, 11 control groups) dictates the size for everyone, and General, with two toggles,
opens with a large empty field. On a small screen a 732 pt window is already awkward.

Width is a different story. 857 pt was measured from a live System Settings (#156), and the
sidebar/detail split (258 / 599) is tuned specifically for it; a horizontal resize would drift the
split. So width remains a matched constant.

Frame persistence was **deliberately removed** (the postscripts of ADR-0035 and ADR-0020) for two
reasons: (1) `center()` was computed at zero width **before** `setContentSize`, which pushed the
window off-screen; (2) a saved frame survives a display-configuration change, and AppKit never
revalidates a restored frame against the current layout. Reason (1) was fixed back then (the
"size → position" ordering has held ever since); reason (2) still stands and hasn't gone anywhere.

## Decision

**1. Resizable by height only.** `.resizable` and `.miniaturizable` are added to `styleMask` (the
traffic lights are drawn as a group — showing a zoom button next to a hidden minimize would leave
a hole). Width is pinned at 857; height is free upward from 480 pt.

**2. `480` as the minimum — not a new number:** it's the historical first fixed window height, and
the existing `SettingsRootView.minHeight`. The controller passes both bounds into the view
explicitly, so they can't drift apart. Below that bound the grouped `Form` scrolls on its own
(verified live at a height of 300 pt: both the detail pane and the sidebar scroll, and content is
never clipped).

**3. The width pin is held by `windowWillResize`, not size limits.** This is forced, and the
reason is measured: `NSHostingController`, while hosting the SwiftUI tree, wipes **all**
constraints during its **first layout pass** (after the window is already shown) — both
`contentMinSize`/`contentMaxSize` and the frame-level `minSize`/`maxSize`, leaving `0×0 …
∞×∞`. So any pin set in `init` doesn't survive. `windowWillResize` is authoritative: AppKit asks
it before every resize, no matter who initiated it (dragging, Accessibility, a window manager) —
whereas AppKit applies size limits only to a user-initiated drag. The limits are still set anyway
(they declare intent and cut off some programmatic paths) and re-set on
`windowDidBecomeKey`, after that layout pass.

**4. The green button means vertical zoom, not full screen.** `windowWillUseStandardFrame`
returns `(x: current, y: defaultFrame.y, width: current, height: defaultFrame.height)`. The
`defaultFrame` AppKit provides is already the target screen's `visibleFrame`, so no manual
`NSScreen` lookup is needed. The toggle behavior (a second click → the previous size) is handled
by `NSWindow.zoom(_:)` itself. Full screen is explicitly disabled (`.fullScreenNone`): a
`.floating` window on an accessory app (ADR-0012 §6), in its own Space, conflicts with an active
full-screen window — the same conflict that made ADR-0020 remove `.floating` from Troubleshoot;
here we keep the window level and drop full screen instead.

**5. The frame is persisted under its own key, not via `setFrameAutosaveName`.**
`PersistedConfig.settingsWindowFrame` stores `[x, y, width, height]` as plain `Double`s (the file
stays AppKit-free). Autosave wasn't rejected on ADR-0023 grounds — that ADR actually says autosave
is system state and doesn't conflict with the config — but because autosave **restores the frame
before** it can be validated: inserting validation would mean either rewriting an already-applied
frame (a visible flicker) or parsing AppKit's undocumented string format.

**6. Validation — a pure function in the Kit.** `WindowFrameValidator.resolve(stored:visibleFrames:
defaultSize:minimumSize:)`, operating on the framework-free `WindowFrameBox` (`Double`, not
`CGRect`: the Kit has neither a CoreGraphics nor an AppKit dependency, ADR-0009). It rejects (→ a
centered default): a missing frame, an empty screen list (a real state during display
reconfiguration), non-finite values, a size below the minimum, a frame that intersects no screen,
and a frame that shows less than a 120×44 pt strip of titlebar. It repairs (→ restore): a height
taller than the screen (clamped), an out-of-bounds position (shifted onto the host screen — the one
with the largest intersection), and a saved width (normalized to the current constant). The line
is deliberate: "can't be reached with the mouse" is unrecoverable, "too big or hanging off a bit"
is recoverable. The frame↔content conversion happens at the boundary, so the validator compares
like-for-like quantities.

**7. `show()` no longer resets geometry.** All the geometry lives behind a one-shot
`hasBeenPositioned` gate, and inside it the order is unchanged: **size → position** (`setFrame`
atomically in the restore branch; `setContentSize` → `center()` in the default branch). This is
what ADR-0035 fixed, and it must not be broken again.

## Consequences

- `Metrics.contentHeight` → `defaultContentHeight` + `minContentHeight`. The chain of manual bumps
  is broken: a new Appearance option no longer **requires** a bump; one is made only to keep the
  default opening size comfortable.
- **A known cosmetic limitation: the ↔ cursor still shows on the side edges** — the window offers a
  horizontal resize that `windowWillResize` silently rejects. AppKit has no built-in way to drop
  that cursor for a single axis: `resizeIncrements`, both pairs of size limits, and the styleMask
  were each checked separately, and none removes it. Apple's own Settings window pins its width the
  same way (verified via Accessibility: a "+300 to width" request returns 857 unchanged, while
  height changes), so it most likely uses a private path. Tracked as a separate ticket.
- `SettingsWindowController` adopts `NSWindowDelegate` for the first time (the second case in the
  project after `DevToolsWindowController`), and the project gets its first use of `NSScreen`.
- `PersistedConfig` gets its first **geometry** key — a deliberate exception to the "config ≠
  system state" boundary (ADR-0023), justified in Decision §5.
- `TokenPaceKit` gets its first type with geometry (`WindowFrameBox`) — deliberately built on
  `Double` so as not to pull in CoreGraphics and to keep the Kit suitable for Phase 2 (iOS/watchOS).
- **The Insights window is deliberately left untouched.** `InsightsWindowController` has the same
  flaw (resets its size on every show), but it's still a placeholder (#242): its default size and
  minimum will change along with the charts (#244/#245). `WindowFrameValidator` is public and
  reusable — at that point it'll be a single call.
- Verification stays visual (there are no UI tests): the validator's pure logic is covered by 19
  unit tests in the Kit, the rest is screenshots in both themes.

## Related

- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — the pure core / thin shell split
  (why the validator lives in the Kit).
- [ADR-0012](0012-configure-window-and-launch-at-login.md) — `.floating` for the accessory window
  (kept).
- [ADR-0020](0020-troubleshoot-window-and-diagnostics-pipeline.md) — the same postscript about
  autosave; the `.floating` ↔ full-screen conflict.
- [ADR-0023](0023-persisted-config-version-marker.md) — the "config ↔ system state" boundary.
- [ADR-0035](0035-settings-window-sidebar-grouped-inset.md) — the origin of "always centered"
  (partially revisited).
- [ADR-0040](0040-native-system-metrics-no-hardcoded-ui.md) — "zero hardcoding"; §1 on the fixed
  window (partially refined).
- [ADR-0042](0042-settings-swiftui-form.md) — the SwiftUI rewrite; the clause on window geometry
  (partially revisited).
- [system-settings-parity.md](../reference/system-settings-parity.md) — the table of system
  mechanisms.
