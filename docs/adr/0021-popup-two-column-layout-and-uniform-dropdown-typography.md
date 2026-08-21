---
status: accepted
date: 2026-07-23
---

# ADR-0021: Popup — a two-column layout, ⌥-gated status, one dropdown font

## Context

A series of UI iterations on the popup dropdown (`PopupViewController`) converged on a few small
fixes that together form one visual pattern worth pinning down — so the next popup change continues
it, instead of accidentally diverging into a new approach:

1. Every detail line in a limit section (`"20% used  ·  resets in ~20m at 05:30"`) was **one** line
   with a `·` separator — "resets in" had no alignment to the right edge of the bar underneath it.
   Same for the section's first line (`"Claude Code  ·  ahead of pace"`).
2. The Claude service status lines (issue #31) were shown **always**, taking up constant space even
   when both components were `operational` — the value on most popup openings is zero (people check
   the widget for the numbers, not to see a green "all good").
3. The "Claude Code" section header and the native menu items ("Settings…", "Quit…") in the same
   dropdown had **independently chosen** font sizes — an attempt to eyeball a match via
   `NSFont.menuFont(ofSize: 0)`, then via empirical trial (16 pt); neither matched the real
   `NSMenuItem` rendering.

## Decision

1. **A two-column split layout instead of one line with `·`.** A new private helper,
   `addSplitLine(left:right:leftFont:rightFont:leftColor:rightColor:)` — an `NSStackView` with
   `.distribution = .equalSpacing`, its width forced to `Metrics.width - 2·hPadding` (the same
   content width as the bar underneath it). `addTitleStatusLine` (title/pacing) and `addDetailLine`
   (used/reset) both delegate to it — the right half is always aligned to the bar's right edge. A
   side effect: the bar is also stretched to the full content width (previously a fixed 240 pt) —
   both now share the same right edge.

2. **The service-status section is ⌥-gated, not always visible.**
   `PopupViewController.optionHeld: Bool` (`didSet` → `rebuild()`) is fed from `App.swift`'s
   `updateActionItemForOption(_:)` — the same modifier-poll timer that already toggles "Settings…"/
   "Troubleshoot…" (ADR-0020 §3). The visibility condition:
   `status?.worstProblem != nil || optionHeld` — a real problem is **always** shown regardless of
   ⌥ (that's exactly when the popup should explain itself), "everything's fine" only shows under
   ⌥. The "Updated … · interval …" line (the same section) hides/shows along with the statuses.

   **A critical detail:** `NSMenu` does not re-measure a hosted `NSMenuItem.view` on its own when
   the content changes (`NSMenu` lays out with `frame`, not Auto Layout — the same trap described
   in `setPopupLayout`'s comment for ordinary live fields). So `updateActionItemForOption(_:)`,
   after `popupVC.optionHeld = optionHeld`, **must** re-set
   `popupVC.view.frame = NSRect(origin: .zero, size: popupVC.view.fittingSize)` — without this the
   dropdown doesn't change height when ⌥ is held, even though the content itself renders correctly.

3. **One shared font constructor for the whole dropdown — not an eyeballed guess.** There's no
   reliable way to *read* which exact font/size AppKit actually uses to draw `NSMenuItem.title` in
   the modern (Big Sur+ redesign) menu: `NSFont.menuFont(ofSize: 0)` is documented to return 13 pt
   (`= NSFont.systemFontSize`), but renders noticeably smaller than an actual native item; manual
   tuning via screenshot comparison (14/15/16/17 pt were tried) also gave no stable result — 16 pt
   looked closest in the trial set, but next to a real "Settings…" it turned out clearly too big.
   Instead of continuing to hunt for the right value, the decision is to **write**, not read: one
   package-wide constant

   ```swift
   let dropdownTextSize: CGFloat = NSFont.systemFontSize   // PopupViewController.swift, file-scope
   ```

   applied explicitly on both sides:
   - `PopupViewController` — every label (`Metrics.textSize = dropdownTextSize`); the only
     difference is weight (`.boldSystemFont`/`.systemFont`), and there's no hardcoded `ofSize:`
     anywhere else.
   - `App.swift` — the native items ("Settings…"/"Troubleshoot…", "Quit…") get an
     `NSMenuItem.attributedTitle` (not a bare `.title`) with the same
     `NSFont.systemFont(ofSize: dropdownTextSize)`, via the `dropdownMenuItemText(_:)` helper,
     including the dynamic swap in `updateActionItemForOption(_:)`.

   A mismatch becomes structurally impossible — both sides read the same variable, instead of two
   independent AppKit API calls happening to agree by chance.

## Consequences

- `PopupViewController.Metrics` no longer contains `barWidth`, `titleSpacing`,
  `separatorPadding`, `statusToLimitsSpacing` — all absorbed into a single `sectionSpacing` (the
  same gap after a section header and between limit sections/bars), or dropped along with the
  removed title line/rule (`addSeparator`/`addSeparatorIfNeeded` were removed as dead code — no
  dropdown section is separated by a line anymore, only whitespace; the HIG allows either approach
  to grouping equally, this is a stylistic choice, not a compliance one).
- The popup no longer shows a separate "TokenPace" header — the dropdown's first line is now
  "Claude Code" (brand color `#d97757`, confirmed against `anthropics/skills`'s
  `brand-guidelines/SKILL.md`). The dev-build/installed-`.app` distinction (issue #69), which used
  to live in that header, moved into the "Quit" item (`"Quit TokenPace (dev build)"` on a bare
  `swift run`).
- `PopupLayout.rows(from:now:)` (`TokenPaceKit`, pure) — section headers dropped the word "limit":
  `"5-hour limit"` → `"5-hour"`, `"7-day limit"` → `"7-day"`. `PopupLayoutTests` updated to match.
- `docs/conventions.md` gains a new "UI design (AppKit)" section: a mandatory check against the
  current Apple HIG before committing a UI change (not from memory — the HIG site is SPA-rendered,
  `WebFetch` often returns empty content; the fallback is `WebSearch` against official Apple
  Developer pages, honestly flagging the confidence limit when no exact official figure is found),
  and the principle itself — "one shared font constructor, not an eyeballed guess" — generalized
  from this ADR to any future AppKit screen.

## Related

- [ADR-0020](0020-troubleshoot-window-and-diagnostics-pipeline.md) §3 — the same modifier-poll
  timer (`optionPollTimer`/`updateActionItemForOption`), now also feeding `popupVC.optionHeld`.
- [ADR-0013](0013-claude-status-line.md) — `StatusHealth`/`ServiceStatus`/`worstProblem`, whose
  visibility condition (`!= nil`) now directly drives the UI section's visibility, not just the
  menu-bar dot.
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — the pure-core/thin-shell split;
  gating the status section on ⌥ is an AppKit-layer decision (`optionHeld` lives in
  `PopupViewController`, not `PopupLayout`), the `StatusHealth` model is unchanged.
