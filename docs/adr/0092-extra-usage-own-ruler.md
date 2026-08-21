---
status: accepted
date: 2026-08-14
supersedes: []
superseded_by: []
---

# ADR-0092: The credits bar — its own scale, with labeled month boundaries

> **Note on a stale quote.** In §"Alternatives considered," point 4 cites Pressure as an example
> of a scale with "a single tick at 20%." That tick no longer exists
> ([ADR-0098](0098-ruler-split-identify-always-explain-on-option.md)), and the "exactly on plan"
> position itself moved to the scale's zero ([ADR-0101](0101-pressure-is-the-gauge-ahead-half.md)).
> The argument is unaffected: it's about a mark needing to denote a **real** reference point, not
> an arbitrary fraction — and this ADR's decision (no ticks at all, two labeled month boundaries)
> still stands unchanged.

## Context

The "Extra usage" section shared not just its look with the token rows but also its **style
choice**: the dropdown's `BarStyle` controlled it too. The proposal was to pin the credits bar to
**Progress** forever and remove that choice.

The reason is that credits pace differently from tokens. Money is spent only once a base limit is
exhausted (`CreditsPacing.shouldShowIcon`), so the typical spending profile is
zero-zero-zero-spike, not a steady flow. On that profile, scales that measure **pressure against
time remaining** say little: Pressure flattens every calm state into a minimal pill
([ADR-0076](0076-pressure-scale-for-marker-less-bar.md)), and Gauge shows "the balance you won't
manage to spend in time" ([ADR-0079](0079-centred-zero-gauge-scale.md)) — but an unspent money
budget isn't a loss, it's simply money not yet paid. What's actually useful for credits is **how
much of the cap has been eaten and how far the month has gotten** — exactly the pair of positions a
window's scale marks out.

The main objection to hardcoding it wasn't arithmetic, it was **visual**: `BarStyle` promises "no
marker anywhere" for Pressure and Gauge, so a single bar with a marker in the middle of a column of
marker-free strips would read as a **bug**, not a decision — especially with no nearby toggle to
explain the exception. The second objection was **two scales in one column**: identical strip width
would mean different things in adjacent rows, exactly the confusion this project consistently
avoids.

## Decision

**The credits bar always draws on the window scale (Progress), regardless of the dropdown's
`BarStyle` — and it carries its own ruler: labels for the first and last day of the calendar month
at the track's edges** (`Aug 1` … `Aug 31`).

The labels aren't decoration — they're exactly what removes both objections. They **name the
window right on the bar**, so the bar reads as a *different tool*, not as the same one behaving
oddly. Different scales become visibly different, instead of silently looking the same.

**The credits bar has no ticks at all.** Internal month subdivisions are impossible (28–31 days,
no even split lands on a real boundary), and the boundary ticks turned out redundant the moment the
boundaries got names: the word already sits where a tick would, so a tick would mark what the label
already said. On top of that, the right-hand tick crowds the time marker near month's end.

**One field drives both halves of the decision — `CreditsRow.monthBounds`.** Both the scale and the
ruler follow from a single fact ("this window is a calendar month"), so they can never drift apart:
there are no two independent flags someone could someday set inconsistently. The render gained
`effectiveScale` / `effectiveShowsTimeMarker`, and **every** drawing branch reads them, not
`barStyle.scale` — otherwise the strip would draw on one scale while the marker sat on another.

