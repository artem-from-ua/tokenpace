---
status: accepted
date: 2026-08-24
supersedes: [0091]
---

# ADR-0128: The menu bar repeats a block per provider, with the status dot pinned rightmost

> **Supersedes the shape of [ADR-0091](0091-countdown-only-where-work-is-not-running.md), not its
> rule.** 0091's `MenuBarMode.expanded(fiveHour:sevenDay:)` becomes `expanded(blocks:)`, and the
> `which: LimitWindow` parameters it left on the bars-less cases become `provider:`. **The decision
> itself still stands in full**: a countdown exists only where there are no bars, the type is what
> enforces it, an exhausted window never draws a bar, and contradictory data gets one signal. This
> record makes that invariant hold for *n* providers instead of for one.

## Context

The widget was built around one provider with two windows, and the type said so:
`expanded(fiveHour: BarView?, sevenDay: BarView?)` — a hard pair, with `drawBars` switching on
`(five, seven)` literally. Everything downstream inherited the assumption: `itemWidth` reserved one
`barWidth` column, the pause glyph and the money marker were widget-level decorations drawn to the
left of everything, and `which: LimitWindow` on the bars-less cases named a *window* because there
was only ever one provider whose window it could be.

[#501](https://github.com/artem-from-ua/tokenpace/issues/501) added Codex, the first provider with
both halves — a status page **and** a usage API. [#503](https://github.com/artem-from-ua/tokenpace/issues/503)
gave it a popup plate and an explicit `ProviderID.displayOrder`;
[#524](https://github.com/artem-from-ua/tokenpace/pull/524) made its quota flow for real. Those were
additive. The widget is not: it is the one surface every existing user already looks at, and it
reports a live server that sends Codex **one** window today, not two.

So the question is not "where does Codex's bar go". It is what the widget's shape should be once the
number of bars is data rather than a constant, and how identity is conveyed on a surface with room
for neither a label nor an icon.

## Decision

### D1. A sequence of blocks, each with the bars its provider actually reports

`MenuBarMode.expanded(blocks: [ProviderBlock])`, where a block carries one provider's bars, its own
pause glyph and its own money marker. `bars` is `[BarView]` — two for Claude, one for Codex today,
three for whatever a server sends next — and **never a synthesized pair**: a 5-hour bar Codex does
not report would be a drawn bar for a limit that does not exist, under a reset invented to fill the
field.

Two invariants are held by the type: `blocks` is non-empty, and no block has empty bars. The one
input that could violate them — every bar elided while calm — is answered with the glyph state
instead. ADR-0091's own invariant survives untouched: no case carries both bars and a countdown, so
"bars *and* a number" stays unrepresentable rather than merely unreached.

### D2. The cases that named a window now name a provider

| Case | Was | Is |
|---|---|---|
| `iconOnlyReset` | `(reset:which: LimitWindow)` | `(provider:reset:)` — it says *whose* quota blocks you |
| `exhaustedUnknownReset` | `(which: LimitWindow?)` | `(provider:)` |
| `weeklyResetUnknown` | no payload | `(provider:)` |
| `error` | `(fiveHour:sevenDay:reset:which:)` | **no payload** |

`which` was documentation-only from [ADR-0074](0074-one-reset-format-on-both-surfaces.md) onward — the label
format stopped depending on it — and with two providers the informative fact is no longer which of
one provider's two windows it was. `.error` loses its payload outright: `drawError` has ignored
those four parameters since ADR-0091 decided that data too stale to trust is not shown at all, and a
parameter nothing reads is a claim the type keeps making falsely.

### D3. Separation is a gap. Not a rule, and above all not a brand tint

Blocks are separated by a horizontal gap wider than the gap **inside** a block, so the grouping
reads as "bars together, blocks apart".

**Brand-tinting the bars is rejected, explicitly, because it will be proposed again.** It is the
obvious way to tell two blocks apart, and it is wrong. A bar's colour **is** the pacing verdict:
green through red is the whole answer the widget gives, and on a 5 pt shape there is no second
channel to carry anything else. A Codex-blue bar would assert "Codex" and "well within pace" with the
same pixels, and nothing tells the reader which one it means. A drawn separator is rejected too: on a
menu bar, a vertical rule reads as the boundary between two *applications*.

The cost this buys is real and is named in the Consequences: identity in the widget becomes
**positional**.

### D4. Ordering is alphabetical, through `displayOrder`

Blocks are sorted by `ProviderID.displayIndex` — the one property that decides provider order
anywhere ([ADR-0125](0125-codex-as-a-status-provider.md)), so the widget, the Settings list and the
popup plates cannot drift into three different orders.

### D5. The dot is a position, not a visibility change

The status dot stays rightmost, after every block. "Silence means fine"
([ADR-0013](0013-claude-status-line.md) §8) is untouched: no dot while everything is green. The
raised-hand awaiting-input icon stays **single and leftmost**, outside the blocks — it is a fact
about Claude Code sessions, not about a quota.

### D6. Crowding is answered by a checkbox, never by hiding a block

Appearance → Menu bar gains **"Providers to display"** — one checkbox per provider whose usage
collection is on, all ticked by default, stored as the *hidden* set so a provider added later needs
no migration. The section appears only when there is more than one provider to choose between.

`itemWidth` has **no ceiling**, deliberately. A degradation ladder that drops a block once the item
grows would decide for the user, silently, on the one surface where width is shared with every other
app. **The last ticked box is disabled**, so the set cannot empty: an item that draws nothing is
indistinguishable from a crashed one, and a widget that kept drawing a block the settings said was
hidden would contradict its own screen. Disabling the box says the choice is unavailable before it is
made, where refusing the click would read as a bug. The Kit still keeps one block if it ever receives
an empty set — a backstop for a stored set written by another build, not the ordinary path — and
collection itself has its own switch on the Providers page.

### D7. The status item gets an accessibility label

`App.swift` set `button.image` and no label at all. The `accessibilityDescription` strings passed to
`NSImage(systemSymbolName:)` are baked into a flat bitmap and never reach VoiceOver, so the widget
was silent. A pure Kit function, `MenuBarLayout.spokenDescription`, produces the spoken string and
`refreshStatusImage` sets it.

Every block is named by its provider, and every bar gets its window, its percentage and its **pacing
verdict in words** — the verdict is the point of the bar, and colour is exactly what does not survive
into speech. This closes a gap that predates Codex; with one provider it was a small loss, and with
two, positional identity becomes the only cue on screen, which is precisely what a screen reader
cannot convey.

## Consequences

- **Provider identity in the widget is positional, and that is a limitation, not a feature.** The
  leftmost block is first alphabetically; nothing on the surface says so. A user with two providers
  learns the order once and then reads by position, and a user who has just added a second provider
  has no way to tell which is which without opening the popup. D3 chose this over a colour language
  that would corrupt the one the bars already speak, but it is a cost, and the accessibility label of
  D7 is the only place a name is actually available.
- **Width now depends on the *set* of providers, not only on the content.** Ticking a second provider
  widens the item permanently, and the menu bar is right-aligned, so everything to its left shifts.
  D6 makes that the user's explicit choice rather than a surprise.
- **The n = 2 geometry is unchanged and had to be proved so.** `halfPointAligned` and the measured
  `(33 − 22) / 2 = 5.5` status-button offset are a fix for real blur, and generalising a hand-tuned
  pair is exactly how such a fix gets lost. The block's top edge is computed from the bar **count**
  and then snapped, which reproduces today's expression for one bar and for two.
- **Two providers can now show identically-titled bars.** Claude's week and Codex's week are both
  `7-day`, so the colour-transition registry is keyed by `(provider, row)`; keyed by row alone, one
  provider's colour slide would play out on the other's bar.
- **A satellite provider's block is built from the popup rows its plate already draws**, so the
  widget's bar and the plate's bar are one normalization rather than two that can disagree.

## Alternatives considered

**Brand-tinting the bars.** Rejected in D3, at length, because it is the proposal this record exists
to give somewhere to land.

**A drawn separator between blocks.** A vertical rule in the menu bar is the convention for the
boundary between two applications' status items; using it inside one item says the widget has split
in two.

**A degradation ladder for crowding** — drop the calm block, then the second bar, then fall back to a
glyph. Rejected in D6: it makes the widget's shape unpredictable from the user's own settings, and
the thing it optimizes (width) is the thing the user is best placed to decide about, since only they
know what else is in their menu bar.

**Keeping `which: LimitWindow` alongside a new `provider:`.** Two identifiers where the code reads
one, and `which` had already lost its last consumer to ADR-0074.

## Verification

Six stubs, listed in [ui-verification.md](../guides/ui-verification.md):
`menubar-claude-only` (the regression guard), `menubar-claude-codex`, `menubar-codex-only`,
`menubar-codex-one-window`, `menubar-provider-failing`, `menubar-providers-deselected`.

The regression guard is checked by **pixel diff against a `main` build** — `main` and the branch run
at once, the real menu bar captured (a window capture does not show vibrancy against the wallpaper),
and the top strip diffed. A 0.5 pt drift is invisible in review and unmistakable in a diff.
