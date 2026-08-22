# Conditions that put bars into each status

An exhaustive reference: **under exactly which conditions each bar type takes on each status/color**.

Why this exists: `severity`, gap color, marker color, and journal bucket are **four different
restatements** of the same predicate, scattered across Kit and AppKit. They can drift apart silently.
This document collects all the branches in one place, with a code-line reference for each.

> **Sources of truth, not a retelling.** Every claim here has a supporting line. If the code and the
> document disagree — the code is right, and the document must be fixed in the same PR.

Related documents: [ui-state-truth.md](ui-state-truth.md) (bar anatomy and metrics),
[menu-bar-signals.md](menu-bar-signals.md) (the inverse problem — how to read what's already on
screen: first "is there a number," and only then the bars),
[users-and-goals.md](users-and-goals.md) (why status exists at all),
[ADR-0061](../adr/0061-far-behind-blue-pacing-zone.md) (the blue zone),
[ADR-0044](../adr/0044-dynamic-pacing-threshold.md) (the dynamic ahead threshold),
[ADR-0078](../adr/0078-idle-drawn-as-zero-in-both-styles.md) (idle drawn as zero).

---

## 1. Bar types and what's even available to them

Not every bar can take on every status. This is the most common source of bogus mockups.

The "Pacing blue" column is about the `farBehind` **zone** — i.e., a **status** — not about any blue
pixel in general (everything blue in the app now shares one `ColorRole.blue`).

| Bar type | Source | Window | Pacing blue? | Where it's drawn |
|---|---|---|---|---|
| **h5** — 5-hour | `snapshot.fiveHour` | 18,000 s | **yes** | menu bar + popup |
| **d7** — 7-day | `snapshot.sevenDay` | 604,800 s | **yes** | menu bar + popup |
| **Opus / Sonnet** | `snapshot.sevenDayOpus/Sonnet` | 7d-paced | **no** | popup only |
| **scoped per-model** | `snapshot.scopedModelWindows` | 7d-paced | **no** | popup only |
| **credits (money)** | `snapshot.spend` | calendar month, UTC | **no** | popup only |
| **idle-h5** | placeholder | none | **no** — has no pacing | menu bar + popup |

**Why blue only on h5/d7.** Blue says "the **week** has headroom you aren't using." Per-model rows
are slices of that same week, so the advice would be pointed at itself; credits aren't a token window
at all. Both get `blueAllowed: false` **in the model**
([PopupLayout.swift](../../Sources/TokenPaceKit/PopupLayout.swift),
[CreditsPacing.swift](../../Sources/TokenPaceKit/CreditsPacing.swift)), and `behindColor` hands them
green at the very first check. The menu bar has no per-model bars at all.

> Before [ADR-0115](../adr/0115-no-blue-on-per-model-windows.md) this was done by the render flag
> `PopupBarView.isBaseLimit`, set by row index. That flag was the cause of the discrepancy below: the
> model didn't know about it.

**Why "no" for idle.** The idle bar has no pacing as such — it doesn't go through `severity` and
can't take on `farBehind`. Its fill is a "ready to start" state, not a verdict: since
[#381](https://github.com/artem-from-ua/cc-timer/issues/381) it's **always green** (gray when
blocked), and the weekly gate no longer factors into it at all. Details in §6.

> **Journal and UI agree — since [ADR-0115](../adr/0115-no-blue-on-per-model-windows.md).**
> `PacingBucket.of` reads the same `blueAllowed` the renderer does, and per-model rows have it
> `false` **in the model**, so a scoped window can never get the `sev: "blue"` the user never saw.
>
> This used to state the same claim on a different basis — "per-model rows carry the same weekly
> gate" — and that basis **was wrong**. The gate closes only when the week is running ahead of pace;
> during a calm week it's open, and blue was written to the file while the popup muted it via its own
> `isBaseLimit`. In the maintainer's August journal this produced **2,214** scoped-blue entries.
> The v4 migration recomputed them as green, leaving `sevRaw: "blue"` in place.

---

## 2. The shared skeleton: four restatements of one predicate

