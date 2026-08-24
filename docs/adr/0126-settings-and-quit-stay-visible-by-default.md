---
status: accepted
date: 2026-08-24
supersedes: [0117]
---

# ADR-0126: `Settings…` and `Quit` are visible by default, behind a switch rather than a modifier

> **Supersedes D1 of [ADR-0117](0117-dropdown-actions-behind-option.md) for two of its five items.**
> `Settings…`, `Quit TokenPace` and Quit's separator now follow a default-on switch instead of ⌥.
> **The rest of 0117 still stands in full**: `Troubleshoot…` and `Development tools…` remain ⌥-only
> (D1 for those), the update line remains the always-visible exception (D2), the caption and its
> switch are untouched (D3, D4), and the mechanism — the modifier-polling timer, `isAlternate` being
> inert in a status-item menu — is unchanged.

## Context

ADR-0117 hid every action item behind ⌥ Option and named the price in its own Consequences:

> **`Settings…` and `Quit` are unreachable without ⌥.** This is a real departure from the macOS
> convention that a status-item menu always offers a visible way out, and it is the cost this ADR
> accepts.

It also wrote down what to do if that cost turned out to be too high. Under "Alternatives
considered", having rejected keeping Quit visible:

> If the caption proves insufficient in practice, this is the first thing to revisit.

It did prove insufficient, and this record is that revisit. The failure mode is the one 0117
described rather than a new one: a menu whose only way out is a modifier is a menu some people
cannot leave, and the single dim caption carrying that knowledge is both easy to miss and, by
0117's own D4, switchable off.

What 0117 got right is not in question. The popup is what the app exists to show, and a column of
rarely-used rows under it was real clutter. The correction is narrower than a reversal: the column
splits, and only the half that answers the platform convention comes back.

## Decision

### D1. Two items and one separator follow a switch, not ⌥

`Settings…`, `Quit TokenPace` and the separator above Quit are shown or hidden by
`PersistedConfig.alwaysShowActionItems`, **default-on**. With the switch on they are in the menu in
both ⌥ states; with it off, ADR-0117's behavior is restored exactly.

They are the way in and the way out — the two entries the platform convention is actually about.

### D2. Everything else in the column stays ⌥-only

`Troubleshoot…` and `Development tools…` are unchanged: specialist entrances, reached when
something is already wrong, and the reason 0117's clutter argument was right in the first place.
Quit's build tag (`(dev build …)` / `(stub …)`) also stays ⌥-revealed — it identifies the running
process for whoever is debugging it, and a permanently tagged Quit is noise on a machine that runs
several builds at once.

Revealing the diagnostic pair alongside the everyday two would put the menu back to its pre-0117
shape and lose what that ADR bought.

### D3. The caption is untouched, and the two switches are independent

`hold ⌥ Option for more` keeps its two conditions (`optionHintEnabled && !optionHeld`) and its own
switch stays live. It is **not** suppressed when the items are pinned, and the caption's toggle is
**not** disabled.

The reason is that the caption was never mainly about the action column. ⌥ expands the widgets
themselves — the per-provider data ages, the detail rows' wording (`used`, `resets in`), the
ruler's scale ticks and the style name, `stand by … for green`, incidents in place of the service
rows, `active` on the credits badge. That is exactly the vagueness 0117 D3 built into the word
"more", and it is what keeps the caption true with `Settings…` on screen.

So the two rows in Appearance › Dropdown act on their own in all four combinations. The new switch
sits **below** the caption's, second in the same unnamed section.

### D4. The default flips for existing users, deliberately and without migration

An absent key reads as `true`, so everyone updating from a build with 0117's behavior gets the
items back on first launch. This is intended: the conventional shape is what a menu should have
before anyone configures anything, and the ⌥-only column becomes the thing a person chooses. No
migration runs, and none is wanted — there is no prior explicit `false` to preserve.

## Consequences

**The clutter 0117 removed comes partly back, and that is the trade.** Two rows and a separator sit
under the popup on every open. The popup is still first and still the reason the menu exists; what
is gone is the claim that the menu is *only* the widget.

**`cardBottomConstant` takes a fourth condition.** "Nothing follows the card" now requires hosted in
the menu, ⌥ up, no update line — **and** the items not pinned. Miss it and the card takes its
lone-plate margin (8.5) while `Settings…` sits directly beneath, which is the layout fault 0117
already names in both directions.

**The update line's separator no longer answers to ⌥ alone.** It divides that line from the items
above it, and those items can now be there with ⌥ up. Two places decide it — the ⌥ swap and
`refreshUpdateMenuItem`, which runs while the menu is **closed**, after an update check or an
install verdict — so both read one computed `actionItemsVisible`. They agreed by accident while both
read ⌥; with a switch in the mix they would have drifted the first time one was edited.

**The ⌥ poll must not touch `UserDefaults`.** The timer fires 20 times a second, so the switch is
cached on `AppDelegate` and re-read in `menuWillOpen` — the same contract the caption's key has. The
cache changes only before the forced desync, so the poll's early return stays correct: inside a
tracking session nothing but ⌥ moves.

**The menu's built state now depends on a setting.** 0117's items were built hidden because that
matched the state the menu opens into; with the switch on, the common state is visible. The three
switched items are therefore built from the setting, read once at menu-build time — otherwise the
first frame of the first open flickers, in the mirror image of the case that comment was written to
prevent.

**A state exists that never did before:** the caption drawn *above* visible action items, with ⌥ up.
It is legible — the caption is right-aligned and dim, the items are ordinary menu rows — but it is
new, and it is the combination to look at when checking vertical rhythm.

## Alternatives considered

**Leave 0117 alone and rely on the caption.** The status quo. Rejected by the evidence 0117 asked
for: the caption is one dim line, it is switchable off, and a menu whose exit is a modifier is a
menu someone can be stuck in.

**Reveal the whole column when the switch is on.** Simpler to describe, and it makes the switch a
plain "undo ADR-0117". Rejected: `Troubleshoot…` and `Development tools…` are exactly the rows 0117
was right about, and pulling them back would trade a real gain for symmetry.

**Suppress the caption when the items are pinned.** Considered and briefly planned, on the reading
that the caption advertises the action column and would be announcing something already on screen.
Wrong: what ⌥ mostly reveals is on the widgets, not in the menu. Suppressing the caption would have
hidden a true statement about the data rows, which is the opposite of what D3 of 0117 is for.

**Disable the caption's toggle while the new switch is on.** Follows only from the suppression above,
and falls with it. It would also have put a greyed control above the row explaining why — a shape
that reads as a bug.
