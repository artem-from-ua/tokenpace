---
status: accepted
date: 2026-08-17
supersedes: [0081]
superseded_by: [0111]
---

# ADR-0105: `Colors tell me` governs pacing bars only

> **§3 "The `degraded` dot — unconditionally white in the menu bar, yellow in the popup" is
> superseded by [ADR-0111](0111-degraded-dot-is-yellow-on-every-surface.md)**
> ([#410](https://github.com/artem-from-ua/tokenpace/issues/410)): the dot is **yellow on all three
> surfaces** — menu bar, popup, and the Legend page. The argument "a yellow dot is a state with no
> action" didn't survive three objections: `unknown` is also gray and also has no action; the value
> carries a **monotonic scale**, and without a middle step it degenerates into "fine, then suddenly
> bad"; and degradation does have an action — check whether the slowdown is on your end. Along with
> §3, the "White `degraded` dot — a deliberate reduction in visibility" paragraph in Consequences
> and the alternative rejected there ("keep it yellow") both became historical — that's exactly the
> option ADR-0111 chose. **§1, §2, §4, §5, and §6 still stand** — including §1, which ADR-0111
> confirms: yellow is unconditional, the dot doesn't read `ColorAdvice`.

> Supersedes §4 of [ADR-0081](0081-weekly-capacity-gate-for-blue.md) ("The idle pill is
> three-valued" — two states remain, no blue). Confirms
> [ADR-0068](0068-credits-in-use-marker-anatomy.md) (the currency glyph's scale stands alone) and
> [ADR-0097](0097-bar-style-preview-rendered-at-runtime.md) (the tile palette is fixed). Implemented
> in [#381](https://github.com/artem-from-ua/cc-timer/issues/381).

## Context

The row now called **`Colors tell me`**
([ADR-0104](0104-appearance-named-for-behaviour-on-three-layers.md)) had historically reached into
everything with color in the widget. `CalmColorMode.mutesCalm` was read from four different places:

- the pacing-gap strips (`gapColorTarget`) — what the option exists for;
- the **idle pill** "ready to start," which additionally had its own three-valued fill choice
  ([ADR-0081 §4](0081-weekly-capacity-gate-for-blue.md): gray / blue / green);
- the **service-status dot** in the `degraded` state (`statusDotTarget`);
- the **currency glyph** (`creditsIconColor`).

Three of the four answer **different questions** than "how am I spending my limit": can I start,
is the external service up, is money already being spent. The row about bar colors was steering
them indirectly — and this turned out to be more than a cosmetic issue; it blocked the next step.

The step in question: under the **Pressure** style, the entire calm side draws as **zero** —
`pressureLength` = `max(0, gaugeOffset)` ([ADR-0101](0101-pressure-is-the-gauge-ahead-half.md)), so
blue `farBehind`, green "on pace," and yellow "slightly ahead" all give the same minimum pill. The
choice of "which calm hues to keep colored" changes nothing in **length** there — so the row could,
in principle, be hidden.

But a live review revealed the other half of the picture, which the reasoning had missed: **the
zero-length pill still takes a color**. With `slowDownOrSpeedUp` saved and Pressure selected, the
pill on screen was **blue**, with no control on the page that would explain it. Hiding the row
without a matching change to the rendering is a hidden setting coloring a visible label.

## Decision

### 1. Scope narrowed to pacing bars

[`ColorAdvice`](../../Sources/TokenPaceKit/ColorAdvice.swift) is now read only by `gapColorTarget`
and `isYellow` — that is, **only** the 5h/7d strips. The other three consumers are detached (§2–§4).

### 2. The idle pill — always green, on both surfaces

| State | Fill | Word |
|---|---|---|
| `isBlocked` | gray | "waiting for limit reset" |
| everything else | **green** (white when muted) | "ready to start" |

There's no blue pill. Blue meant "ready to start, **and** the week still has headroom to burn" — a
second claim layered onto the first and carried by the same label. Idle answers one question; the
second claim is dropped, not relocated.

Consequence for the types: `BarView.weeklyHeadroom` and `LimitRow.weeklyHeadroom` are **removed** —
the flag existed only to thread the weekly verdict through an inert row that never goes through
`severity`. The weekly gate itself still does its real job further on, on `blueAllowed` for
**active** bars ([ADR-0081 §3](0081-weekly-capacity-gate-for-blue.md) — still stands).

Both surfaces lose this distinction **in the same release**, so the menu bar and the popup can't
diverge on what idle looks like.

### 3. The `degraded` dot — unconditionally white in the menu bar, yellow in the popup

`statusDotTarget(.degraded)` no longer reads any setting and always returns the neutral. Two
reasons, and the second is why this is **unconditional**, not just detached:

- the service dot isn't a pacing signal, and the row about bar colors has no business reaching it;
- **a yellow dot in the menu bar is a state with no action.** Louder states stay colored:
  `partialOutage` (orange), `majorOutage` (red), `underMaintenance` (blue), `unknown` (gray) — each
  of these has something to do about it.

**In the popup the state stays yellow** (`PopupViewController.dotColor`). The asymmetry is
deliberate: there the dot sits **next to the service name and status text**, so color isn't the only
carrier of meaning. In the menu bar it's the only one.

### 4. The currency glyph doesn't read the muting setting

`creditsIconColor` lost its settings branch. Its own scale is **white → orange → red**
([ADR-0068](0068-credits-in-use-marker-anatomy.md)): there's no green or yellow step to mute in the
first place. That branch matched the rest of the function in every state but one — the
**unlimited** cap (`bar == nil`), where it was overriding the neutral foreground. So its entire
effect was to dim "money is being spent," which isn't a pacing verdict.

### 5. Under Pressure, the calm side is muted unconditionally

`gapColorTarget` under `barStyle == .pressure` returns `calmWhite` for every calm state — blue,
green, yellow — **regardless** of `ColorAdvice`. `isYellow` under this style returns `false`
immediately rather than relying on a coincidental match against a tone comparison. The idle pill
follows the same rule (`barStyle == .pressure || colorsTell.mutesCalm`).

This is what makes the gate on the row honest: under Pressure, the setting has **zero** effect —
neither on length nor on color. Pressure is also the worst place for a colored calm state: there's
no strip left to measure, so the hue would be the only remaining channel, reporting a state the
scale has deliberately chosen not to draw.

### 6. Under Pressure the row is **disabled and shows `Slow down`**, not hidden

When `menuBarStyle == .pressure`, the `Colors tell me` row stays in place but goes `.disabled`, and
its highlighted segment becomes **`Slow down`**. This isn't a placeholder: under Pressure, the only
color that remains is orange, "you're spending too fast" — and that's exactly what that segment
names. The control **reports state** instead of offering a choice that would change nothing.

The row sits **in the same card as `Style`** — the gate is two rows above, and the adjacency makes
the reason visible.

**Why not hide it** (the first draft did exactly that): a row that disappears takes its own
explanation with it — the user is left guessing whether the option vanished or moved. A grayed-out
control with an honest value still answers "so what will the colors do?", the question the row
exists for. This matches the pattern already established in neighboring panes
([`AboutPane`](../../Sources/TokenPace/Settings/AboutPane.swift),
[`NotificationsPane`](../../Sources/TokenPace/Settings/NotificationsPane.swift)): an unavailable
feature's toggle shows disabled rather than disappearing — in this project, the gate for **hiding**
something is an ON/OFF toggle ("the feature is off — its parameters don't exist"), and a choice
among three equally valid options has no such precedent.

**The saved value is never touched.** `SettingsModel.displayedColorAdvice` swaps out only what
**gets drawn**; `PersistedConfig.colorsTell` keeps the user's last choice, so switching back to
Gauge or Progress restores it with no "previous value" held in memory. A separate memory field would
be a second copy of what storage already holds, with the usual consequence: two copies drift apart
after a preset, a reset, or a relaunch.

`SegmentedControl` reads `\.isEnabled` and dims **only the ink**, leaving the highlight in place:
the accent fill turns neutral, the text turns secondary. A control that ignores clicks but looks
alive is worse than either extreme.

The change **animates** (`easeInOut` 0.2 s, bound specifically to `menuBarStyle`): the highlight
travels to `Slow down` and back together with the dimming, so both read as one consequence of
clicking the tile. The binding is narrow on purpose — a bare `.animation(_:)` would also animate the
neighboring row's segment changes.

## Consequences

**A simplification visible in the types.** `BarView.weeklyHeadroom`, `LimitRow.weeklyHeadroom`, and
`CalmColorMode.mutesIdlePill(isBlue:)` are removed; the idle row no longer needs a weekly verdict.

**The `idle-week-hot` frame lost its role in the menu bar.** It existed precisely to show a green
pill against a blue one on `idle` — both are now green. The frame stays as a check that the weekly
gate does **not** touch idle. See [ui-verification.md](../guides/ui-verification.md).

**The white `degraded` dot is a deliberate reduction in visibility, and it was checked live.** Two
objections were considered and rejected:

- [ADR-0071](0071-incident-subscriptions.md) (lines 32–35) says `degraded` is **already**
  under-read: people read it as "will be slower," even though part of the functionality may not
  work at all. A white dot makes the state even quieter. Accepted deliberately: the answer to that
  under-reading is **the popup's text and the incident subscription**, which ADR-0071 already added
  — not a yellow pixel in the menu bar. The dot says "take a look," not "here's what's broken."
- [ADR-0013](0013-claude-status-line.md) (line 108) ranks `degraded` **above** `unknown` and
  `maintenance` in severity order — and those stay colored. A formally lower state is now more
  visible than a higher one. Accepted: severity order decides **which** dot to show when components
  disagree, and that hasn't changed; color answers a different question — whether there's an action
  here. `maintenance` and `unknown` have one (the first is a scheduled window with a deadline, the
  second is "we don't know the state"); `degraded` at menu-bar scale does not.

Both objections were weighed, and the maintainer chose white **after a live check, done specifically
in light mode** — that's exactly where the neutral sits closest to the menu bar background and
disappears most easily.

## Alternatives considered

**Hide the row under Pressure.** This was the original decision, abandoned after a live review.
Hiding leaves the user with no answer to "so what's going on with the colors right now?" at the exact
moment the answer is unambiguous, and forces a style switch just to see the saved value — and
switching resets the preset to `Custom`. A gate on "a choice among three equally valid options" also
had no precedent anywhere in the project: all six conditional rows are gated by an ON/OFF toggle, and
the established pattern for "present but inactive" is exactly `.disabled`
([`AboutPane`](../../Sources/TokenPace/Settings/AboutPane.swift),
[`NotificationsPane`](../../Sources/TokenPace/Settings/NotificationsPane.swift)).

**Hide the row but leave the pill colors as they were.** This is the state the live review actually
found: a blue pill with no control on screen. Rejected as worse than either extreme — this is exactly
where the unconditional muting of the calm side under Pressure (§5) came from.

**Keep a "previous value" in a separate field.** Not needed: nothing overwrites `colorsTell` under
Pressure — only what's **displayed** is swapped (`displayedColorAdvice`). An extra field would also
have to be migrated and exported, while always duplicating what already exists.

**Detach the `degraded` dot from the setting but keep it yellow.** The smallest change, and the one
best defended against the objections above. Rejected: a yellow dot in the menu bar carries no
action, and this widget's quiet default exists precisely for states like that. The popup, which has
text, keeps drawing it yellow — so no information is lost, only relocated to where it reads.