| # | Location | What it returns | Line |
|---|---|---|---|
| 1 | `BarLayout.severity` | `PacingSeverity` (Kit) | [PacingModel.swift:265](../../Sources/TokenPaceKit/PacingModel.swift) |
| 2 | `PacingBucket.of` | bucket for jsonl | [PacingBucket.swift:49](../../Sources/TokenPaceKit/PacingBucket.swift) |
| 3 | `aheadColor` / `behindColor` | gap `NSColor` | [PopupViewController.swift:645, 665](../../Sources/TokenPace/PopupViewController.swift) |
| 4 | `isFarBehind` | the phrase "far behind pace" | [PopupViewController.swift:2592](../../Sources/TokenPace/PopupViewController.swift) |

`StatusItemView.gapColorTarget` ([:1043](../../Sources/TokenPace/StatusItemView.swift)) is **not** a
fifth restatement: it reads `severity` and delegates to `behindColor`.

### Constants

| Constant | Value | What it does |
|---|---|---|
| `pacingOrangeOverrideSeconds` | 1200 s (20 min) | window ending → any lead turns orange |
| `pacingBlueStartOverrideSeconds` | 1200 s (20 min) | window starting → blue doesn't flash |
| `aheadThreshold(timeFraction:)` | `0.16 × (1 − t)` | yellow→orange boundary, **dynamic** |
| `behindThreshold(...)` | 5h: 0.40, 7d: ≈0.2857 | green→blue boundary, **fixed in wall-clock time** |
| `farBehindWidthMultiplier` | 2 | multiplier on the base width, **a constant** (not a setting) |
| `blueAllowed` | Bool | whether blue is allowed for this bar at all |

`behindThreshold` = `blueBehindWidthSeconds × 2 / windowDurationSeconds`, with a base of 60 min (5h)
and 24 hours (7d). It used to be user-configurable (`FarBehindInterval`); now the multiplier is fixed,
and the question "should blue be drawn at all" has moved entirely into `blueAllowed`
([PacingModel.swift](../../Sources/TokenPaceKit/PacingModel.swift)).

### `blueAllowed` — the weekly-capacity gate

`blueAllowed` is set when a bar is built and answers the question "does this bar have the right to
advise speeding up":

| Bar | `blueAllowed` |
|---|---|
| d7 | always `true` — doesn't gate itself |
| h5 | `PacingModel.weeklyHasHeadroom(in:now:)` |
| Opus / Sonnet / scoped | **always `false`** — they are slices of the same week that blue is talking about ([ADR-0115](../adr/0115-no-blue-on-per-model-windows.md)) |
| credits, idle placeholders | `false` — they have no pacing |

`weeklyHasHeadroom` = `d7.pacing == .onPaceOrBehind && d7.usageFraction < 1`, i.e., the d7 bucket ∈
{blue, green}. **Closed by default:** if the week's `resets_at` fails to parse, it returns `false` —
otherwise a `?? now` fallback would give `timeFraction = 1.0` and wrongly **open** the gate.

---

## 3. Base h5 / d7 bars — the full transition table

Notation: `u` = `usageFraction` (`utilization/100`, clipped to `[0,1]`), `t` = `timeFraction` (the
fraction of the window elapsed), `elapsed` = `windowDurationSeconds − remainingSeconds`.

Branches are checked **top to bottom, first match wins**.

| # | Condition | Severity | Color | Bucket |
|---|---|---|---|---|
| 0 | `u <= t` **and** `!blueAllowed` | `.calm` | green | `green` |
| 1 | `u <= t` **and** `elapsed <= 1200` | `.calm` | green | `green` |
| 2 | `u <= t`, `blueAllowed` **and** `(t − u) > behindThreshold` | `.farBehind` | **blue** | `blue` |
| 3 | `u <= t` (remaining) | `.calm` | green | `green` |
| 4 | `u > t` **and** `u >= 1` | `.exhausted` | red | `red` |
| 5 | `u > t` **and** `remainingSeconds <= 1200` | `.ahead` | orange | `orange` |
| 6 | `u > t` **and** `(u − t) < 0.16×(1−t)` | `.calm` | yellow | `yellow` |
| 7 | `u > t` (remaining) | `.ahead` | orange | `orange` |

Branch 0 is the weekly gate (or an inert bar); it **precedes** the start override. Unlike the retired
`FarBehindInterval.off`, this isn't a setting but a fact about the data, so **the journal honors it
too** — that's exactly why the "Bucket" column shows `green` rather than a blank.

