---
status: accepted
date: 2026-08-12
supersedes: []
---

# ADR-0082: Settings sidebar icon size is pinned to Large

> A deliberate **exception** to [ADR-0040](0040-native-system-metrics-no-hardcoded-ui.md) ("system
> mechanisms, not hardcoded metrics"), in the same spirit as the exceptions already recorded there:
> when no system mechanism exists, it's more honest to measure and document a number than to imitate
> system behavior halfway.

## Context

The sidebar read the system's **System Settings → Appearance → Sidebar icon size**
(`NSTableViewDefaultSizeMode`, 1/2/3 = S/M/L) and updated live through the private notification
`AppleSideBarDefaultIconSizeChanged`. The mechanism worked — the capsule's size really did follow the
system.

The problem the maintainer found while switching size: **only** the capsule followed. The rest of the
numbers the system moves along with it stayed put, and the mismatch got worse the smaller the icons.

Measured on live windows (@2x, both 857 pt):

| Size | Width: ours / System Settings | Row inset: ours / System Settings |
|---|---|---|
| Small | 276 / **259** | 32.5 / **10** |
| Medium | 276 / **259** | 26 / **10** |
| Large | 276 / 276 | — / **10** |

Both mismatches have a technical cause, and both are measurable:

- **SwiftUI doesn't hand back the column width.** `.navigationSplitViewColumnWidth(259)` renders at
  307 pt. `.frame(width:)` doesn't scale at all — it "snaps" between a handful of states: frame 200 →
  307 pt, 240 → 243, 340 → 243 — a wider frame produces a **narrower** column. That's exactly why
  three "calibrated" values (242/255/275) all rendered identically.
- **The row inset is derived from the list's width.** `listRowInsets` can only **add** to
  `List(.sidebar)`'s own 20-pt floor (measured: leading 0 → 20 pt, 4 → 24, 10 → 30), so getting it
  down to the system's 10 is only possible with negative padding.

Both were fixed — the width through `NSSplitView.setPosition(_:ofDividerAt:)`, the inset through
negative padding — and afterward the measurements matched the system at all three buckets. But on a
live window the match still didn't read as one: the capsule, the width, and the inset are just three
numbers among many the system moves together (row height, vertical spacing, text tracking, the
position of group separators), and chasing them one at a time means approaching the target without
ever reaching it.

## Decision

**Don't follow the system size at all.** `SidebarIconMetrics` now returns the fixed values for the
**Large** bucket — chip 26, symbol 17, label 15 — and no longer reads `NSTableViewDefaultSizeMode` or
subscribes to `AppleSideBarDefaultIconSizeChanged`.

Large, not Medium: it's exactly the bucket the rest of the window was measured and fitted against, back
in [#156](https://github.com/artem-from-ua/tokenpace/issues/156)
(width 288 in `.frame`, from which SwiftUI produces the 276 pt the window has lived at all along).
So this isn't a new size choice — it's an acknowledgment of the size we actually already had.

The type stays (instead of inlining numbers at each call site), so there's one place that answers
"how big is the sidebar capsule," and one place to come back to if a future macOS gives SwiftUI a real
handle on column width.

## Consequences

- **The window is now honestly one size.** It used to be "half system": one capsule, with the
  geometry around it from Large. Now there's no mismatch in any state, because there's only one
  state.
- **A user who chose Small will see Large in our app.** This is a deliberate cost: the alternative is
  three states, none of which match the system, and that's exactly what the maintainer rejected after
  a live review.
- **Dead code removed:** the notification observer, `deinit`, `systemBucket()`, `apply()`, and an
  `@ObservationIgnored` field. The class became a list of constants.
- **The lessons from #156 about the mechanism itself still stand**, recorded in
  [system-settings-parity.md](../reference/system-settings-parity.md) — they'll be useful if following
  the system ever becomes fully possible. That same document also records a side finding: `defaults
  write` for this notification **does not send** it (only System Settings does), so the response to a
  change can't be verified through `defaults` — only through the system UI.
- ADR-0040 stays in force as a principle; this is an exception to it, not a repeal — exactly where no
  system mechanism able to cover the whole geometry exists.

## Alternatives considered

- **Chase the remaining numbers to match the system** (width + inset had already been fixed).
  Rejected after a live review: the match still stayed incomplete, and every additional number was
  one more measured constant liable to drift out of sync on the next macOS.
- **Pin to Medium** (the system default). Rejected: the rest of the window was measured against
  Large, so Medium would require re-measuring and re-fitting the entire geometry — more work for a
  size no one asked for.
- **A dedicated "icon size" option in Settings.** Rejected: this setting is inherently a system one,
  and duplicating it means multiplying the same decision across two places (see the rule in
  [users-and-goals.md](../reference/users-and-goals.md) about what the user already controls
  themselves).
