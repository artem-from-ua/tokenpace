---
status: accepted
date: 2026-08-13
---

# ADR-0088: The Settings detail pane — safe area is cut at the hosting boundary, the toolbar rule is driven by the controller

> Refines [ADR-0069](0069-settings-window-height-resizable.md): the minimum height 480 → 470, and
> §2 ("scrolling was verified live at 300 pt") described a build predating
> [#311](https://github.com/artem-from-ua/tokenpace/issues/311) — the toolbar added there, with
> `.fullSizeContentView`, triggered the safe-area propagation bug, and the pane's scrolling broke
> unnoticed.

## Context

[#346](https://github.com/artem-from-ua/tokenpace/issues/346): a Settings pane taller than the
window **got clipped at the bottom instead of scrolling** — no scrollbar appeared, the scroll wheel
gave rubber-banding. The ticket's hypothesis (`.frame(minHeight:)` on the `NavigationSplitView`
root) was disproved arithmetically before any code: at the default 732 pt, the 480 floor is inactive
(`max(732, 480) = 732`), yet the bug reproduced exactly there.

The real cause came from **measuring the live tree, not from theory**: the first SwiftUI descendant
of the hosting controller — `PlatformViewHost<NavigationSplitRepresentable>` — laid out at
**496 pt inside a 470 pt window** (+26 = half of the toolbar's 52 pt safe area) at any window
height. Everything below it inherited 496: the tail of every pane and the scroller's bottom 26 pt
hung past the window's edge, unreachable. This is a confirmed Apple bug in safe-area propagation
into a `NavigationSplitView` detail column under `NSHostingController` — rdar://122947424,
confirmed by an Apple Frameworks engineer in
[thread 746611](https://developer.apple.com/forums/thread/746611).

Side findings made along the way to the fix, each backed by its own measurement:

- **The toolbar separator line** above the detail column drew constantly, even while scrolled all
  the way to the top. `NSTitlebarSeparatorStyle.automatic` does not bind to the bridged scroll
  view — measured in **two** configurations: with the bridge's insets untouched
  (`automaticallyAdjustsContentInsets = false`, 52 pt inset) and with it forced back to `= true`.
  The line does not react to scrolling in either case. The sidebar column (`List`, auto=true)
  behaves correctly — that very contrast is what first led down the false trail of "just set auto
  back."
- **The first card sat at ~70 pt** against the system's 52 (measured in #311): a grouped `Form`
  carries **18 pt of its own inset inside the document** (measured from card positions;
  `defaultMinListHeaderHeight` has no effect — checked). No public API removes those 18 pt.
- **The minimum height** of 480 was higher than the system's. The real minimum for System
  Settings, taken from the window server (`CGWindowListCopyWindowInfo`) with the window squeezed to
  its limit, is **857 × 470**. Frame ≡ content in both windows (`.fullSizeContentView`: the title
  bar overlaps the content rather than adding to it); the earlier estimate of "443," taken from a
  screenshot, was wrong precisely because it subtracted a title bar that doesn't exist.

## Decision

**1. `hosting.safeAreaRegions = []` — the root fix.** SwiftUI no longer receives the window-chrome
safe area, and the bridge lays out exactly into the window (measured: a 470 split inside a 470
window, at every height). The column keeps its own inset under the toolbar — the bridge takes it
from the window, not from this safe area (measured after the change: 52 in both the sidebar and the
detail column).

**2. The controller drives the separator line.** The system rule — none at rest, a hairline the
moment content slides under the toolbar — is implemented directly: a `boundsDidChangeNotification`
observer on the clip view toggles `NSSplitViewItem.titlebarSeparatorStyle` between `.none` and
`.line` (`SettingsWindowController.driveDetailTitlebarSeparator()`). Re-hooked on every pane change,
because switching panes rebuilds the scroll view — the same discipline as in `pinSidebarSplit()`.

**3. The first card sits at 52.** `.contentMargins(.top, −18, for: .scrollContent)`: inset
52 − 18 = 34, plus the document's own 18 pt inset = 52. The number is instrumented, not eyeballed.

**4. Minimum height 470** — the measured system value. Enforcement is unchanged —
`windowWillResize` ([ADR-0069 §3](0069-settings-window-height-resizable.md)).

**Rejected levers** — all measured; the table exists so they don't get tried a second time:

| Lever | Measured outcome |
|---|---|
| remove/shrink `.frame(minHeight:)` on the root | `docH` unchanged — the ticket's hypothesis doesn't hold |
| a `VStack` wrapper around the detail column | inset 32→52, `docH` unchanged |
| `.frame(maxHeight: .infinity, alignment: .top)` | `docH` unchanged |
| `.padding(.top, −20)` on the pane | shifts the whole pane along with the scroll view — the scroller's top gets clipped |
| `.safeAreaPadding(.top, −20)` | clamps to zero, a no-op |
| `.contentMargins(.bottom, N)` / `.safeAreaPadding(.bottom, N)` | stretches the scroll view itself N points below the window — the scroller's bottom hangs past the edge (measured: −26 overhang) |
| `sizingOptions = [.minSize]` | the window hits a floor equal to the tree's ideal size (522) — shrinking below that becomes impossible |
| forcing `automaticallyAdjustsContentInsets = true` | the insets are still the same 52, the separator line is still constant |
| `defaultMinListHeaderHeight` | has no effect on the document's 18 pt |

## Consequences

- `SettingsWindowController` gets a fourth bridge patch (`driveDetailTitlebarSeparator`), alongside
  `pinSidebarSplit` / `claimDividerCursor` / `mergeSidebarTitlebarStrip` — all of this is the price
  of a `NavigationSplitView` inside an `NSHostingController`. The tally keeps growing; if a fifth
  one becomes necessary, it's worth weighing a native `NSSplitViewController` with two hosted
  columns instead of the bridge.
- The detail column's insets **must not be touched** with SwiftUI modifiers beyond the top-margin
  one mentioned above: any `.padding` / `.safeAreaPadding` / `.contentMargins(.bottom, …)` breaks
  the scroller's geometry — see the table.
- `safeAreaRegions = []` means the Settings window's SwiftUI tree sees no safe area at all. If
  content that relies on it ever shows up (a bottom bar, an overlay above the toolbar), the inset
  will have to be supplied explicitly.
- The automatic separator (`.automatic`) is unusable for this window by construction; any future
  revisit must either keep the manual driver or prove by measurement that `.automatic` actually
  bound.
- Verification scenario — [ui-verification.md](../guides/ui-verification.md#detail-pane-scrolling-toolbar-rule-minimum-height-346);
  the method for diagnosing bugs like this —
  [agent-workflow.md § "Diagnosing window layout bugs"](../guides/agent-workflow.md#diagnosing-window-layout-bugs).

## Related

- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — pure core / thin shell (why the window is an AppKit shell).
- [ADR-0042](0042-settings-swiftui-form.md) — SwiftUI `Form` + `NavigationSplitView` (the bridge patched here).
- [ADR-0069](0069-settings-window-height-resizable.md) — resizable height; §2 and the minimum are refined by this ADR.
- [ADR-0077](0077-settings-toolbar-segmented-back-forward.md) — the toolbar whose safe area is the trigger.
- [#346](https://github.com/artem-from-ua/tokenpace/issues/346), [#311](https://github.com/artem-from-ua/tokenpace/issues/311).
- [Thread 746611](https://developer.apple.com/forums/thread/746611) (rdar://122947424).