### Four traps in this table

**Trap 1 — the equality `u == t` is calm.** The `pacing == .onPaceOrBehind` branch tests `t >= u`, so
exact equality goes **left**, into calm
([PacingModel.swift:266](../../Sources/TokenPaceKit/PacingModel.swift)).

**Trap 2 — the two 20-minute overrides are NOT symmetric in reachability.** Both sit after the exit
from the calm branch, so when `u <= t` the end-of-window override (row 5) is **unreachable**. The
state "97% spent, 97% of time elapsed, 9 minutes to reset" stays **green**, not orange.

**Trap 3 — `severity` merges green and yellow.** Both are `.calm` (rows 3 and 6). Only the color
layer and `PacingBucket` split them apart. So a bar being `.calm` ≠ a bar being green.

**Trap 4 — exhaustion on the calm side does not produce `.exhausted`.** A window that was just reset
to 100% can read as `u <= t` and fall through branches 1-3 — meaning `severity` will be `.calm`.
`PacingBucket.of` **fixes this separately** (`if usageFraction >= 1 { return .red }` on the calm
side, [PacingBucket.swift:60](../../Sources/TokenPaceKit/PacingBucket.swift)), but `severity` does
not. This is discrepancy #2 between the UI and the journal.

### Numeric threshold examples

| Window | `t` | `aheadThreshold` | Yellow while lead < | Blue when headroom > |
|---|---|---|---|---|
| 5h | 10% | 0.144 | 14.4 pp | 40 pp |
| 5h | 50% | 0.080 | 8.0 pp | 40 pp |
| 5h | 90% | 0.016 | 1.6 pp | 40 pp (unreachable: `t−u ≤ 0.9`) |
| 7d | 30% | 0.112 | 11.2 pp | 28.6 pp |
| 7d | 80% | 0.032 | 3.2 pp | 28.6 pp |

The ahead threshold **narrows** over time (a lead late in the window is more dangerous — the window
will reset before you can get back on pace), while the behind threshold **doesn't move** (it's a
fixed span of wall-clock time: "more than 2 hours behind" means the same thing at the start and at
the end).

---

## 4. Per-model bars (Opus / Sonnet / scoped)

Paced **like 7-day windows** — they take `LimitWindow.sevenDay` and borrow `seven_day.resets_at` when
they have none of their own ([UsageSnapshot.swift:591](../../Sources/TokenPaceKit/UsageSnapshot.swift)).

The table from §3 applies **with one exception**: row 2 (blue) is unreachable — green stands in its
place always, because these bars are built with `blueAllowed: false`
([ADR-0115](../adr/0115-no-blue-on-per-model-windows.md)). Not "unreachable in the UI," but
unreachable, period: the rule lives in the model, so both the renderer and `PacingBucket` see it.

| # | Condition | Popup color |
|---|---|---|
| 1-3 | `u <= t` (any amount of headroom) | **always green** |
| 4 | `u >= 1` | red |
| 5 | `remainingSeconds <= 1200` | orange |
| 6 | lead < `0.16×(1−t)` | yellow |
| 7 | remaining | orange |

The phrase "far behind pace" is unavailable to them too — `isFarBehind` returns `false` for any bar
with `blueAllowed == false`
([PopupViewController.swift](../../Sources/TokenPace/PopupViewController.swift)); they show "on
pace" instead.

**The journal matches now too — and this is new.** Before
[ADR-0115](../adr/0115-no-blue-on-per-model-windows.md), this doc claimed they "carry
`blueAllowed = weeklyHasHeadroom`, so `sev` is never `blue` for them." The second claim doesn't
follow from the first. During a calm week the gate is open, and blue **was** being recorded —
**2,214** times in the maintainer's August journal, while the popup muted it via its own
`isBaseLimit`. Now `blueAllowed` for them is unconditionally `false`, and the v4 migration
recomputed the archive (`sevRaw` preserves what was originally written).

---

## 5. The credits (money) bar

The biggest set of departures from the token bars.

