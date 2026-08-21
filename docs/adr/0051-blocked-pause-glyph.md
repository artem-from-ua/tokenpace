---
status: superseded
date: 2026-07-31
superseded_by: [0063]
---

# ADR-0051: An orange "pause" glyph before the bars in the fully blocked state

> **Superseded by [ADR-0063](0063-unified-pause-hides-bars.md).** The "Show pause icon when fully
> blocked" option (the `showBlockedPause` key) was removed — the pause glyph now draws **always**
> under `isBlocked` and turned **red** (the role `menuPauseOrange` → `menuPauseRed`). The toggle
> was merged into a single `pauseHidesBars`, which controls only the bars.

## Context

When work is **fully stopped** — every main window (5h/7d) is exhausted **and** paid extra-usage
credits don't cover it (`CreditsPacing.isBlocked`) — the user has no way to work until the reset.
If they left the pacing bars visible (the "Show pacing bars when 5h/7d limits reached" option, #194,
now default-**off**), the bars show red 100%, but signal nothing about the fact itself that
"service is stopped". An explicit visual marker of a full stop is needed.

The decision: draw an **orange SF Symbol `pause.fill` as the leading element** of the widget,
behind a separate "Show pause icon when fully blocked" option (#199, default-**on**). The glyph
does **not** depend on the bars toggle: it appears both to the left of the bars (`.expanded`) and
to the left of the countdown text in bar-free mode (`.blockedReset`, #194) — as soon as a full
stop begins.

Two questions for this ADR: (1) **which predicate** shows the glyph, and (2) **how** to thread it
through the model.

## Decision

### The predicate — `CreditsPacing.isBlocked`, not `mainWindowExhausted`

The glyph means "work is impossible", so the trigger is `CreditsPacing.isBlocked(in:)`
(`mainWindowExhausted && !creditsCanCover`), **not** the broader `mainWindowExhausted`, which #194
(ADR-0049) uses for hiding bars. The difference matters: when 7d is at 100% but credits still
cover it, work continues on the paid tier — this is **not** a full stop, so pause is not shown.
This is the same boundary as the red "Effective blocker" badge in the popup
(`WorkAvailability.canWork` — the inverse of `isBlocked`).

> **Postscript (#161, [ADR-0113](0113-back-to-work-tracks-the-subscription-quota.md)).** The
> sentence above initially also counted the "Back to work!" edge at this boundary. No longer: the
> notification now watches `subscriptionAvailable` (`!mainWindowExhausted`) — that is, the
> **broader** boundary, the same one the paragraph above calls "#194 (ADR-0049)". They diverge
> exactly in the credits-cover case: the pause glyph is not shown there (work continues), while the
> quota is considered spent (so its reset can be announced). This ADR's decision — `isBlocked` as
> the glyph's trigger — still stands unchanged.

### The model — a `blockedPause: Bool` flag on `MenuBarLayout`, computed at the health-aware seam

Instead of the view layer (thin, with no business logic — ADR-0009) re-deriving `isBlocked`, the
`blockedPause` flag is computed in `MenuBarLayout` — at the same health-aware `make(...)` seam as
`credits` and `serviceProblem`, **after** `mode` is determined:

```
blockedPause = showBlockedPause (gate) && CreditsPacing.isBlocked(snapshot)
             && mode ∈ {.expanded, .blockedReset}   // i.e. NOT .error
```

The glyph is independent of the bars toggle (`hideBarsWhenBlocked`): it is set for both
`.expanded` (bars present) and `.blockedReset` (countdown-only). Only `.error` is excluded — a
stale/cold-start state is not a signal of "full stop". Threaded through
`with(serviceProblem:credits:blockedPause:)`, like other decorations. The flat `make(from:now:...)`
is untouched.

### Drawing — a leading glyph like `drawErrorGlyph`, a color like `drawCreditsIcon`

Both `drawExpanded` and `drawBlockedReset` draw the glyph at `rect.minX + hPadding` (vertically
centered), get back the right edge, and shift `originX` of the bars / countdown text to the right
— the same scheme already used for ⚠️ in `drawError`. Width is reserved symmetrically in
`itemWidth` (both the `.expanded` **and** `.blockedReset` branches) through one `pauseInset`, so
draw and width read the same flag and never diverge. Fallback: if `pause.fill` is unavailable —
content draws at the normal origin without a glyph (`guard … else { return originX }`), width is
slightly over-reserved, never clips.

### Color — a separate `ColorRole.menuPauseOrange` role

Project convention (ADR-0046): every menu color has its own role in DevColorTuner. Reusing
`menuStatusOrange` (the orange service dot) would tie two independent signals to one tuner slider,
so a separate `menuPauseOrange` role is added (starting value 240/140/40, like status-orange,
tuned independently afterward).

## Consequences

- A full service stop reads at a glance in **both** bar modes — whether bars are visible or in
  countdown-only. With `showBlockedPause`=on by default, the glyph appears as soon as `isBlocked`.
- The glyph and #194 compose cleanly, but are **independent**: `isBlocked` (pause) is narrower than
  `mainWindowExhausted` (hide-bars), so when a limit is exhausted but covered by credits, the bars
  hide (#194), but pause is **not** shown (work continues on the paid tier — that is not a stop).
- One more menu color in the tuner (`menuPauseOrange`).
- The `showBlockedPause` option — default-on (opt-out), gated by
  `PersistedConfig.showBlockedPause`, a toggle in Settings → Appearance (second in the list). Menu
  bar only; the popup is untouched.
