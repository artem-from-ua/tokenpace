---
status: accepted
date: 2026-08-13
supersedes: [0063, 0086]
superseded_by: [0091]
---

# ADR-0090: The menu bar answers one question — can we work

> **Postscript ([#381](https://github.com/artem-from-ua/cc-timer/issues/381)).** The "an option
> that adds nothing" logic has been applied twice more, and both times not by removing the
> control but by narrowing its scope
> ([ADR-0105](0105-color-advice-governs-pacing-bars-only.md)): the idle pill lost its blue state
> ("ready to start" + "there's something to burn" was two answers on one label), and the
> `Colors tell me` row under Pressure **becomes disabled and shows `Slow down`** — there, the only
> color left is orange, so the control would just report a state rather than offer a choice that
> changes anything. The row this ADR reduced to two segments is now called
> `Hide the top 5h bar`
> ([ADR-0104](0104-appearance-named-for-behaviour-on-three-layers.md)); the behavior hasn't
> changed.

> **Partially superseded by [ADR-0091](0091-countdown-only-where-work-is-not-running.md).** Two
> bar fallbacks were removed: an unresolvable reset for an exhausted window now yields
> `exhaustedUnknownReset` (a lone ⚠️), and the stale phase no longer rebuilds diagnostic bars next
> to the glyph. The countdown disappeared from `.expanded` entirely, so
> `AppearancePresetValues` went from nine fields to eight. Still standing: the three mutually
> exclusive states, `subscriptionExhaustedWhileCovered` as the bar-hiding predicate, and the
> mutual exclusivity of "pause ↔ currency."

> Replaces [ADR-0063](0063-unified-pause-hides-bars.md) (the single "Pause icon hides bars"
> toggle) and [ADR-0086](0086-tri-state-calm-bar-hiding.md) (three-way calm-bar hiding). Both left
> a setting in place where the answer follows from the data.

## Context

Menu bar bar management had sprawled across **four** independent options in the Appearance pane:

| Option | What it decided |
|---|---|
| `pauseHidesBars` ([ADR-0063](0063-unified-pause-hides-bars.md)) | whether to hide bars under the pause icon |
| `showExtraUsage` (#144, #146) | whether to draw the currency icon |
| `awaitingInputInMenuBar` ([ADR-0073](0073-awaiting-icon-reserved-slot-and-slide.md)) | whether to reserve the palm-icon slot |
| `CalmBarHiding.sevenDay` ([ADR-0086](0086-tri-state-calm-bar-hiding.md)) | which calm bar exactly to hide |

Sixteen combinations — while the user only has one meaningful choice: whether to remove the top
5-hour bar while it has nothing to say.

### A bug found along the way: two icons at once

At an exhausted spending cap (`spend_limit_reached`), the widget drew **the pause and the currency
sign side by side**:

```swift
isActive        = enabled || spendLimitReached    // → true  → currency icon
creditsCanCover = enabled && !spendLimitReached   // → false → isBlocked → pause
```

`drawLeadingDecorations` draws leading icons sequentially, so both ended up on screen. At the same
time, [ui-state-truth.md](../reference/ui-state-truth.md) **already** declared that pair
impossible — meaning the invariant was written down, and violated. The reasoning there was
mistaken: it conflated "credits are active" (`isActive`, the icon's gate) with "credits cover it"
(`creditsCanCover`, the blocking gate).

## Decision

**The menu bar does not show credits status. It shows whether we can work.** Three mutually
exclusive states:

| State | Widget | Predicate |
|---|---|---|
| Can work on the subscription | pacing bars | otherwise |
| Can work, but paying money | currency sign + countdown, **no bars** | `subscriptionExhaustedWhileCovered` |
| Cannot work | pause + countdown, **no bars, no currency** | `isBlocked` |

Mutual exclusivity is by construction: `CreditsPacing` splits the last two on `creditsCanCover`, so
both can never be true at once. The icons no longer compete: under `blockedPause`, the credits
marker is zeroed out at the `layout.with(...)` seam.

### Why the "paying money" state doesn't need bars

This is the most contentious part, because it **rolls back** a deliberate decision from
[ADR-0063](0063-unified-pause-hides-bars.md), which narrowed the hiding predicate from
`mainWindowExhausted` to `isBlocked` with exactly the reasoning "work continues on a paid rate,
that's not a stop." The objections are addressed point by point, and none held up:

1. **"The 5-hour window will refill → you'll stop paying"** — false. If the 7-day window is what's
   blocking, refilling the 5h one changes nothing: you keep paying until the **blocking** window
   resets. And that's exactly the number the countdown shows
   (`BlockingReset.forSubscriptionExhausted` — the latest exhausted token reset).
2. **"The 7-day bar tells you it's waiting for a reset"** — that's not an action *right now*
   ([users-and-goals.md](../reference/users-and-goals.md): "is there an action the user would take
   differently?"). Planning ahead isn't a glance task, and the dropdown gives you more in one
   click.
3. **"The blue idle pill tells you no session is running"** — in this state it offers no choice:
   you can always start, the only question is whether it costs money — which the currency sign
   already tells you.
4. **"The bar shows depth beyond 100%"** — the server clamps `utilization` at 100
   (`CreditsPacing`), so that information doesn't exist even today.

"Not a stop" ≠ "needs bars." The state really is a working one — and that's exactly why its marker
is the **currency sign**, not the pause. But the bars, pinned to the ceiling, carry no pacing
information, and [users-and-goals.md](../reference/users-and-goals.md) says outright that
**silence is a valid state**: the absence of a signal needs the same justification as its
presence, and often wins.

### The predicate is `subscriptionExhaustedWhileCovered`, not `shouldShowIcon`

The tempting mistake is to tie hiding to whatever drives the icon. `shouldShowIcon` rests on
`anyBaseLimitExhausted`, which counts **per-model** sub-windows, and those don't gate work at all
(this is stated directly in `CreditsPacing`). Then an exhausted Opus/Mythos sub-window would hide
the 5h/7d bars while both real windows are healthy — on the most common frame of all.

### The data-health axis doesn't collapse into the mode

`MenuBarLayout` is split along two axes: `mode` is a function of **data freshness and
availability**; `credits`/`blockedPause` is a function of **money and blocking**. The three-way
split lives in the second axis and doesn't replace the first. Otherwise stale /
`usagePollingOff` / `nothingMonitored` would lose their place.

The practical consequence: bar construction was pulled out into `expandedBars`, and the diagnostic
path (30–60 minutes of failures) routes **there**, not into `make`. Otherwise a stale, exhausted
snapshot would silently lose its diagnostic bars — for exactly the users who are blocked or
paying — and a snapshot an hour old has no business claiming "blocked **right now**."

### Four options disappear

- **`pauseHidesBars`** — hiding becomes the only behavior. ⚠️ This is a **behavior change, not a
  no-op**: `true` was only the `Chill` preset's value, while the factory `Work harder!` and
  `Control freak` kept bars next to the pause.
- **`showExtraUsage`** — the icon now follows the data. It already stays silent until credits are
  in play, so the opt-out let people hide the only signal that money is being spent.
- **`awaitingInputInMenuBar`** — detection and display become one decision. The cost is named
  outright: under [ADR-0073](0073-awaiting-icon-reserved-slot-and-slide.md) the toggle meant
  "reserve ≈18 pt," and now everyone who has the feature on pays for it. ADR-0073's point is
  preserved — the slot is reserved based on an **option**, there's just one option now.
- **`CalmBarHiding.sevenDay`** — the row names the bar ("Hide 5h (top) bar"), so the segments only
  say *when*: `When it's calm` / `Never`. This rolls back the symmetry from ADR-0086, which cost a
  control whose name couldn't be read as a single sentence.

## Consequences

### Migrating the old boolean key

`hideCalmSevenDayBar = true` → **`.fiveHour`**, not `.never`. That user was asking for **fewer**
bars during calm periods, and `.fiveHour` still gives that — one bar while calm, both on
orange/red. `.never` would give the opposite of what was asked. The retired raw value
`"sevenDay"` decodes the same way.

ADR-0086's three-way control never **shipped** (the last tag was `v0.76.0`, the control landed in
0.88.0), so no stored `"sevenDay"` from the new control exists; only the old boolean key, present
in releases from 0.35.0 onward, needs migrating.

### Presets slim down

`AppearancePresetValues` goes from twelve fields to nine. Two of the three removed
(`pauseHidesBars`, `awaitingInputInMenuBar`) were the only thing distinguishing `Chill` from
`Work harder!` beyond palette, style, and ticks. The presets don't merge, but the margin
disappeared — so a **pairwise-inequality** test was added: otherwise `matching(_:)` would start
silently naming the wrong preset, and the "Custom" segment would lose its meaning.

### Config compatibility

New builds read old dumps safely — `Codable` ignores unknown keys (the same precedent as the
retired `farBehindInterval`). **The reverse breaks**: an older build won't read a new dump,
because its `try c.decode` throws on the missing key. There's no protection on our side; worth
noting in the release notes.

### Orphaned keys

The three removed keys stay around as `Key.retired…` constants in
`resetAppearanceToDefaults()`, following the `retiredFarBehindInterval` precedent. Along with
them, two pre-#227 legacy keys get swept up (`hideBarsWhenBlocked`, `showBlockedPause`) — the
migration that was their only cleanup mechanism is retired together with the key that fed it.

### The cost

- `MenuBarMode.blockedReset` → `iconOnlyReset`: "blocked" no longer describes both bar-free
  states.
- `resetLabelWidth` motivated its label maximum through `forBlocked`; now there are two entry
  points.
- The states differ by **width** (a bar block is 34 pt), and there is no hysteresis anywhere at
  the `>= 100` boundary. The 7-day window drifts, so `99.9 → 100.0 → 99.7` is real: today that's a
  color flicker; after this change it's a width flicker that shifts neighboring widgets. Verify
  live; a separate hysteresis ticket if needed.