| Aspect | Token bars | Credits |
|---|---|---|
| `u` | `utilization / 100` | `used / limit` |
| `t` | fraction of the window | fraction of the **calendar month** |
| Time zone | local | **UTC** (hardcoded) — for both `t` and the month-edge labels |
| Window | 5h / 7d | month; `BarLayout` substitutes 7d as a placeholder |
| Blue | yes (base bars) | **never** (`blueAllowed: false`) |
| Bar exists? | always | **only when a cap is set** |
| Presentation style | follows `dropdownStyle` (Pressure / Balance / Progress) | **always Progress**; `BarStyle` is ignored ([ADR-0092](../adr/0092-extra-usage-own-ruler.md)) |
| Ticks | a per-style set (fractions of the window / 20% / 0.5) | **none**; instead, two month-edge labels (`Jan 1` / `Jan 31`) |

**The edge labels are UTC too, and that's visible user-facing text.** Near a month boundary they can
diverge from the local calendar by several hours (up to ~11 hours east of UTC, ~8 hours west) — unlike
the `resetLine` on the same row, which renders **locally**. This tradeoff is deliberate: the reset
moment is a point on a timeline shared by everyone, while the month label is a property of the
window's own calendar, so the label must name the month that the bar's geometry actually measures
([ADR-0092](../adr/0092-extra-usage-own-ruler.md)).

**The bar is absent when there's no limit.** `barLayout(for:now:)` returns `nil` when
`spentFraction` is undefined (no cap / unlimited / zero limit) — the popup then shows only the amount
spent, with no bar and no color ([CreditsPacing.swift:194](../../Sources/TokenPaceKit/CreditsPacing.swift)).

**When the cap is reached, `u` is forced to exactly 1**, so red fires despite rounding:
`spend.spendLimitReached ? 1 : min(1, max(0, rawUsage))`.

**The 20-minute end-of-window override applies here too** — the end of the month can be less than 20
minutes away; if the calendar can't compute the boundary, a 7d length is substituted, so only the
dynamic threshold applies.

Transitions: rows 4-7 of the §3 table (red / orange / yellow); the calm side is **always green**.

---

## 6. The idle bar (no active 5h session)

`sessionIdle` occurs when the server doesn't hand back a 5-hour window — then `resetsAt: ""`, and the
window **is not synthesized**
([UsageSnapshot.swift:439](../../Sources/TokenPaceKit/UsageSnapshot.swift)).

This is a **separate code path**: the idle bar never goes through `barLayout`/`severity` at all. Its
`BarLayout` is an inert placeholder (`u = 0, t = 0, windowDurationSeconds = 0`), which the renderer
ignores ([PopupLayout.swift:542](../../Sources/TokenPaceKit/PopupLayout.swift),
[MenuBarLayout.swift:348](../../Sources/TokenPaceKit/MenuBarLayout.swift)).

