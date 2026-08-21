---
status: accepted
date: 2026-08-04
superseded_by: [0114]
---

# ADR-0068: Anatomy of the "credits in use" marker — a pill with a knocked-out currency glyph

> **Postscript (#416).** The clause "The wording `Extra Usage Credit` is aligned with the existing
> notification" (below, in "Related decisions") is superseded by
> [ADR-0114](0114-extra-usage-is-one-name.md): every surface now writes **`Extra usage`**, and
> `credits` is lowercase and plural. The motive hasn't changed — it's the same as here: the app
> shouldn't name one thing two ways. What changed is which side got picked as the canon: 0068
> aligned the hint with the notification and didn't see the third participant — the popup
> section's title (`PopupViewController.extraUsageTitle`), which was already sentence case. The
> rest of this ADR still stands.
>
> **Postscript (#396).** The anatomy is superseded by
> [ADR-0108](0108-extra-usage-one-anatomy-and-per-bar-style-caption.md). The marker is still a
> `PillView`, but: it moved from the leading half to the **trailing** one, where it qualifies the
> status word; its fill became the neutral `barTrack` instead of the label color (in the label's
> own color it read just as loud as the blocking-reset badge next to it); and along with that, the
> **knockout is gone** — on light gray, the cutout showed a card in almost the same tone, so the
> glyph faded instead of reading, and the ink became plain `label`. The product decision — "a
> neutral pill, with no status color" — hasn't changed; what changed is how neutrality is
> achieved.
>
> **Postscript (0.85.0).** This ADR's product decision still stands: the marker is a neutral pill
> with a currency sign, carrying no status color. What changed is the **implementation**. The
> glyph is no longer cut by a mask: `KnockoutGlyphBadge` is removed, the marker is drawn by the
> same `PillView` as the blocking-reset badge, and the sign goes into it as a **text attachment**,
> painted in the card's fill color with no alpha (`cardPlateFillOpaque`) — visually the same
> "cutout" look, but via plain text that switches light/dark on its own. The reasons: the three
> badges had three different heights (18.0 / 17.5–20.5 / 14.0 pt), and the currency one changed
> height along with the account's currency.
>
> Along with this, the claim "optical centering of the glyph isn't solved by calculation" (below,
> in "Consequences") is disproven. It is solvable — you have to measure the symbol's **ink**, not
> its box: currency boxes don't match (12×12 for `€` vs. 12×15 for `¤`), and that's exactly why the
> eyeballed constant `opticalNudge = −0.4` was only correct for the euro. Measurements are in
> `scripts/check-badge-heights.swift`.
>
> **Postscript ([#381](https://github.com/artem-from-ua/cc-timer/issues/381)) — the decision is
> reaffirmed, and it became the argument for itself.** The glyph in the menu bar no longer **reads**
> the bar-color settings ([ADR-0105 §4](0105-color-advice-governs-pacing-bars-only.md)): the
> marker's own scale is **white → orange → red**; there is no green or yellow rung to mute in the
> first place, by this ADR's own construction. The removed branch matched the rest of
> `creditsIconColor` everywhere except the **unlimited** cap, where it overrode the neutral
> foreground — that is, it muted "money is moving," which isn't a pacing verdict.

## Context

In the popup, next to the **Extra usage** heading, a marker shows when paid credits are actually
covering an exhausted limit (`CreditsRow.inUse`). Since #146 this was a badge with the word
`active`: blue at first (`controlAccentColor`), and from #224 filled **red**
(`PopupBarView.gapRed`), "to read as a warning that the limit is being spent on paid credit."

An external audit (#254) showed that this presentation contradicts the project's own rule.
`CreditsPacing.swift` states explicitly:

> Red appears **only** at the cap (`used >= limit` or `spend_limit_reached`) — being "ahead of
> pace" is yellow/orange, not red.

But the filled red `active` badge appeared **regardless of the amount**. In the state "5h
exhausted, €0.00 / €50.00," the Extra usage row said four things at once: a red badge
(critical), "on pace," a green bar, and zero spending.

Two consequences that matter more than the formal inconsistency:

1. **The signal had nowhere to escalate to.** If €0.00 is already painted in the loudest color in
   the interface, €49.00 is no louder. Nothing stronger was left for the cap.
2. **Two incompatible things looked identical.** `makeInUsePill` and `makeResetBadge` both called
   the same `makePill` factory with the same `gapRed`: "credits are in use" and "this specific
   reset will unblock you" were visually indistinguishable and could appear in the same popup.

A key clarification from the maintainer that settled the decision: **the fact of switching to
paid credits is itself a critical signal, independent of the amount spent.** So the audit's
suggestion of "remove the color and make it a neutral chip" would have discarded the requirement,
not satisfied it.

The resolution is to split two **orthogonal axes** that were so far encoded through one channel
(the fill):

- the **magnitude axis** (how much has been spent) — a gradient, already served by `aheadColor`;
- the **mode axis** (crossed from subscription into paid) — a binary event, whose criticality
  doesn't depend on the amount.

An additional fact: a signal for the **moment** of the switch already exists separately —
`BackToWorkNotifier`'s `postExtraUsage` sends a system notification, "Now using Extra Usage
Credit," on the not-spending → spending edge. So the marker in the popup carries an **ongoing
state**, not an event, and doesn't have to shout continuously.

## Alternatives considered

All three were built and verified live on the `credits-active` stub (macOS 15, dark).

### 1. An outlined `active` badge

A one-point red border, red text, no fill.

- **+** Separates the two pills anatomically (outline vs. fill), keeps the word self-describing.
- **+** A minimal departure from what already existed.
- **−** Red is still present as a status color, i.e. the mode axis still borrows a token from the
  magnitude axis.
- **−** Doesn't solve the escalation point: an outline at €0.00 looks the same as at the cap.

### 2. A bare currency glyph, tinted red

The word is removed, leaving `€`/`$` after the label, in red.

- **+** No pill at all — the collision with the filled reset badge disappears instead of being
  softened.
- **+** **Consistency with the menu bar**: it's the same SF Symbol the bar already draws for
  credits (`StatusItemView.creditsSymbolName(for:)`), so both surfaces mark the feature with one
  sign.
- **−** The glyph sits directly above "€10.8 of €15" and could read as a prefix to the amount
  rather than a state indicator.
- **−** A static red diverges from the bar's glyph, which is tinted via `aheadColor`.

### 3. A `label`-colored pill with a **knocked-out** glyph (chosen)

A solid pill in the ordinary text color, with the currency symbol punched all the way through it —
the popup's background shows through.

- **+** No status color at all: the marker states the **mode**, without claiming a severity. Red
  stays reserved exclusively for "you're blocked."
- **+** The anatomy differs radically from the filled reset badge, while the marker still reads as
  a dense, deliberate object rather than a barely-visible hint — matching the requirement that
  "this is a critical signal."
- **+** The same currency glyph as in the bar (option 2's advantage is preserved).
- **−** Needs its own view with a layer mask — more complex than an `NSImageView`.
- **−** Optical centering of the glyph in the pill isn't solved by calculation (see "Consequences").

## Decision

**Option 3** was chosen. The marker is drawn by `KnockoutGlyphBadge` — a layer-backed view that
fills the pill with `ColorRole.label` and applies a mask with an **inverted** glyph, so the symbol
is transparent.

Related decisions, made alongside this one:

- **`PillView` is now reserved solely for the blocking-reset badge.** A fill in the popup now means
  exactly one thing: the reset that unblocks work. The `stroke`/`textColor` parameters added for
  option 1 are removed.
- **The hint emphasizes the present tense**: `Currently spending Extra Usage Credit — your plan
  limit is exhausted`. The wording `Extra Usage Credit` is aligned with the existing notification,
  so the app doesn't name the same thing two different ways.
- **The currency glyph in the menu bar is limited to three colors** — white → orange → red. Green
  (`Palette.dotGreen`) and yellow are removed: bars grade through green/yellow because they show
  *pace*, while the currency glyph answers a different question — "is real money moving, and how
  close is the cap" — where a green "all good" would be misleading. The thresholds are the same
  ones used in `aheadColor`, so the glyph and the bars don't diverge.

## Consequences

**Positive.** Red in the popup means one thing again. The marker is present from the first second,
but doesn't occupy the loudest register, so there's room to escalate at the cap. The menu bar and
the popup mark credits with the same symbol.

**The cost — subpixel alignment.** The glyph in the pill isn't centered by calculation: an SF
Symbol's ink sits offset within its own bounding box, and the correction, a fraction of a point, has
to be re-derived at every rounding step (a whole pixel at 2×). Attempts to measure the ink's
bounds by rasterizing, force parity, and quantize the offset into pixels **produced no result that
matched what the eye reads**: the measurements showed "even" exactly where the maintainer saw a
skew.

So the alignment comes down to two constants, chosen **by eye**: `opticalNudge` (the glyph's
offset) and `hInset` (the pill's horizontal margin). This is a deliberate choice in favor of
simplicity — optical alignment in typography is done exactly this way. The lesson is broader than
this ADR: **for subpixel geometry, pixel measurements of the render are not a source of truth** —
exactly as a screenshot is not one for colors (see CLAUDE.md on the Digital Color Meter).

**What's still open.** The marker currently doesn't escalate with spending — it looks the same at
€0.00 and at the cap. Escalating the tint via `aheadColor` (calm → orange → red) was discussed
in #254 as a possible next step, but not implemented: live feedback on the neutral presentation is
needed first.

## Related

- #254 — the audit of the popup's color semantics (the origin of this change).
- #146 — the origin of the `active` badge (blue `controlAccentColor`).
- #224 / PR #225 — the badge became filled red as part of "popup polish," with no separate
  discussion.
- #158, ADR-0038, ADR-0048 — the blocking-reset badge, now the only filled one.
- ADR-0037 — the paid-credits model; `aheadColor` as the shared scale.
- ADR-0059 / ADR-0060 — the menu bar's and popup's semantic colors.
