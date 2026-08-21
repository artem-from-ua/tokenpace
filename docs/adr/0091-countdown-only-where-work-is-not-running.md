---
status: accepted
date: 2026-08-14
supersedes: [0029]
---

# ADR-0091: A countdown only where work isn't running

> Replaces [ADR-0029](0029-reset-countdown-selection-by-severity.md) (choosing the reset time by
> a severity table and the `ResetCountdownMode` mode) and partially supersedes
> [ADR-0010](0010-usage-health-and-error-states.md) (the three error phases, 30/60 min
> thresholds), [ADR-0043](0043-unified-reset-line-and-remove-resetnow.md) (a broken `resets_at` →
> ⚠️ instead of bars), and [ADR-0090](0090-menu-bar-answers-can-we-work.md) (the fallback to bars
> for an unresolvable reset; diagnostic bars in the stale phase).

## Context

[#354](https://github.com/artem-from-ua/tokenpace/issues/354) raised a narrow question: the
"both windows calm" branch in `selectReset` picked the **nearest** reset, and after
[#344](https://github.com/artem-from-ua/tokenpace/pull/344) that could name a window whose bar
wasn't even drawn. The ticket offered a choice of three rules.

But any of them left a deeper flaw in place: **the number doesn't say whose it is**. "21m" next to
two bars doesn't point at a window — the user guesses from the magnitude, and the guess breaks the
moment the weekly reset is three hours out. The rule "two oranges → weekly" that would have been
needed would have to be **memorized**: it doesn't read off the screen.

This is the same flaw as in [#278](https://github.com/artem-from-ua/tokenpace/issues/278): the bar
and the countdown are two independent signals, and neither explains the other.

The question turns out to be bigger than #354: **where should a countdown live at all**, so its
referent is unambiguous.

## Decision

### 1. A countdown exists only where there are no bars

The widget has exactly two shapes:

| Shape | When | What it means |
|---|---|---|
| **bars, no number** | work is running on the subscription | the only question is pace — carried by color |
| **glyph + number, no bars** | work has stopped, or costs money | the number is when that state ends |

The glyph next to it unambiguously names the cause, so the question "whose number is this" never
comes up.

**This is not "a binary signal."** Pause + `4d` means "wait 4 days," currency + `4d` means "pay for
4 days"; states that are opposite in meaning are shaped the same. The honest way to put it: number
↔ bars is a **surface switch**, not a signal. The rule is structural (one referent, because there
is one context), not semantic.

### 2. The type enforces the invariant, not a convention

`MenuBarMode.expanded` loses its `resetToShow` field, so "bars + number" becomes
**unrepresentable**, not merely unreachable.

The field's removal took `selectReset` with it (and `ResetSelection`/`ResetToShow`): both of its
call sites lived **inside** `expandedBars` — exactly the path that no longer carries a countdown —
so the whole severity table would have computed a value nobody reads. `BlockingReset` is
untouched: it, not `selectReset`, builds the countdown for bar-free states.

### 3. An exhausted window never draws a bar

Two paths violated this; both are closed.

**A broken `resets_at`.** `blockedResetMode`/`paidResetMode`, when returning `nil`, used to fall
through to the bar path — that's exactly how a data error surfaced, drawing the very red bar the
rule now forbids. A new case, `exhaustedUnknownReset`. This needs a new predicate,
`exhaustedWindowWithoutReset`: `hasBrokenActiveReset` only says "something somewhere is broken,"
and is just as true for a 5h window at 12%.

**The 30–60 min stale phase**, which used to rebuild diagnostic bars next to ⚠️. Bars that stale
invite the one reading they can't support ("here's where I stand"), and the popup already explains
the failure in words.

### 4. Contradictory data gets one signal, not two

`exhaustedUnknownReset` draws a **lone ⚠️** — no pause, no currency — even though the model knows
which of the two glyphs would otherwise apply.

This decision was made **after live verification**, and it corrects this ADR's own original
intent. On screen, a pause claims "you are blocked," while ⚠️ next to it claims "don't trust me";
nothing says the distrust is only about *the time*. The pair reads as a broken widget, not as a
state. So this is the one place where `isBlocked` is true but no glyph appears.

### 5. The ⚠️ threshold is counted in attempts, not minutes

`glyphAfter(for:)` = `max(15 min, 3 × pollInterval)`; `hideBarsAfter` is removed along with the
phase.

A flat 15 minutes would raise ⚠️ after a **single** failed attempt on an inactive machine, because
`PollingEngine.inactiveInterval` itself is 15 minutes. The threshold should mean "we tried,
repeatedly," and that's a **count**, not a duration. `UsageHealth` gets a `pollInterval` field.

**A 429 no longer starts a failure streak.** It's the server saying "not so fast," and
`Retry-After` alone would be enough to raise ⚠️ on a system working exactly as intended. The
backoff and the reason shown in the popup remain unchanged.

### 6. The "Show reset countdown" option disappears

`ResetCountdownMode` is removed: each of its three values chose a behavior that no longer exists.
The key is retired and swept up, like `pauseHidesBars`.

**The change is visible to everyone, including on the default** — not just those who had
"Always" turned on:

| Was | What it loses |
|---|---|
| `.always` | the countdown while fully calm |
| `.smart` (**default**) | **the countdown at orange 5h** |
| `.never` | nothing (in bar-free states the number was already forced from ADR-0090 onward) |

### 7. `.error` draws a crossed-out antenna, not ⚠️

"Can't reach the API" is a routine event; "window exhausted, but the date is broken" is a rare
server bug. Both used to draw the same triangle, and the rare state looked like the common one.
⚠️ is now reserved exclusively for "the data contradicts itself."

## Consequences

### What this buys

- The question "whose number is this" disappears — not as fixed, but as **unrepresentable**.
- #354 closes without picking a rule: the "both calm" branch no longer exists.
- The bar and the countdown can never diverge, because they never coexist.
- The most common state is quieter: an orange 5h window recurs several times a day and heals
  itself with a reset — the countdown there used to blink without asking anything of the user.

### What this costs

- **A distant orange 7d loses its number.** Under the default (`.smart`) it was already silent
  (`showsSevenDayAheadWhenFar`), so for most people this is a no-op; for `.always` it's a real
  loss.
- **Width jumps more sharply.** Switching to ⚠️ collapses the widget to a compact glyph
  (≈22 pt vs. ≈59 pt), shifting neighboring status items. We do **not** reserve a bar slot in
  ⚠️ states: the failure is rare, and keeping 34 pt of empty space for it the rest of the time
  isn't worth it — unlike the palm icon
  ([ADR-0073](0073-awaiting-icon-reserved-slot-and-slide.md)), where the reservation is justified
  by frequency.
- **The flip at the 100% boundary** now redraws the whole composition, not just the color. There
  is no hysteresis anywhere; ADR-0090 named this a cost, and it has grown.
- **A gap between the two surfaces.** The menu bar stays silent in working states, the popup
  always shows resets. Hence the requirement: **the popup's reset line is never gated by
  severity** — otherwise, under `PopupSectionVisibility = .nonCalm`, both surfaces would go quiet
  at once and the number would vanish from the app entirely.

### What stays open

`users-and-goals.md` calls the countdown to reset a useful signal ("will I finish in time").
This ADR doesn't cancel that, it **narrows** it: a countdown passes the "which action would the
user take differently" test only when there's something to decide **about "now."** When work has
stopped, "wait or not" is a decision right now. When work is running at orange, the decision is
"slow down or not," and **color** answers that one.

Whether "calm" should stop meaning "stay silent" at a small **absolute** remaining balance stays
open in [#278](https://github.com/artem-from-ua/tokenpace/issues/278) — but it's now about
`severity` (should the bar turn yellow), not about the countdown.

## Alternatives considered

**An "always weekly" rule in the "both calm" branch** (option B from #354). Would fix the
bar/number mismatch, but would leave the countdown next to the bars — i.e. it would keep the
"whose number is this" question alive in every other branch.

**A "window of the visible bar" rule** (option C). The same, plus a new `hideCalmBar` parameter
(from [#381](https://github.com/artem-from-ua/cc-timer/issues/381) — `hideTopBar`) threaded into
`selectReset` — a coupling [ADR-0086](0086-tri-state-calm-bar-hiding.md) deliberately avoided.

**A two-value option** ("When well ahead" / "When paused only"). Considered and rejected: both
values give sensible behavior, but "paused only" wins on all three criteria (glance speed, noise,
rule simplicity), and keeping the option around for a losing value is the same logic
[ADR-0090](0090-menu-bar-answers-can-we-work.md) already rejected for four other options.

**An optional `reset` in `iconOnlyReset`** instead of a new case. The type would stop guaranteeing
a countdown is present, and `which` without a number would lose its meaning. Putting `"⚠️"` there
as a string is not possible: `resetLabelWidth` measures it with `monospacedDigitSystemFont`, while
the rest of the widget draws an SF Symbol — that would produce two different-looking ⚠️s and a
width jump.

## Verified live

Seven states on a real menu bar (`TOKENPACE_STUB`):

| Stub | On screen |
|---|---|
| `calm-both` | one bar, silence |
| `5h-orange` | two bars, **no number** |
| `credits-active` | € + `5d` |
| `credits-limit-reached` | ⏸ + `5d` |
| `both-red` | ⏸ + `4d` — the **later** of the two resets |
| `idle-blocked` | ⏸ + `4d`, no idle placeholder |
| `broken-reset` | **lone ⚠️** |

Bars and a number never appeared together in any frame.

The stale phases aren't reproducible with a stub (`failingSince` can't be rewound) — unit tests
only.