The pill is **binary** (since [#381](https://github.com/artem-from-ua/cc-timer/issues/381) — it used
to be ternary):

| Condition | Fill | Word |
|---|---|---|
| `sessionIdle` **and** `CreditsPacing.isBlocked` | **gray** | "waiting for limit reset" |
| `sessionIdle`, not blocked | **green** | "ready to start" |

- `isBlocked` = `mainWindowExhausted && !creditsCanCover`
  ([CreditsPacing.swift:150](../../Sources/TokenPaceKit/CreditsPacing.swift)) — gray only when the
  main window is exhausted **at 100%** *and* credits don't cover it: working is impossible.
- **There is no more blue idle pill on any surface**
  ([ADR-0105](../adr/0105-color-advice-governs-pacing-bars-only.md)). Before
  [#381](https://github.com/artem-from-ua/cc-timer/issues/381) it was blue when the week had
  headroom and green otherwise — and its blue color was exactly what diverged from what blue means on
  an **active** bar. Now both renderers target green unconditionally:
  [PopupViewController.swift:432](../../Sources/TokenPace/PopupViewController.swift)
  (`blocked ? monochromeGrey : color(.green)`) and
  [StatusItemView.swift:995](../../Sources/TokenPace/StatusItemView.swift).
- The flag went away along with the color: the fields `LimitRow.weeklyHeadroom` /
  `BarView.weeklyHeadroom` **no longer exist** — the idle bar has nothing left to ask about the week.
- `PacingModel.weeklyHasHeadroom` still gates `blueAllowed` — but now only for the **5-hour** bar
  ([ADR-0081](../adr/0081-weekly-capacity-gate-for-blue.md) still stands in that part; per-model rows
  moved out from under it in [ADR-0115](../adr/0115-no-blue-on-per-model-windows.md), idle even
  earlier).
- **The wording doesn't change** between green and (formerly) blue: you genuinely can work either
  way. The text used to promise "ready to start, full quota available" — that part has been removed.

**On top of this — [`ColorAdvice`](../../Sources/TokenPaceKit/ColorAdvice.swift)** (menu bar only,
§7): the green pill gets muted to white under both muting modes (and **unconditionally** under
Pressure); the gray pill is never muted.

> **One blue, one role.** Previously the idle fill (`ColorRole.blue`) and the pacing gap
> (`ColorRole.paceBlue`) were two separate palette entries sharing the **same** default,
> `.systemBlue` — indistinguishable on screen, and separated only in that the tuner could pull them
> apart (the tuner itself has since been removed —
> [ADR-0106](../adr/0106-remove-dev-color-tuner-and-dissolve-colorstore.md)). The roles were merged
> into a single `.blue`, and since [#381](https://github.com/artem-from-ua/cc-timer/issues/381) idle
> doesn't read it at all — `.blue` is now purely a pacing color.

**Consistency with "Back to work!"** A green pill can coexist with the notification, and that isn't a
contradiction: `WorkAvailability.subscriptionAvailable` asks "is quota available" (exhaustion —
[ADR-0113](../adr/0113-back-to-work-tracks-the-subscription-quota.md)), while the gate asks "is there
headroom" (pace). A week that reset from 100% to 85% early in its window produces both the
notification and a green pill: "you can work, just don't push the pace."

**Geometry, not color.** [ADR-0078](../adr/0078-idle-drawn-as-zero-in-both-styles.md), "idle is drawn
as zero," is about **shape** — a solid, knobless pill at zero, with no zones and no time marker. The
color there is blue, not neutral. Confusing these two claims is a common mistake.

---

## 7. Modifiers layered on top of the computed color

The color from §3-6 is an **input**, not the final pixel.

### `ColorAdvice` — muting to white (menu bar only)

The type is named for the **advice the color carries**, not the muting mechanism
([ColorAdvice.swift](../../Sources/TokenPaceKit/ColorAdvice.swift), renamed from `CalmColorMode` in
[#381](https://github.com/artem-from-ua/cc-timer/issues/381) —
[ADR-0104](../adr/0104-appearance-named-for-behaviour-on-three-layers.md)). The row in Settings →
Appearance › Menu bar is called **"Colors tell me"**, with the segments listed below in the first
column; the old raw values (`yellowGreenBlue`/`yellowGreen`/`off`) are read through
`legacyRawValues`.

| Mode (segment) | Green/yellow | Blue | Orange/red |
|---|---|---|---|
| `.slowDown` (`Slow down`) | **white** | **white** | colored |
| `.slowDownOrSpeedUp` (`Slow down or speed up`, default) | **white** | colored | colored |
| `.howItsGoing` (`How it's going`) | colored | colored | colored |

Warnings are never muted. The popup mutes nothing. The renderer doesn't read the case directly — it
reads two derived flags, `mutesCalm` and `mutesBlue`.

**Under Pressure, muting is unconditional.** In the menu bar, when `menuBarStyle == .pressure`, the
entire calm side (blue/green/yellow) and the idle pill are muted to white **regardless of
`ColorAdvice`** ([StatusItemView.swift:995](../../Sources/TokenPace/StatusItemView.swift) —
`barStyle == .pressure || colorsTell.mutesCalm`). That's exactly why the "Colors tell me" row
**becomes inert and shows `Slow down`** under Pressure: under this style, the only color that
survives is orange's "you're spending too fast," which is exactly that segment. The control reports
the state instead of offering a choice that wouldn't change anything; the saved value isn't
overwritten and reverts once you switch back to Balance or Progress.

**These three surfaces no longer read `ColorAdvice` at all**
([ADR-0105](../adr/0105-color-advice-governs-pacing-bars-only.md),
[#381](https://github.com/artem-from-ua/cc-timer/issues/381)), because they answer different
questions:

- **The service dot**: its scale (gray → yellow → orange → red) is self-contained, and since
  [#410](https://github.com/artem-from-ua/tokenpace/issues/410) it's identical across all three
  surfaces — menu bar, popup, Legend ([ADR-0111](../adr/0111-degraded-dot-is-yellow-on-every-surface.md)).
  What changed was the **tone** of `degraded`, not who decides it: the setting never read the dot,
  and still doesn't.

  **Since [#454](https://github.com/artem-from-ua/tokenpace/issues/454) the scale reaches green in
  exactly one position** ([ADR-0121](../adr/0121-github-as-a-status-only-provider.md) §D4): a popup
  **provider-header dot on a calm provider**. The colour is `ColorRole.green` — the same green
  `dotColor(_:)` has mapped `.operational` to since #341, and the same one the Legend has listed among
  its six service states all along, so nothing new entered the vocabulary; what is new is a surface
  that draws it. The dot appears **only** while the provider is `operational` and vanishes the moment
  anything is wrong, because the rows that then appear each carry their own dot and name their service.
  So there is still **no green anywhere in the menu bar's dot** — silence there remains the complete
  answer to "can I work" ([ADR-0013](../adr/0013-claude-status-line.md) §8) — and no green on a service
  *row*, which is drawn only for a problem or a fresh recovery. The `gray → yellow → orange → red`
  escalation is untouched: green sits outside it, as the state where nothing escalates.
- **The currency symbol (¤)**: its own white→orange→red scale is self-contained
  ([ADR-0068](../adr/0068-credits-in-use-marker-anatomy.md)).
- **The idle pill** (§6): muted through the shared `idleMuted`, the same flag that governs the rest
  of the calm side.

### Journal vs. UI

`PacingBucket` ignores **only** `ColorAdvice` — that's cosmetic, and the series has to stay
comparable across users. `blueAllowed`, by contrast, it **honors**: that's not a setting, it's a fact
about the data ([PacingBucket.swift](../../Sources/TokenPaceKit/PacingBucket.swift)).

The width of the blue zone is no longer configurable: the old `FarBehindInterval` (×1/×2/×3/off) has
been removed, and the multiplier is fixed at ×2.

---

## 8. Impossible combinations

States the code **cannot** produce. Rendering one makes everything around it in the analysis wrong.

| Combination | Why it's impossible |
|---|---|
| A blue per-model / credits row | `blueAllowed == false` in the layout itself → green both on screen and in the journal ([ADR-0115](../adr/0115-no-blue-on-per-model-windows.md)) |
| Blue in the first 20 minutes of a window | start override, branch 1 |
| Orange when `u <= t` | the end-of-window override is unreachable on the calm side |
| A blue bar with the words "far behind" on Opus | `isFarBehind` returns `false` when `blueAllowed == false` |
| A **green service dot in the menu bar** | Silence is the calm answer there — the dot is drawn only for a problem ([ADR-0013](../adr/0013-claude-status-line.md) §8). Green appears in **one** place only: a popup provider-header dot on a calm provider ([ADR-0121](../adr/0121-github-as-a-status-only-provider.md)) |
| A **green service dot on a popup *row*** | Rows are drawn only for a problem or a recovery inside the 15-minute window, and a recovered row is drawn in the colour of the state it recovered *to*, on a plate whose header dot is by then absent. The green dot belongs to the **header**, never to a row |
| A **non-green provider-header dot** (yellow / orange / red / blue / grey) | `headerDot(for:)` returns a dot for `.operational` and `nil` for everything else, `unknown` included — the moment anything is wrong the rows below carry the colour and name the service ([ADR-0121](../adr/0121-github-as-a-status-only-provider.md) §D2) |
| A credits bar when `limit == nil` | `barLayout` returns `nil` — there's no bar |
| A credits bar under Pressure or Balance | Always the month-window scale, regardless of `dropdownStyle` ([ADR-0092](../adr/0092-extra-usage-own-ruler.md)) |
| A credits bar with ticks | Its ruler is two month-edge labels, no ticks at all (0092); and even those labels only show **under ⌥** ([ADR-0098](../adr/0098-ruler-split-identify-always-explain-on-option.md)) — without it, the bar has no ruler at all |
| An idle bar with a time marker | idle draws as zero, with no marker and no zones |
| An idle bar filled full width | idle is a pill at zero |
| **A blue idle pill** — under any settings, in any state of the week | Since [#381](https://github.com/artem-from-ua/cc-timer/issues/381) there's no blue idle on any surface: the fill is green, or white (under muting), or gray (blocked). The `Yellow + Green` exception for idle that applied under [#343](https://github.com/artem-from-ua/cc-timer/issues/343) disappeared along with blue |
| **A colored idle pill under Pressure in the menu bar** | Under Pressure, muting is unconditional (`barStyle == .pressure \|\| colorsTell.mutesCalm`), so a green pill there is **always** white — regardless of `ColorAdvice`, which isn't even shown in Settings under this style |
| **A white (neutral) service dot in the menu bar — in any state** | Since [#410](https://github.com/artem-from-ua/tokenpace/issues/410) ([ADR-0111](../adr/0111-degraded-dot-is-yellow-on-every-surface.md)) `statusDotTarget` has no exception left: all six states take their tone from the scale (`degraded` is yellow, same as in the popup and on the Legend). The `calmWhite` branch no longer exists, so a neutral dot is drawn nowhere |
| Yellow on the calm side | yellow only exists when `u > t` |
| Blue on 5h when `t < 0.40` | `t − u ≤ t`, so the headroom can never reach the threshold |
| **Blue h5 when d7 ∈ {yellow, orange, red}** | the weekly gate is closed → `blueAllowed == false` |
| **An idle pill that changes color with the week's state** | The weekly gate no longer factors into idle at all: the fields `LimitRow.weeklyHeadroom` / `BarView.weeklyHeadroom` don't exist, so `idle` and `idle-week-hot` draw the same **green** pill |
| `sev: "blue"` in the journal that never appeared on screen | the journal reads the same `blueAllowed` |

---

## 9. How to verify a state arithmetically

Before claiming "the bar will be this color," work it out:

```
u = utilization / 100
t = elapsed / windowDuration          # fraction of the window elapsed
elapsed = windowDuration - remainingSeconds

if u <= t:
    if not blueAllowed:                     -> GREEN (weekly gate / inert bar)
    elif elapsed <= 1200:                   -> GREEN (start override)
    elif (t - u) > behindThreshold:         -> BLUE (h5/d7 only)
    else:                                   -> GREEN
else:
    if u >= 1:                              -> RED
    elif remainingSeconds <= 1200:          -> ORANGE (end override)
    elif (u - t) < 0.16 * (1 - t):          -> YELLOW
    else:                                   -> ORANGE
```

Then: if the bar isn't entitled to blue (`blueAllowed == false`), blue is replaced with green. If
it's the menu bar and that tone gets muted, the color becomes white; muting comes from `ColorAdvice`
(§7) **or**, unconditionally, from the Pressure style.

---

## 10. Stubs for live verification

| Scenario | What it shows |
|---|---|
| `far-behind` | both base bars blue (5h headroom ~0.55, 7d ~0.61) |
| `both-orange` / `both-red` | the ahead side and exhaustion |
| `calm-both` | both green |
| `near-reset` | the 20-min end override (2 pp lead → orange) |
| `bar-extremes` | 5h blue (75 pp headroom) + 7d behind pace (so the gate stays open) |
| `idle` | **green** idle pill, "ready to start" (was blue before [#381](https://github.com/artem-from-ua/cc-timer/issues/381)) |
| `idle-week-hot` | the week is ahead of pace — and the pill is **the same green**. This state was kept as a stub deliberately: it proves idle does **not** react to the week; a divergence from `idle` would be a regression |
| `idle-blocked` | gray idle pill, "waiting for limit reset" |
| `weekly-gate` | 5h deeply behind pace, but the week is exhausted → 5h is **green**, not blue |
| `credits-*` | the money bar in various states, including without a cap |
| `credits-month-end` | the same money bar at **90% of the month** — the tightest spot on its ruler: the time marker gets closest to the right-hand label (`Jan 31`) |
| `color-cycle` | cycles through every bucket in turn |

Run with: `TOKENPACE_STUB=<id> swift run`.
Full list — [ui-verification.md](../guides/ui-verification.md).
