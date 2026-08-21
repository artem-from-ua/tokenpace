---
status: accepted
date: 2026-08-07
---

# ADR-0073: A reserved slot for the awaiting-hand icon, and its slide from below — the first motion animation

## Context

The menu bar is **right-aligned**, so any change to the widget's width shifts everything to its left —
including other apps' status items. `StatusItemView.itemWidth(for:)` computes its width from what is
drawn **right now**, so the widget "breathes" on every data change, and the user's menu bar keeps
rearranging itself.

There are five sources of width, but only one of them matters (diagnosed in
[#283](https://github.com/artem-from-ua/cc-timer/issues/283), spotted by @kintecus in his 2026-08-04
menu bar review, section 4 "Fixed slots"):

| Source | Width | How often it toggles |
|---|---|---|
| **Awaiting-hand icon** ([#233](https://github.com/artem-from-ua/cc-timer/issues/233)) | ≈18 pt | **Dozens of times a day** — the moment a session starts or stops awaiting input |
| Credits icon ([#144](https://github.com/artem-from-ua/cc-timer/issues/144)) | ≈16 pt | 1–2 times per 5-hour window |
| Pause glyph ([#199](https://github.com/artem-from-ua/cc-timer/issues/199), [#227](https://github.com/artem-from-ua/cc-timer/issues/227)) | ≈14 pt | 1–2 times per window, at the moment of blocking |
| Service dot ([#31](https://github.com/artem-from-ua/cc-timer/issues/31)) | 10 pt | Rare — on an incident |
| Reset label format band | varies | ≈once per window (`1h0m` → `59m`) |

Only the first one is high-frequency. The other four fire exactly when the user is already looking at
the widget **for that very reason** — a jump that explains itself costs far less than one that
explains nothing. The hand icon, by contrast, toggles during ordinary work and carries no news about
the widget's layout at all.

The root cause is a property whose name looks like a settings flag but is actually a conjunction with
live data:

```swift
// StatusItemView.swift, before the change
private var showAwaitingInMenuBar: Bool {
    layout?.awaitingInput != nil                   // data
        && PersistedConfig.awaitingInputInMenuBar  // setting
}
let awaitingInset = showAwaitingInMenuBar ? awaitingIconWidth() + Metrics.awaitingIconGap : 0
```

The second half of the context: once the slot is stable, the icon's appearance stops being a layout
event — and that opens up a question that had no point asking before. Until now the project's only
animation was **color** ([ADR-0070](0070-smooth-bar-colour-transitions.md)); geometry was deliberately
never animated.

## Decision

**Reserve the hand icon's slot from the setting, and inside that reserved slot, smoothly slide the
icon out from below and hide it the same way over the same 0.8 s.**

### 1. The slot is reserved from the option, not from the data

`reservesAwaitingSlot` = `awaitingInputEnabled && awaitingInputInMenuBar`, and `awaitingInset` in
`itemWidth(for:)` is computed from it. Drawing the glyph itself still depends on the counter being
present.

**Both toggles are required.** Turning off the master "Show sessions awaiting input" switch (Extra
features) only *disables* the Appearance option — its saved value stays `true`. The condition this
decision replaced covered that case **through data** (`layout?.awaitingInput` is always `nil` while
the master is off), which is exactly why the master now has to be named explicitly, now that the
reservation no longer looks at data. Otherwise ≈18 pt would stay occupied for a feature that is
completely off.

This changes **the meaning of an existing toggle**: "Show awaiting-input icon in the menu bar" now
means "reserve the slot," not "the icon is present this instant." No new setting was added — it would
have been a thirteenth toggle for a layout detail, and the same on-screen position would mean
different things to different users.

The other four sources of width stay as they are (see the table above).

### 2. Advancing the origin has to come from the slot too — otherwise the fix does not work

This is not an implementation detail, it is part of the decision. `drawLeadingDecorations` advanced
`originX` under the same "glyph was drawn" condition, so reserving the width alone would only have
added empty space **to the right** of all the content, while the bars would stay left-aligned — and
keep shifting anyway. Both places now key off `reservesAwaitingSlot`, and the step is taken from the
**measured reservation** `awaitingIconWidth()`, not from the width of the drawn glyph, so the slot and
the glyph can never drift apart by a subpixel.

### 3. Motion is Y-only, with clipping; no fade, no width animation

The icon slides out from under the widget's bottom edge and hides back the same way, clipped to its
own slot. The travel distance is `Metrics.height` (22 pt), not the glyph's measured height: the ~13 pt
glyph is centered in a 22 pt row, so from its resting top edge to the bottom of the row is ≈17.5 pt;
22 clears that with margin and stays one constant instead of a number derived from whatever SF Symbols
returns today.

Width is **not** animated during the motion — it is already stable per §1, and that is the whole
point: the icon's motion moves nothing else.

### 4. A scalar tween — a sibling of `ColorTween`, not a generalization of it

`ScalarTween` / `ScalarTweenSet` / `ScalarTweenKey` — a new AppKit-free file in Kit next to
`ColorTween.swift`, with the same three-branch `update`, the same `pruneStale(45)`, the same
`TweenCurve.smoothstep`, and **the same end-of-run epsilon** (the same `Date` quirk, and without it a
tween stays "almost done" forever, and the frame timer never winds down).

Generalizing `ColorTween` over a lerpable type was rejected: its doc comments are ADR-0070 written
into code, and generalizing it would rewrite ~140 lines of load-bearing prose for the sake of one new
call site. A separate `ScalarTweenKey` — because the `TweenKey` contract explicitly says "the identity
of one animated **color**," and this has no color to speak of.

`ScalarTween.defaultDuration` is **pinned** to `ColorTween.defaultDuration` (0.8 s) rather than
repeated as a literal: a single toggle can change color and presence at the same time, and two
different numbers would produce a noticeably different landing time. A test guards this.

### 5. The "icon is disappearing" state lives in the animator

When the counter becomes `nil`, the view has no memory at all of an icon that is on its way out — so
per [ADR-0070](0070-smooth-bar-colour-transitions.md) §3, the state lives in `ColorAnimator` (a second
registry, `scalars`), not on the view.

Hence **the feature's central invariant**: the draw site calls `resolve(.awaitingIcon…)` **on every
frame where the slot exists**, including when nothing is awaiting (`target: 0`). This buys two things
— the key stays alive, so the outbound animation is even possible, and the key keeps getting
"touched," so `pruneStale` won't discard it while the slot is on screen. A discarded key would come
back through the "first appearance" branch and jump — the same class of bug as the 5 s → 45 s
threshold in ADR-0070.

The same site also caches `lastAwaitingUrgency`: a hand icon that is sliding away has no urgency in
the layout (the counter is already gone), so the red hand would turn gray mid-slide.

### 6. First appearance does not slide

The "first appearance of a key adopts the target with `duration: 0`" branch, inherited from
`ColorTweenSet`, produces exactly the behavior needed: a session that was already awaiting input when
the app launched is a **current state**, not a change, so the icon simply is. Consequence for the
toggle: turning the option on while sessions are already active registers the key for the first time →
an instant appearance. This is deliberate — the user just asked for this, and a slide-in would read as
lag.

### 7. Reduce Motion disables the motion but not the color fades

With `NSWorkspace.accessibilityDisplayShouldReduceMotion`, the motion's duration becomes 0 — the glyph
simply appears and disappears, and the frame timer never spins up at all. Toggling the setting
mid-slide lands anything in flight (subscribed to
`accessibilityDisplayOptionsDidChangeNotification`).

ADR-0070's color transitions **keep working**: the setting is about motion — Apple's own wording says
"UI should avoid large animations, especially those that simulate the third dimension" — and nothing
moves in a crossfade. Reduce Motion is not a request for a static menu bar; the pacing colors would
change either way, only abruptly — which is exactly the flicker ADR-0070 removed.

### 8. 30 fps re-checked from scratch, not inherited

ADR-0070 justified 30 fps on the grounds that "with no **moving edge**, 30 is enough — there's nothing
to strobe." A moving edge now exists, so the number was re-checked: ~24 frames over 0.8 s with an
≈18 pt travel gives ~0.75 pt per frame, and smoothstep puts the fastest phase in the middle, where the
steps are least noticeable. Doubling the frame rate would double the number of full `snapshotImage()`
calls for a decoration that appears dozens of times a day. 30 stays; the lever is still the same one
constant.

### 9. The `TOKENPACE_AWAITING_CYCLE` stub

`TOKENPACE_AWAITING` freezes the counter, and a live watcher cannot be toggled on demand — the
transition has nothing to reproduce it with. A handle on the **existing** stub, rather than a new
`StubScenario` case: the slide needs checking against every data world the icon shares the widget with
(bars, `blockedReset`, the pause glyph), and a scenario would pin down just one; meanwhile `_DAYS` /
`_PROJECTS` keep working, so the case "the red hand stays red all the way down" stays reachable. It
ticks through `reRenderForCurrentTime()` (not a bare `refreshStatusImage()` — the ADR-0070 trap) in
`.common` run-loop mode.

## Consequences

- **The cost is ≈18 pt of stable empty space** to the left of the bars while the queue is empty, for
  anyone with the indicator turned on. Stable emptiness reads as background over the course of a day;
  a jump recaptures attention every single time. Anyone who keeps the indicator off pays nothing.
- **The toggle's meaning changed** (it now reserves a slot, rather than describing the current screen)
  — with no new setting.
- **The "geometry never animates" policy (ADR-0070) is narrowed, not repealed.** What animates is
  the motion of **a single decoration inside a reserved slot**; the gap length and the marker position
  still jump — there, an animation would hide exactly the fact the bar exists to show.
- **The unconditional-`resolve` invariant is fragile.** If a future refactor skips the call when the
  counter is `nil`, the outbound animation will silently die, and the key will be discarded after
  45 s. Guarded by comments at both ends.
- Rejected: **fade** (the edge doesn't read as clipped, the motion is less legible), **animating the
  width** (24 recomputations of `statusItem.length` per animation, and neighboring items would ride
  along — exactly what the fix removes), **reserving all five slots** (the review's original proposal:
  ≈58 pt of reserved space on top of the 34 pt of bars, mostly empty ~95% of the time — the calm state
  paying for the emergency state on a surface where width is already scarce), **a separate setting**
  (a thirteenth toggle for a layout detail).
- Deliberately **not** animated: the pause glyph and the currency symbol — they toggle 1–2 times per
  window, their slot is not reserved (see the table), and motion without a reserved slot would shift
  their neighbors.

## Related

- [ADR-0070](0070-smooth-bar-colour-transitions.md) — the color transitions; this ADR borrows the
  duration, the curve, the epsilon, the timer discipline, and the rule "state lives outside the view."
  The `framesPerSecond` argument there is about color only — for motion, the number was re-checked
  (§8).
- [ADR-0066](0066-detect-sessions-awaiting-input.md) — the awaiting-input indicator itself.
- [#283](https://github.com/artem-from-ua/cc-timer/issues/283) — the ticket with the diagnosis and the
  source table.
