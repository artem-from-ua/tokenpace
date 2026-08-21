# Reading the menu bar

A reference **from the reader's side**: what does what's on screen right now actually mean. Two
neighboring pages solve the inverse problems — [ui-state-truth.md](ui-state-truth.md) says how to
**draw** a state, and [bar-status-conditions.md](bar-status-conditions.md) says under which data a
bar takes on which color.

The English version of steps 1-2 below is meant for the README and the in-app help.

## Two independent axes

Read separately from everything else and present in **any** mode:

- **The dot on the right** — Claude service status (#31). Colored means there's a problem on
  Anthropic's side. Drawn even when the widget shows nothing else: in "polling disabled" mode it's
  the only live signal.
- **The hand on the left** — a Claude Code session is awaiting input (#233). The most frequent
  decoration: per [ADR-0073](../adr/0073-awaiting-icon-reserved-slot-and-slide.md) its slot is
  permanently reserved, so the widget doesn't jitter dozens of times a day.

Now the widget itself.

## Step 1. Is there a number?

A countdown appears **only** when work is not running on the subscription
([ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md)). If a number is present, the
glyph next to it names the reason:

| On screen | State | The number means |
|---|---|---|
| ⏸ + number | work has **stopped** | when it resumes |
| ¤ + number | work continues, but **at a cost** | when it stops costing money |
| ⚠️ alone | the data **contradicts itself** — the window is exhausted but its `resets_at` is broken | nothing; we don't know the time |
| slashed antenna | **can't reach the API** past the threshold | nothing; there's no data |
| `zzz` | polling **disabled by the user** (#341) | nothing; it's a choice, not a failure |

There are no bars in any of these states: a window at 100% carries no pacing information, and the
only thing worth attention is when it ends.

**Why ⚠️ appears without a glyph.** A pause would assert "you're blocked" right next to a sign that
disclaims the data. Nothing on screen says the distrust applies only to the time, so the pair would
read as a broken widget. Contradictory data gets one signal.

## Step 2. No number → read the bars

Work is running on the subscription. The bars show **pace**, not remaining quota.

| What you see | What it means |
|---|---|
| **one bar** | the 5-hour window is calm and steps aside — what's left is the weekly one |
| **two bars** | the 5-hour window is ahead of pace, so it stays on screen. The top one is 5h, the bottom is 7d |
| **orange** | this window is running ahead of pace. Nothing is blocked — it's a **forecast** |
| green, yellow | pace is normal |
| blue | you're noticeably **behind** pace — you could speed up |

Two caveats:

- **"One bar = 5h is calm" holds under the default
  [`TopBarHiding`](../../Sources/TokenPaceKit/TopBarHiding.swift)` = .untilItNeedsAttention`** — the
  `Until it needs attention` segment in the "Hide the top 5h bar" row (renamed from
  `CalmBarHiding.fiveHour` in [#381](https://github.com/artem-from-ua/cc-timer/issues/381)). Anyone
  who picked `Never` always sees both.
- **Idle is a different reason for one bar.** When there's no active session, the 5-hour window
  doesn't exist at all ([ADR-0027](../adr/0027-session-idle-no-phantom-reset.md)), and its bar is
  drawn as zero ([ADR-0078](../adr/0078-idle-drawn-as-zero-in-both-styles.md)). Same pixel, different
  story.

## Invariant

**A bar never carries a countdown, and a countdown never carries bars.** They never appear together
— and that's a property of the type: `MenuBarMode.expanded` has no field for a number, so that pair
is unrepresentable.

Practical consequence: if you see a number, look at the glyph, not the bars — they aren't there.

## What the menu bar doesn't say

- **The absolute percentage.** Neither "88%" nor "12% left" — nowhere, in any style. This is
  deliberate: a bare level doesn't clear the "what action would the user take differently" test
  ([users-and-goals.md](users-and-goals.md)). Percentages live in the popup.
- **Whether the quota will cover a specific task.** The widget doesn't know what you're about to do.
  It knows whether your **current pace** leads to exhaustion — that's what the color says.
- **Time to reset while working.** One click away, in the popup: the reset line is on every limit
  and never hidden.

## English — for the README and in-app help

> **Reading the menu bar**
>
> **Step 1. Is there a number?**
>
> A countdown appears only when work is not running on the subscription. If you see one, look at the
> glyph beside it:
>
> - **Pause + number** — work has stopped. The number is when it resumes.
> - **Currency + number** — work continues, but you are paying for it. The number is when it stops
>   costing money.
> - **⚠️ alone** — a limit is spent but the server did not say when it resets.
> - **Slashed antenna** — the app cannot reach the API.
> - **`zzz`** — usage polling is switched off. Nothing is wrong.
>
> There are no bars in any of these states: a window at 100% carries no pacing information, and the
> one thing worth knowing is when it ends.
>
> **Step 2. No number? Read the bars.**
>
> You are working on the subscription. The bars show pace, not remaining quota.
>
> - **One bar** — the 5-hour window is calm and steps aside; what you see is the weekly one.
> - **Two bars** — the 5-hour window is ahead of pace, so it stays on screen. The top bar is the
>   5-hour one, the bottom is the weekly.
> - **Orange** — that window is running ahead of its pace. Nothing is blocked; it is a forecast.
> - **Blue** — you are well behind pace and could speed up.
> - **Green, yellow** — nothing to act on.
>
> A bar never carries a countdown, and a countdown never carries bars.

## Related documents

- [ui-state-truth.md](ui-state-truth.md) — how to draw state (metrics, anatomy, impossible combinations)
- [bar-status-conditions.md](bar-status-conditions.md) — under which data a bar takes on which color
- [users-and-goals.md](users-and-goals.md) — the "useful signal" criterion
- [ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md) — the decision that the
  countdown lives only in barless states
- [ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md) — "can we work" as the single question