**Labels are computed in UTC** — the same zone `timeFraction` is computed in
(`CreditsPacing.resetTimeZone`; the monthly limit resets at 00:00 UTC on the 1st, confirmed by
Anthropic's docs). A label has no business naming a different month than the one its own geometry
measures.

## Alternatives considered

The question was **what exactly should show that the bar is different.** That an unexplained
exception reads as a bug was accepted from the start; what was open is what carries the
explanation. Five options were considered; four rejected.

**1. Only a hint in Settings, no change to the bar.** The cheapest option: one line of text, no
render work. Rejected as **insufficient in place**: the hint sits in Settings, while the surprise
happens **in the popup**, where Settings isn't visible. A user who never opened that page — i.e.
most people — would see a bar exception with no hint at all. The hint stayed, but as a supplement,
not as the load-bearing piece.

**2. A silent hardcode — just pin Progress and add nothing.** Rejected immediately: this is exactly
the configuration where `BarStyle` promises "no marker anywhere" and one bar draws a marker anyway.
The worst benefit-to-surprise ratio of all the options — the exception silently contradicts the
promise the toggle made.

**3. A quieter month marker instead of the full 7×14.** The idea: mark the position within the
month without importing Progress's **identifying glyph** — the project already has a precedent for
this kind of construction, the Gauge center tick (1 pt, neutral tone, under the track, only the
tips visible — [ADR-0079](0079-centred-zero-gauge-scale.md),
[ADR-0089](0089-gauge-centre-tick-calm-tone.md)). Rejected because it cures the **wrong** half: a
quiet marker removes the stylistic contradiction, but says nothing about the **scale** — and it's
exactly the scale difference that makes neighboring bars incomparable. On top of that, for anyone
already on Progress, the credits bar would start differing from the token ones — the exception
would just move to a different configuration.

**4. A calendar ruler with quarter-month subdivisions (`subdivisions: 4`).** The mechanism already
existed — one argument to the call. Rejected because quarters **mark nothing real**: a month has
28–31 days, an even split lands on no real boundary, so the ticks would depict a precision that
doesn't exist. Compare with Pressure, where the single tick sits at 20% — there it's a **real**
reference point ("exactly on plan"), not an arbitrary subdivision.

**5. Labeled month boundaries — chosen.** The two points that genuinely exist on this scale and are
worth knowing, labeled so the bar **names its own window**. This is the only option that closes
both objections at once: the words "Aug 1" on the left and "Aug 31" on the right say both "the
scale here is different" and "which one exactly" — with no need to point back to Settings.

During implementation, a **sixth** intermediate idea also fell away — boundary ticks **together**
with the labels. The live render showed a tick under a word marks what the word already said, and
the right-hand tick additionally crowds the time marker near month's end. Only the labels remained.

**Color** was separately rejected as a way to differentiate: severity is computed **before** the style
choice, and the state "the same `(u, t)` with a different color on different bars" is a declared
impossible combination. Color here is the model's output, not a way to emphasize something.

## Consequences

**The cost is named: a label can drift from the user's local calendar.** East of UTC (Kyiv, Tokyo,
Sydney), in the first hours of a new month the bar still says "Aug 1 … Aug 31" while the wall
calendar already reads September; west of UTC (New York, Los Angeles), it's the mirror case. The
window of mismatch is up to ~11 hours east and ~8 hours west, once a month. This isn't a bug: the
last day of **your billing window** really is August 31 UTC, and credits at 01:00 in Kyiv on
September 1 haven't reset yet. The alternative — computing locally — was rejected because it
creates a worse flaw: a label contradicting its own geometry ("Sep 1" on a bar measuring August).
Right next to it, in the same row, `resetLine` renders **locally**, and that's deliberate: the
moment of reset is a point on a timeline shared by everyone, while a month label is a property of
the window's own calendar.

**The decision is not silent.** Under the Bar style control in Settings → Dropdown there is a hint,
"*Extra usage* bar always draws in *Progress* style." — anchored to the control itself (a shared
`VStack`), the same as every other explanation on those pages. The reasoning isn't repeated in the
hint: it would just restate what the bar's own labels already show.

**Symmetry with "credits pace exactly like a token limit" is preserved where it matters.** The
color and severity of credits are computed by the same `aheadColor` ladder as before (spike #142) —
only the **render geometry** changed, and `BarStyle` was always render-only. The state "the same
`(u, t)` with a different color" remains impossible.

**What became impossible in renders:** a credits bar in Pressure or Gauge anatomy, a credits bar
with ticks, a credits bar with no boundary labels (while a cap exists). The exception "a
left-anchored strip on the credits row under `.pressure`," which lived in
[ui-state-truth.md](../reference/ui-state-truth.md), disappeared along with that state's
possibility.

**An unlimited cap draws nothing** — no bar, no labels (`bar == nil` ⟹ `monthBounds == nil`): only
what exists can be labeled.

**The `credits-month-end` stub** freezes the clock at 90% of the month — the point where the time
marker gets closest to the right-hand label. This is the tightest spot in the geometry, and the one
to check whenever metrics change.

Refines [ADR-0062](0062-configurable-bar-presentation.md) (the style choice no longer applies to
the credits bar) and adds a fourth case to [ADR-0076](0076-pressure-scale-for-marker-less-bar.md) /
[ADR-0079](0079-centred-zero-gauge-scale.md): a bar whose scale is set by **the data**, not by a
setting.
