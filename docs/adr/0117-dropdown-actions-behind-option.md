---
status: accepted
date: 2026-08-22
supersedes: []
superseded_by: [0126]
---

# ADR-0117: Every dropdown action sits behind ⌥ Option, announced by a caption

> **Partially superseded by
> [ADR-0127](0126-settings-and-quit-stay-visible-by-default.md).** Only two of D1's five items are
> replaced: `Settings…` and `Quit TokenPace` (with Quit's separator) now follow a default-on switch
> instead of ⌥, which is the revisit this record asks for under "Alternatives considered".
> **Everything else still stands**: `Troubleshoot…` and `Development tools…` stay ⌥-only, the update
> line stays the always-visible exception (D2), the caption and its switch are untouched (D3, D4) —
> including the reason they are, since what ⌥ mostly reveals is on the widgets, not in the menu —
> and the mechanism is unchanged.

> Supersedes the visibility half of **§3** of
> [ADR-0020](0020-troubleshoot-window-and-diagnostics-pipeline.md), which made "Settings…" a
> "normal, always-visible item" with "Troubleshoot…" the sole ⌥-gated one. Every action item is now
> gated the same way. **The mechanism from that section stands unchanged** — the modifier-polling
> timer, and the two findings behind it (`isAlternate` is inert in a status-item menu; an event
> monitor is starved by menu tracking). This ADR changes what the timer reveals, not how.

## Context

The dropdown is two things stacked: the popup — a hosted `NSView` drawing the limit bars, which is
what the app exists to show — and, below it, a column of native items (`Settings…`,
`Troubleshoot…`, `Development tools…`, the update line, `Quit TokenPace`).

The column is opened far less often than the popup is read. Settings gets visited when something is
being configured; Quit, in practice, almost never. Yet both occupied the bottom of every single
open, and the popup — the reason for opening at all — ended a third of the way up a menu whose
remainder was a list nobody came for.

[ADR-0020 §3](0020-troubleshoot-window-and-diagnostics-pipeline.md) had already established that a
menu item can be modifier-gated, and shipped the machinery for it. It applied that to the one item
judged too specialised for everyday use. The question this ADR settles is whether that judgment
generalises — whether the *ordinary* items are also things a user wants on demand rather than
always.

## Decision

**1. Every item carrying an action is hidden unless ⌥ Option is held.**

`Settings…`, `Troubleshoot…`, `Development tools…`, `Quit TokenPace` and its separator, plus
`Insights…` when it is uncommented. They are built `isHidden = true` — the state the menu opens
into — and `menuWillOpen` seeds the real state before the first frame, so opening with ⌥ already
down still shows the full column.

**2. The update line is the exception and stays visible in both states.**

It carries an action (`openReleasesPage`), so a purely mechanical "gate everything actionable" rule
would take it too. But it is first of all a *notice*: the user did not open the menu to invoke it,
and a "new version available" that only appears while a modifier is held is a notification that
does not notify. Its click is a convenience attached to a message, not the reason the row exists.

The same logic covers the error and success lines without any work: they are `NSTextField` rows
*inside* the popup (`addWarningTitle`), never menu items, so hiding items cannot reach them.

**3. A dim italic caption stands where the column was: `hold ⌥ Option for more`.**

Deliberately vague. What ⌥ reveals varies with the build and the state — Troubleshoot and
Development tools are themselves conditional — so a caption promising "actions" or "details" would
be wrong in some states and certainly right in none. "More" holds whatever ⌥ turns out to show.

It is **not a menu item**. It lives in the popup's own view as a sibling of the card, and it is
inert: non-editable, refuses first responder, outside the accessibility tree. There is nothing
behind it, and a caption that looks clickable in a menu is a promise the popup cannot keep.

Italic for the reason the style caption beside a row title is italic: it is a note *about* the menu,
not a fact reported in it. `secondaryLabelColor` rather than the popup's own `dimmedLabelColor` —
that one is tuned for captions inside the card, against the plate's fill, and is barely legible out
on the menu's material. Both are dynamic system colours, so light/dark needs no rule of ours.

**4. A switch turns the caption off, and it is deliberately not an appearance preset value.**

Settings → Appearance › Dropdown, in its own unnamed section, default on. It sits on that pane
because that is where someone looks for it — but it is the one control there that a preset does not
rewrite and Copy config does not carry. It records that its owner already knows the shortcut, which
is a fact about a person rather than about how the dropdown should look; restoring it onto a second
Mac would restore the wrong thing. Membership in `AppearancePresetValues` is what decides that, and
this key stays out of it.

## Consequences

**`Settings…` and `Quit` are unreachable without ⌥.** This is a real departure from the macOS
convention that a status-item menu always offers a visible way out, and it is the cost this ADR
accepts. Three things make it tolerable rather than reckless:

- the caption is on by default, so the discovery path exists unless the user removes it;
- turning it off is an opt-out taken deliberately, by someone who has read what it says;
- ⌥ itself is not discoverable-by-accident but is standard macOS vocabulary for "show me more".

Turning the caption off leaves **no on-screen affordance at all**. That is the intended shape of the
opt-out, not an oversight: it is the state someone chooses precisely because they no longer need to
be told.

**The bottom margin now depends on what follows the card.** `cardBottomInset` is trimmed to 4
*because* a native item follows and `NSMenu` pads above it. With nothing following, the trim framed
the plate against a neighbour that was not there. A separate constant applies in that case, and it is
**8.5, not the 14 of `cardInset`**, because `NSMenu` pads below the hosted view too: measured on a 2×
capture of the real menu, a literal 14 rendered as 18.5 pt against the sides' 13. The same trap as
`cardTopInset`'s 10-instead-of-14 — the constant is not what lands on screen.

"Nothing follows" takes **three** conditions, not two, and the third was missed on the first pass:
hosted in the menu, the caption off, ⌥ up — **and no update line showing**. That line stays visible in
both ⌥ states by decision 2 above, so it is a neighbour like any other; without the check the card took
its lone-plate margin while a row sat directly beneath it. The popup cannot see the menu it is hosted
in, so `refreshUpdateMenuItem` pushes the fact in as `hasVisibleMenuNeighbour`.

**The update line's separator is ⌥-gated even though the line is not.** The separator divides that line
from the action items **above** it; with ⌥ up there are no items above, and it renders as a rule under
nothing, between the card and the notice. So the line stays and its divider goes — they answer
different questions ("is there something to tell you" versus "is there something to divide from").

**The ⌥ transition changes two things at once** — the popup's fitting size and the menu's item count.
`updateTroubleshootVisibility` already re-fit the hosted view for the service rows; the caption rides
that same path.

**The Settings live preview opts out** (`hostedInMenu`, `optionHintEnabled = false`). It has no menu
items, so a caption offering "more" would promise what that surface cannot deliver; and its window
already frames the card evenly by topping the trimmed inset up itself, so letting the popup do it too
would double the gap. ⌥ still works there — it reveals the same on-demand *content* the preview
exists to mirror.

## Alternatives considered

**Keep `Quit` always visible.** The safest option, and the one a strict reading of the platform
convention asks for. Rejected because it defeats the point: the goal is a menu that is the widget,
and one permanent row plus its separator is most of the visual weight the change was meant to
remove. If the caption proves insufficient in practice, this is the first thing to revisit.

**Make the caption a disabled `NSMenuItem`.** Simpler in that it needs no view work. Rejected on
two counts: right-alignment inside a menu item is a paragraph-style approximation rather than a
layout, and a disabled row still reads as a menu row — an item that looks like something one *could*
have clicked, greyed out, which is the opposite of what the caption is.

**Put the switch on General.** Where it first landed, on the reasoning that a non-preset setting
does not belong among preset values. Rejected: the pane a setting lives on is a findability
decision, and someone hunting for a dropdown option looks at Dropdown. The preset question is
answered by the value struct, not by the pane, so the two do not have to agree. An earlier revision
of this work added a cross-pane link from Dropdown to General to bridge that gap; moving the control
made the link unnecessary, and it was removed with it.
