---
status: accepted
date: 2026-08-11
supersedes: []
---

# ADR-0077: ‹ › in the Settings toolbar — one item, a separated NSSegmentedControl

## Context

Between ‹ and › in the Settings toolbar sat an 8 pt dead zone — a strip where the cursor didn't
highlight either button ([#314](https://github.com/artem-from-ua/tokenpace/issues/314)). System
Settings has no such zone. [#313](https://github.com/artem-from-ua/tokenpace/pull/313) exhausted four
approaches within the "two separate `NSToolbarItem`s" scheme — none removed the zone.

Instrumented probes on live windows (method: a synthetic cursor + pixel-diffing hover/no-hover
screenshots) established the facts that were missing:

1. **The generated `NSToolbarButton`'s hover zone is a painted pill, not the button's frame.** A
   40 pt button paints a 28 pt pill (width − 12), and a cursor position 1 pt outside the pill
   highlights nothing. So any pair of separate buttons leaves a dead strip between the pills — item
   size doesn't affect this (checked at 39/43.5/45/53; a stack with spacing −10.5 just overlaps the
   boxes, and both pills light up at once).
2. **A plain `NSButton` (`.toolbar` bezel + `showsBorderOnlyWhileMouseInside`) inside an item's
   custom view draws no hover pill at all** — the pill machinery lives in the private
   `NSToolbarButton`; it cannot be obtained outside toolbar generation.
3. **The SwiftUI bridge (`NSHostingController.sceneBridgingOptions = [.toolbars]`) places
   `.navigation` items above the sidebar**, right after the traffic lights: a `NavigationSplitView`
   inside a hosting controller does not register its columns with the bridge, so
   `sidebarTrackingSeparator` never gets inserted. This is the same boundary #156 already ran into
   with the title.
4. **An AX dump of live System Settings**: the pair is a single `AXGroup 76×52` node, containing a
   ~68×28 visual container and two adjacent `AXButton 40×40` hit zones (921..961..1001 — flush
   against each other). This is the geometry of a segmented control, not of two toolbar items.

## Decision

The ‹ › pair is **one `NSToolbarItem` whose view is an `NSSegmentedControl`** with
`segmentStyle = .separated`, `trackingMode = .momentary`, and two template chevrons
(13 pt medium `.large` — the configuration is set explicitly, because unlike a generated button, a
segment doesn't apply the toolbar's own image processing).

No manual sizing: the control self-sizes to 80×40, and the toolbar places it in a 76×52 slot — a
number-for-number match of System Settings' geometry from the AX dump. Enablement is two calls to
`setEnabled(_:forSegment:)` from `update(...)`, guarded against redundant writes.

## Consequences

- **There is no dead zone.** The 33×28 and 34×28 pills meet edge to edge (measured: 588..621 and
  622..656 screen pt — the boundary at 621|622); to the left of the seam ‹ lights up, to the right, ›.
  The center-to-center step of the glyph ink is **36.5 pt**, exactly the value measured in System
  Settings (it used to be 46.5).
- **A disabled segment** dims its own template glyph and draws no pill on its own — System Settings'
  behavior, with none of our code.
- **The workaround machinery from #312/#313 is dead**: walking the title bar in search of generated
  buttons, re-asserting `isBordered` after every validation pass, `NSToolbarItemValidation` with
  state in the controller, `minSize`/`maxSize` 45×34. The segmented control is our own view; the
  toolbar doesn't rebuild it, and it needs no validation (`autovalidates = false`).
- **The AX tree matches System Settings**: `AXGroup → AXGroup → 2×AXButton 40×40` with Back/Forward
  descriptions (from the images' `accessibilityDescription`).
- The pill size, slot, and step are now **the system's property**: they'll change with a new macOS
  release alongside System Settings, with no calibration of our own (the principle from
  [ADR-0040](0040-native-system-metrics-no-hardcoded-ui.md)).
- Limitation: a segmented control doesn't offer a separate "history on long-press" button (like
  System Settings' Forward `AXMenuButton`); TokenPace never had that feature anyway.
