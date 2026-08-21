# Matching the Settings window to macOS System Settings

> A reference for how TokenPace reproduces the look and behavior of the system's **System Settings**
> (macOS 15 Sequoia) — where AppKit gives it to us "for free," where it doesn't, and which mistakes
> NOT to repeat.
> Born out of the big pass #156 (redesign #131 → parity with System Settings).

## Product goal

**TokenPace must follow the interface design of native macOS apps as closely as possible.** Every
screen, window, and control should look and behave as if it were part of the system — the same look,
sizes, colors, fonts, spacing, and behavior as Apple's own apps (System Settings above all). The user
should never feel like this is a "third-party" app. This is the guiding principle for any UI work
here; everything below is about **how** to achieve that technically (and where it's hard, because
AppKit doesn't offer a native primitive).

## TL;DR (for anyone arriving here before touching the Settings UI)

1. **First check whether a system mechanism exists.** Historically, most of the "magic numbers" in
   Settings existed only because we were **drawing the grouped-inset look by hand**, instead of using
   a system container. Before picking a number, ask: "doesn't the system already give me this?"
2. **Settings detail panes now use SwiftUI `Form { Section }.formStyle(.grouped)`** (ADR-0042, #168)
   — same as System Settings itself. Row height/padding/corner radius/dividers are **system
   defaults, zero constants**. The measured card-metrics table that used to live here has been
   **removed** — it described `SettingsCard`, which no longer exists. AppKit still has no
   grouped-inset container — that's exactly why we moved to SwiftUI Form instead of tuning more
   numbers.
3. **Don't pick numbers out of thin air or "by eye."** If a constant is unavoidable, it must be
   **measured** from the live System Settings (AX `AXSize` / Retina screenshot ÷2), not guessed.
   Document where it came from.
4. **Check BOTH themes and ALL states.** Light **and** dark. Small/medium/large sidebar icon size.
   Dev build and `.app`. The most common cause of "this looks wrong" in this pass was checking only
   light and only one state.
5. **Don't diagnose blind.** Take a screenshot, compare it pixel-by-pixel with System Settings, and
   only then fix it. Every "blind" fix in this pass broke something else.

## Principle: system mechanisms, not hardcoding (ADR-0040)

For **standard system elements** — zero hardcoded sizes, fonts, spacing, colors. Use what AppKit
already provides:

| What | System mechanism | Do NOT do |
|---|---|---|
| Sidebar icon size | **exception: pinned to Large** (#335). Previously read `NSTableViewDefaultSizeMode` (`NSGlobalDomain`, 1/2/3=S/M/L) via `DistributedNotificationCenter` (`AppleSideBarDefaultIconSizeChanged`) — the mechanism worked, but it only followed the chip **size**: SwiftUI doesn't expose the column width (measured: `.navigationSplitViewColumnWidth(259)` → 307 pt; `.frame(width:)` doesn't scale at all — 200 → 307, 240 → 243, 340 → 243), and the row inset scales with list width (32.5 pt at Small vs. the system's 10) while `listRowInsets` can only **add** on top of a 20-pt floor. Following one axis out of several means matching the system on none of them | `effectiveRowSizeStyle` does **not** resolve `.large` for a source list — don't rely on it |
| Switch size | `NSSwitch.controlSize = .mini` (26×15 pt — exact match to System Settings) | not `.regular`/`.small` (too large) |
| Popup menu (dropdown) | `.flexiblePush` + `.small` + `showsBorderOnlyWhileMouseInside = true` (compact, borderless-at-rest) | not `.push`/`.automatic` (heavy blue border) |
| Fonts | `NSFont.systemFontSize` (13) / `NSFont.smallSystemFontSize` (11) / text styles | not raw `ofSize: 11`/`12` |
| Window **width** | **857 pt, fixed** (measured from System Settings), sidebar **fixed at 258** | don't make the width resizable — sidebar/detail (258/599) are tuned for it and would drift; don't make the sidebar dynamic "to fit the longest label" — System Settings doesn't do that either |
| Window **height** | **resizable** from 480 pt up, default 732 (ADR-0069). The width pin is held by `windowWillResize` — `NSHostingController` clears all size limits during the first layout pass. The green button is a **vertical** zoom; the frame persists with validation against `NSScreen.visibleFrame` | don't bump the fixed height by hand for every new Appearance option (that's how it was done before ADR-0069 — 480 → … → 732); don't enable full screen (a `.floating` window fights the full-screen Space, ADR-0020); don't rely on `contentMinSize`/`contentMaxSize` for enforcement |
| Window title | Title bar **has no text and is transparent** (`titleVisibility = .hidden` + `titlebarAppearsTransparent`), and the pane name is an item in **our own AppKit toolbar** (`SettingsToolbarController`, 15 pt semibold — measured pixel-for-pixel against the system, #311). This satisfies the HIG mandate to "display the selected section" (#156 §2) | don't leave text in the title bar (it would duplicate the pane name); do **not** put the name in a SwiftUI `ToolbarItem`: `.navigation` places it above the **sidebar**, next to the traffic lights (re-verified through the `sceneBridgingOptions` bridge in #314 — same result), `.principal` centers it over the whole window, and a trailing `Spacer` doesn't move it (the item shrinks to its intrinsic size) |
| Back/forward ‹ › buttons | **One** `NSToolbarItem`, view = `NSSegmentedControl` (`.separated`, `.momentary`, 13 pt medium `.large` template chevrons), with no manual sizing at all — the control assembles itself into 80×40, slot 76×52, 33/34×28 flush segments, matching System Settings ([ADR-0077](../adr/0077-settings-toolbar-segmented-back-forward.md)) | don't split the pair into **two** items: the hover zone of a generated `NSToolbarButton` is its own **pill** (button − 12 pt), so separate buttons always leave a dead zone between them (#314, exhausted in #313); don't put a plain `NSButton` in a custom view — outside toolbar generation it **doesn't draw** the hover pill at all |
| Material under the traffic lights | `styleMask` includes **`.fullSizeContentView`** — the split view extends to the full height, so the sidebar's vibrancy continues behind the title bar | without it, the strip above the sidebar draws the **window** background (measured 40,40,40 in dark) against the sidebar's own 70,70,70 — a visible seam right where the traffic lights are |
| Traffic-light position | an empty `NSToolbar` + **`window.toolbarStyle = .unified`**. There's no direct API for the traffic-light position — AppKit places it relative to the titlebar+toolbar height, so the toolbar itself is what supplies the right height. Measured on a reference System Settings screenshot: the red button's center sits at **(25.75, 25.75) pt** from the window origin, diameter 11.5 pt; our render matches to the pixel | don't leave the window without a toolbar — a bare `.titled` gives (13.5, 13.5) pt, i.e. the traffic lights sit ~12 pt higher and further left than the system's; **`.unifiedCompact` doesn't work either** — it gives (18.75, 18.75); don't move the buttons by hand |
| Row alignment | `NSStackView` `.alignment = .firstBaseline` + `edgeInsets` determine row height | don't center text manually via top/bottom pins (makes the text top-heavy) |
| Section symbols | exact matches from System Settings' `.appex Info.plist`: General=`gear` (not `gearshape`), Notifications=`bell.badge.fill`; weight `.regular`. For panes **without a system counterpart** (`Providers`=`puzzlepiece.extension.fill`, the UI trio) there's no plist to draw from — the symbol is then chosen by meaning and **verified** with `NSImage(systemSymbolName:)`, which returns `nil` for a name that doesn't exist (this is how we found out `zzz.circle` doesn't exist) | don't guess a symbol name; not `.semibold` (too heavy); don't assume a name exists just because it sounds plausible |
| Long sidebar labels | truncate on a single line + `allowsExpansionToolTips = true` (HIG) | don't wrap |
| Folder path | `NSPathControl` (self-truncating, click→Finder, doesn't stretch the layout) | not a bare `NSTextField` (stretches the window) |

## What SwiftUI Form gives for free (former AppKit exceptions)

macOS AppKit has no iOS-style grouped primitives. That used to force us to draw everything by hand
with measured constants. **Now the detail panes are SwiftUI (ADR-0042)**, and the system supplies all
of the following:

- **Grouped-inset container** (row height, corner radius, padding, dividers, card spacing) →
  `Form { Section }.formStyle(.grouped)`. The old `SettingsCard`/`SettingsRow` and their measured
  constants (row 37 / inset 12/11 / corner 4 / divider 10 / hairline 0.5 pt) are **gone** — these are
  now system defaults with zero constants.
- **Card color / panel background** → `Form.grouped` picks the system grouped background itself
  (previously a manual dynamic `NSColor` 242/43, 246/40, because the `.contentBackground` material
  produced a pure-white bug).
- **Rounded corners on the time picker** → the native `DatePicker(.hourMinute)` (previously a
  bezelless `NSDatePicker` inside a custom `RoundedFieldBox` with measured insets).
- **Colored chip behind the sidebar icon** → `List(.sidebar)` + `Label`/`.foregroundStyle`
  (previously a custom `ChipView`, because the standard `.imageView` outlet applied source-list
  tint/vibrancy on top).

The menu-bar widget (`StatusItemView`) now draws with **system semantic colors** (the `labelColor`
family + `.system*`, ADR-0059) instead of a fixed sRGB value — that's what gives it a native
look/feel. The **popup**'s pacing bars also moved to system semantic colors (ADR-0060; the
`.systemRed/Yellow/Orange` trio, track `labelColor@0.22`, except for the Claude brand color) — these
are **not** System Settings elements, so SwiftUI Form doesn't apply to them.

## My (the agent's) mistakes in this pass — and how to avoid them

Documented honestly so the next agent (or I) doesn't step on the same rake.

1. **Worked around system mechanisms, then picked numbers.** The biggest systemic mistake. Examples:
   hardcoded sidebar icon sizes instead of the `.imageView` outlet; painted the card a solid color
   instead of looking for a material; didn't think of SwiftUI Form. **Lesson:** always ask "is there
   a system way?" first, and only then reach for a constant.
2. **Checked only the light theme.** The user was in **dark** the whole time, and I was screenshotting
   light — so I missed dark-mode bugs (picker background color, weak divider). **Lesson:** always
   check light **and** dark.
3. **Checked only one state.** The sidebar icon size broke at large, because I only looked at medium.
   **Lesson:** check all three sizes (mode 1/2/3), the dev build, and the `.app`.
4. **Fixed things blind and broke something else.** A trailing-alignment change broke the switches'
   right alignment; a top/bottom-constraint change bloated the About card — twice. **Lesson:**
   diagnose with a screenshot → compare against System Settings → fix → **check every pane** with
   screenshots, only then hand it off.
5. **`effectiveRowSizeStyle` doesn't resolve `.large` for a source list.** Burned a cycle before I
   started reading `NSTableViewDefaultSizeMode` directly. **Lesson:** for source-list icon size, use
   the global default, not `effectiveRowSizeStyle`.
6. **`UserDefaults.didChangeNotification` doesn't catch a cross-process change** to a global domain.
   Reacting at runtime to a sidebar icon size change requires `DistributedNotificationCenter` with the
   private name `AppleSideBarDefaultIconSizeChanged`. **Lesson:** external changes to `NSGlobalDomain`
   go through distributed notifications, not local defaults-KVO. (Lessons 5-6 about the mechanism
   still stand, but the sidebar no longer uses it — the size is now pinned to Large, #335. Also
   measured: `defaults write` does **not** send that notification — only System Settings itself does,
   so testing the reaction to a change has to go through its UI, not through `defaults`.)

## How to measure System Settings (method)

- **AX `AXSize`/`AXPosition`** — exact sizes for the window, sidebar, rows (`AXOutline`,
  `AXOutlineRow`).
- **Retina screenshot ÷2** — colors (center pixel sample), geometry, corners.
- **`.appex Info.plist`** — System Settings section symbols/tints (`ISSymbolName`/`ISEnclosureColor`).
- **SDK headers** (`NSTableView.h`, etc.) — which APIs/styles actually exist (not from memory!).
- Don't guess from training data: the HIG site is an SPA and often doesn't respond to `WebFetch` —
  look for official Apple pages/forums instead, and honestly flag the limits of your confidence
  (convention, ADR-0021).

## Related

- [ADR-0042](../adr/0042-settings-swiftui-form.md) — moving the detail panes to SwiftUI Form
  (eliminated the measured card constants that used to live in this reference).
- [ADR-0040](../adr/0040-native-system-metrics-no-hardcoded-ui.md) — the "zero hardcoding" principle
  decision.
- [ADR-0035](../adr/0035-settings-window-sidebar-grouped-inset.md) — the original redesign (revisited
  twice: 0040 material/dynamic color, 0042 SwiftUI Form).
- [conventions.md](conventions.md) § UI design (AppKit).
- [ui-verification.md](../guides/ui-verification.md) — stubs and the live-verification process.
- Issue #156 (parity), #168 (SwiftUI Form rewrite).
