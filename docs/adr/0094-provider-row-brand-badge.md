---
status: accepted
date: 2026-08-14
supersedes: []
superseded_by: []
---

# ADR-0094: The provider row gets a brand badge, the Providers chip becomes a puzzle piece

## Context

The `Providers` page replaced `Extra features`
([ADR-0084](0084-settings-drill-in-child-pages.md)), and brought with it the `Claude`
navigation row. Two things from that decision rested on arguments that, over time, stopped
matching what's on screen.

**The section's chip showed a cloud** (`cloud.fill`). A cloud depicts *where* the services run —
but that's not what the page configures. It configures the **connection** to them: one row per
provider, and more rows are coming. A symbol that describes someone else's infrastructure says
nothing about the axis the page grows along.

**The chip's color was purple** (`0x5E5CE6/0x8C8AFB`) — inherited from the now-retired
`Extra features` chip. Right next to it in the code sat a warning that this was a **starting
value, not a measurement**: the pair had been lifted with a color picker from a *different* System
Settings pane, and it was waiting to be checked against the one Providers would eventually come to
resemble. That debt just sat there, unpaid.

**The `Claude` row had no icon at all**, and [ADR-0084](0084-settings-drill-in-child-pages.md)
justified it this way: "a provider's logo is legally questionable, and a generic glyph would be
decoration standing in for information." The first half is sound and still stands. The second one
isn't: `Internet Accounts`, whose shape this row's form was lifted from, gives every entry a
colored badge, and there it's not decoration — it's exactly what lets you recognize the row at a
glance.

## Decision

**1. The section chip becomes `puzzlepiece.extension.fill`.** A puzzle piece says what the page
does: a provider snaps into the app, and there's growing room for the next pieces. The symbol's
existence was checked with `NSImage(systemSymbolName:)` on macOS 15 — the same method that
revealed, in #341, that `zzz.circle` doesn't exist.

**2. The chip's color becomes the measured `General` gray**
(`0x5E5E5F/0xC0C0C4`). `General` and `Providers` sit in the same sidebar group, because they
answer the same question, "what does the app do" (rather than "how does it look") — and now the
sidebar says so in color, the same way it says green for the UI trio. As a side effect, this pays
off the debt: instead of an unverified pair borrowed from an unrelated pane, the pair now comes
from the very pane the chip sits next to.

**3. `SettingsNavigationRow` gains an optional leading badge.** The slot for it was planned from
the start — the metric was named `chipTextGap` and never used. A row with nothing to identify
itself by passes `nil` and stays with its text flush to the left edge.

**4. The badge carries a generic glyph on a brand color, never a logo.** The legal objection from
[ADR-0084](0084-settings-drill-in-child-pages.md) still stands and is honored exactly this way:
color belongs to the brand, shape belongs to the system. For Claude that's `cloud.fill` on
terracotta `#d97757` — the cloud moved here from the section chip, and here it fits: the provider
really **is** a cloud service, even though the page is about connecting to it.

**5. The color comes from the same `ColorRole.claudeBrand`** as the "Claude Code" heading in the
popup ([ADR-0021](0021-popup-two-column-layout-and-uniform-dropdown-typography.md)), rather than
being duplicated as a separate constant. Two brand markers in one app can't drift apart if they
share one source.

**6. Size — 26 pt (16 pt glyph), matching the sidebar chip.** Lifted from `Internet Accounts`:
there, an entry's badge is noticeably larger than the sidebar chip and overlaps both lines — the
name and the status line. On a two-line row this reads as **the row's icon**, not a bullet in
front of text. The glyph is slightly smaller proportionally than the sidebar one (16 of 26 vs. 17
of 26): a cloud fills its square more tightly than a gear does, and at the sidebar's proportions it
crowded into the corners.

**7. The badge's gradient is derived from measured pairs, not invented.** The sidebar capsule has
**two** measured endpoints; the brand gives **one** color. The second endpoint is
`dark + t·(255 − dark)` per channel, with `t` taken as the average across four measured pairs:
0.188 (UI presets), 0.191 (Notifications), 0.503 (About), 0.616 (General) → **0.375**. For
terracotta this gives `#D97757` at bottom-right and `#E7AA96` at top-left, on the same axis as the
sidebar capsules (`0.25,0 → 0.75,1`).

## Consequences

**The gradient's light endpoint is not a measurement, and the code says so directly.** It's the
only color in Settings derived by formula rather than by color picker. The justification: System
Settings has never drawn a capsule in terracotta, so there's nothing to measure; but the rule
["colors are measured with Digital Color Meter"](../reference/ui-state-truth.md) isn't weakened by
this, and the doc comment asks that `#E7AA96` be checked with a color picker rather than trusted as
a number.

**The spread of `t` across panes is huge — from 0.188 to 0.616.** This isn't measurement noise,
it's exactly what `CapsuleTint`'s doc comment warns about: system capsules are hand-drawn artwork,
not one formula. So 0.375 is more honestly called a stand-in for a measurement than a "correct"
number. If the terracotta top ever reads as a washed-out pink, the closer analogues are the
saturated **chromatic** panes (UI presets and Notifications, both ≈ 0.19), and the fix is a single
constant, `lightenFraction`.

**The "generic glyph = decoration" objection from
[ADR-0084](0084-settings-drill-in-child-pages.md) is partially withdrawn.** The legal half of that
argument still stands and is repeated here as point 4 — it's exactly what keeps logos off the
table. Only the claim that *any* generic glyph on this row is decoration is withdrawn.

**The badge is flat in structure but not in appearance.** It doesn't use `CapsuleTint`, because
that type means "two measured points," and feeding it a derived number would dilute that
guarantee. The cost is a bit of duplicated geometry (5 pt radius, gradient axis) between
`SidebarChip` and `SettingsRowBadgeView`; pulling out a shared chip is left for whenever a third
carrier of this shape shows up.

## Alternatives considered

**The Anthropic logo on the badge.** Ruled out for the same reason as in
[ADR-0084](0084-settings-drill-in-child-pages.md): a redrawn wordmark inside someone else's app is
legally questionable, and no amount of recognizability offsets that.

**Leave the badge flat (no gradient).** That's how it was done at first — precisely because the
brand only gives one color. Rejected because a flat chip next to the sidebar's gradient capsules
reads as a different material; deriving the second endpoint from the measured pairs turned out
cheaper than that inconsistency.

**Take `t` as the average of only the chromatic panes (≈ 0.19).** The argument for: the gray
`General` and the blue `About` (whose blue channel is already pinned near 255) lighten
differently than a saturated color does. The argument against, which won out: the average across
**all four** is what's actually visible across the sidebar as a whole, and the gap between 0.19 and
0.375 for terracotta stays within the spread of the system capsules themselves.

**Reuse `SidebarChip` for the row.** It's `private` and typed to `SettingsSection`; splitting it
out would mean parameterizing it with primitives and moving it to its own file — a refactor for the
sake of a single carrier of the new shape. Deferred until a third one shows up.
