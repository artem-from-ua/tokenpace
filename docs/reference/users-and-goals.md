# Users, their pain, and their goals

Who TokenPace is for, what they run into in Claude Code, and what "the app helped" means to them.
This is the reference for anyone proposing a UI change — so that the motivation rests on real
behavior rather than on a guess.

> Related: [SPEC.md](../../SPEC.md) — the product spec; [ADR-0005](../adr/0005-pacing-fractions-not-blocks.md)
> — why pacing rather than blocks; [ADR-0027](../adr/0027-session-idle-no-phantom-reset.md) — the idle state;
> [ADR-0044](../adr/0044-dynamic-pacing-threshold.md) — the dynamic threshold;
> [personas.md](personas.md) — the personas of the target audience and the enrichment features.

## Who this is

**A developer who works with Claude Code every day, for hours at a stretch.** Not a billing
administrator, not a cost analyst — someone who writes code and now and then hits the limit
in the middle of a task.

The defining property: **work comes in bursts**. One heavy session (a large refactor, a long
exploration of the codebase) eats 10–15% of the weekly quota in an hour. A calm day
eats nothing.

The variations on that core — by appetite for quota, shape of the day, and motivation — are
described as four personas in [personas.md](personas.md); the bar for a useful signal (below) is
applied there persona by persona.

## The core pain

**The limit arrives without warning, in the middle of the work.** Claude Code reports the
exhaustion after the fact — once there is no way to continue. The consequences:

1. **Lost context.** A long session breaks off halfway; coming back to it 3 hours later
   means rebuilding the state in your head.
2. **No way to plan.** "Will I finish this task before the reset?" — a question that had no
   answer before TokenPace without opening a browser.
3. **No way to correct course.** Learning about 100% after the fact changes nothing.
   Learning at 30% that you are "burning twice as fast as the clock" lets you redistribute the work.

Hence the central requirement: **the signal has to arrive while there is still something to do
about it**, and it has to take a shape that makes clear what to do.

## What makes a signal useful

A signal is useful if it **changes a decision**. The test to apply before putting anything on
screen:

> Is there an action the user would take differently having seen this — and would have taken
> wrongly without seeing it?

If not, the signal is not useful, however true it may be.

### Examples that pass the test

| Signal | Action |
|---|---|
| An orange bar | Ease off, or move the heavy task |
| "stand by 3h for green" on 7d | Weigh a pause as an option: wait it out, or accept orange and keep working |
| A blue bar | You can burn more freely, there is room |
| Red + the pause glyph | Work has stopped; plan the break |
| The currency symbol | From here on it is money, not quota |
| The countdown to the reset | Finish now, or wait |

### Examples that fail

| Signal | Why not |
|---|---|
| "27% used" on its own | Says nothing about whether that is good or bad until you know how much time has passed — and that is already folded into the color |
| "12% of quota left" at a calm pace | 12% across 12 hours is a surplus (a sustained pace of 1.71× the linear rate), not a shortage |
| "the 7-day window is nearly full" when `usage ≤ time` | The calm branch means `rate ≤ 1`, so running out before the reset is arithmetically impossible |
| The total money spent, in the menu bar | Duplicates the currency symbol, which already encodes the state in its color |

**The rule that follows:** a value (`usageFraction`, the remainder, an amount of money) is the
model's **input**. The color, the verdict, and the marker are its **output**. Showing the input
next to the output asks the user to redo a computation the app has already done.

## Why silence is a valid state

Showing something costs attention. The widget lives in the menu bar next to the system icons; the
popup opens on top of the work. So **the absence of a signal is not a defect by default** —
it needs the same justification as a presence does, and it often wins.

A calm state, in which there is nothing to do, ought to say nothing. That is not "the app fell
short", that is the result.

## The "stand by … for green" line: what it adds, and why it is almost always silent

> The decision and the alternatives — [ADR-0102](../adr/0102-stand-by-line-for-the-seven-day-bar.md).

An orange bar says **what** is wrong — more has been spent than this point in the week allows. It
does not say **what it costs to fix**. The user sees the problem but has no price for the solution,
so they either guess at a pause or ignore the signal.

Under ⌥, the 7-day row grows a third line — `stand by 3h for green`: how long to spend nothing so
that the bar returns to the green zone. That turns a verdict into **a quantity you can act on**:

| What the line shows | The decision it changes |
|---|---|
| `stand by 40m for green` | The pause is cheap — take a break, come back to green |
| `stand by 2d for green` | The pause is unrealistic — accept orange deliberately and plan the week around it |

Both outcomes are useful, and the second no less than the first: "waiting it out won't work" is an
answer too, and it stops the futile attempts to "ease off a bit".

**Why 7d, and why not 5h.** The five-hour window resets at least twice in a working day — it fixes
itself, without any decision from the user, so the price of a pause there interests nobody. The week
does not work that way: orange on 7d lives for days, and that is exactly where a pause is a real
strategy.

### Three layers of silence

The line is expensive in attention — it is the third in the section and it shifts the bar. So it
stays silent everywhere it does not change a decision:

1. **Only under ⌥.** At rest, the section looks as it did before. The line is a detail on demand,
   not a permanent resident of the popup.
2. **Only when the bar is orange.** On green or blue there is nothing to wait for; on yellow the
   lead is still within normal; on red a pause does not work at all — an exhausted window is cured
   only by a reset.
3. **Only when the wait is worth discussing** — no less than 20 minutes
   (`PacingModel.standByFloorSeconds`). A shorter pause elapses while the user is reading the popup,
   and it produces a line that blinks for no reason.

**One threshold is in fact enough.** It is natural to want another rule — "don't show it when the
reset lands at roughly the same time", since the reset line already carries that signal. But that
rule is already in force, and in a stricter form: the computation refuses if green would arrive in
the last 20 minutes of the window, because `pacingOrangeOverrideSeconds` holds the bar orange there
anyway. Any pause closer to the reset is filtered out earlier, so a separate 10-minute rule would
not reject a **single** case — it would be dead code. This is a classic trap: two thresholds that
look independent while one is actually nested inside the other.

### How much noise this really is

Orange on 7d requires a lead above `0.16·(1 − t)` — mid-week that is tens of hours of waiting. So:

- in the **typical** orange state the line shows hours or days, and the 20-minute threshold never
  touches it;
- the threshold **never fires at all** on real data — and that is a conclusion drawn from measuring
  the source, not an estimate of probability.

The reason lies in the API itself. The `utilization` of the token windows arrives **rounded to a
whole percent** ([usage-api-quirks](usage-api-quirks.md): 6204 journal records, not one fractional).
On the seven-day window one percentage point is **1 hour 40 minutes** of work, and that is also the
**minimum non-zero lead** over time. So a wait on 7d can be either zero or ≥ 101 minutes — values
in between do not occur in nature, and the 20-minute threshold catches an empty set.

Arithmetically the state "orange with a pause under 20 minutes" exists (it needs less than 125
minutes left in the window and a lead of hundredths of a point), but **the server does not serve
such values**. That is precisely why the `standby-floor` stub had to be built on a fractional
percent, which a real response never carries.

The practical conclusion: **the threshold is a safety catch, not a filter**. It guarantees the line
will never say "stand by 3m" (advice you cannot finish reading) should the API's granularity ever
change. Today it hides nothing, and the line's silence rests on the other two conditions — ⌥ and
orange.

**The lesson is wider than this feature:** before putting a threshold on a quantity derived from
`util`, check it against the **quantization step** of that window (3 minutes on 5h, 101 minutes on
7d). A threshold smaller than the step is dead.

## The hierarchy of attention

What should be louder is determined by **how urgent the correction is**, not by the size of the
number:

1. **Red** — work has stopped, or money is going out
2. **Orange** — behavior has to change now
3. **Yellow / green** — do nothing
4. **Blue** — you can speed up

The absolute remainder is **deliberately absent** from this scale: it does not map onto an action
without being related to time, and that relation is the pacing model.

## Scarce resources

Two surfaces with hard constraints — any proposal has to reckon with them.

### Menu bar width

The space is horizontal and shared with other people's widgets. A change in width **shifts the
neighbors**, so jitter in the width is not cosmetic.

Measured reference points (`monospacedDigitSystemFont(ofSize: 11)`):

| Element | Width |
|---|---|
| The bar block | 34 pt |
| `1h` · `9h` · `4d` | 13.5–13.8 pt — the narrowest label |
| `10h` · `22h` · `15d` | 20.5–20.8 pt |
| `10m` · `45m` | 23.6 pt — **today's widest label** |
| `20:40` | 31.3 pt — **in the popup only**; there is no clock time in the menu bar ([ADR-0074](../adr/0074-one-reset-format-on-both-surfaces.md)) |
| `4h41m` | 37.2 pt — the former maximum; the combined format is gone |
| `€13.32` | 38.3 pt |
| `$54,321.00` | 62.6 pt |

The widest label dropped from 37.2 to 23.6 pt along with the removal of the 90-minute threshold
([#284](https://github.com/artem-from-ua/tokenpace/issues/284)), and
[#303](https://github.com/artem-from-ua/tokenpace/issues/303)
([ADR-0075](../adr/0075-reset-label-reserved-slot.md)) made it **constant**: the label is drawn in a
fixed-width slot (24 pt — the widest of `10m`/`45m`/`<1m`) with the text centered, so a change in
the number of digits (`10h` → `9h`) or in the unit (`49m` → `1h`) no longer shifts the widget. The
price is up to 10 pt of emptiness around short labels, split evenly on either side of the text.

The slot is reserved **only while the label is on screen**: under the default `smart` the countdown
is absent most of the time, and holding space for it would mean making the calm state pay for the
emergency one. So the appearance and disappearance of the label itself does still shift the widget —
deliberately, because that transition coincides with an event the user is already looking at.

Money amounts are dangerous in their own right: the width depends on the currency (JPY has no
decimal places, and neither does CLP), on where the symbol sits (`13,32 ₴` puts it after the
number), and on the thousands separator. The spread of 21–62.6 pt is nearly threefold.

### Popup height

It grows downward and is **multiplied by the number of vendors** (see [#60](https://github.com/artem-from-ua/tokenpace/issues/60)).
Every extra line in a limit's template costs N lines across N providers. That is exactly why the
idle line is deliberately compact — it is a saving in height, not semantic delicacy.

## What the user already controls

Not everything that looks like the app's decision is one.

| Quantity | Who sets it | Consequence |
|---|---|---|
| The monthly spending cap | The user, in Anthropic billing | `spend.limit: null` → the credits row collapses into a plain counter with no bar and no verdict |
| Whether the 5-hour bar hides while calm | The row **"Hide the top 5h bar"** — [`TopBarHiding`](../../Sources/TokenPaceKit/TopBarHiding.swift): `Until it needs attention` / `Never`, default **`Until it needs attention`** ([ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md), which narrowed the three-way choice of [ADR-0086](../adr/0086-tri-state-calm-bar-hiding.md); the type and segment names — [#381](https://github.com/artem-from-ua/cc-timer/issues/381)) | The top 5-hour bar disappears while it is calm and comes back on orange/red; the 7-day one always stays |
| The bar style — **separately for the menu bar and for the dropdown** | `menuBarStyle` / `dropdownStyle`, each of them progress / pressure / balance ([ADR-0080](../adr/0080-per-surface-bar-style.md)) | The time marker is there or it is not — and the scale changes with it: Progress measures in fractions of the window; Pressure measures against the time remaining, so **width carries urgency** ([ADR-0076](../adr/0076-pressure-scale-for-marker-less-bar.md)); Balance measures the same thing **with a sign, from the center**, so **direction carries which side of plan you are on**, and the left half shows the surplus you will not manage to spend ([ADR-0079](../adr/0079-centred-zero-gauge-scale.md)). The surfaces are independent — a denser style in the roomy popup and a quieter one in the cramped bar are set separately |
| What exactly the bar colors should be telling you | The row **"Colors tell me"** — [`ColorAdvice`](../../Sources/TokenPaceKit/ColorAdvice.swift): `Slow down` / `Slow down or speed up` (the default) / `How it's going` ([ADR-0104](../adr/0104-appearance-named-for-behaviour-on-three-layers.md), [#381](https://github.com/artem-from-ua/cc-timer/issues/381)) | Muting the calm tones toward white — and **only for the pacing bars** ([ADR-0105 §1](../adr/0105-color-advice-governs-pacing-bars-only.md): the service dot, the currency glyph, and the idle pill do not read this setting — the dot still does not, even after [ADR-0111](../adr/0111-degraded-dot-is-yellow-on-every-surface.md), which changed its tone but not who decides it). Under the **Pressure** style the row is **disabled and shows `Slow down`**: there the calm side is muted unconditionally, so the choice would change nothing, and `Slow down` is a truthful description of what is drawn. The stored value is not overwritten and returns on Balance/Progress |
| The popup sections | [`PopupSectionVisibility`](../../Sources/TokenPaceKit/PopupSectionVisibility.swift) — `When it needs attention` / `Once used` / `Always` (ordered quieter→louder, [ADR-0104](../adr/0104-appearance-named-for-behaviour-on-three-layers.md) — which superseded [ADR-0087](../adr/0087-above-zero-section-visibility.md) and §5–§6 of [ADR-0100](../adr/0100-dropdown-style-tiles-and-retired-option-segment.md), [#381](https://github.com/artem-from-ua/cc-timer/issues/381)) | Per-model and credits, each under its own key. The credits row **does not offer** `whenItNeedsAttention` (`creditsOffered`): with no spending ceiling there is no bar, and therefore no severity. The `optionOnly` case has been **removed from the enum** — ⌥ reveals the group under any choice anyway; the old raw value is read through `legacyRawValues` |

**Before proposing "remove X, it isn't always appropriate", check whether the user cannot already
remove it themselves.** Often the switch sits in the very place the quantity itself is set — and
that is a better place for it than a setting of ours.

## The ratio between the windows' quotas (N) — computed, not hardcoded

**N ≈ 9.8** points of the five-hour scale per one point of the weekly scale — that is, the weekly
limit holds roughly **ten fully spent 5-hour windows**, and one window exhausted to 100 %
eats ~10.2 pp of the weekly one.

Measured on a day-long series (`ratio-d7-h5`, 2026-08-06): the slope of the **cumulative sums** by
least squares over 17 ticks of the weekly counter. The 95 % CI of the mean local N is 8.9–10.8.

> The instantaneous ratio of the derivatives cannot be computed: `d7_util` is integer-valued and
> over a day moved only 17 times by +1 pp, while `h5_util` took 130 steps. Dividing one step
> function by another sample by sample yields zeros and infinities. The increment is taken
> only within a single segment and only when positive, so the zeroing at a reset does not count
> as spending.

### What this tells us about the product

Astronomically, seven days hold **33.6** five-hour windows, while the limit is enough for
~10 — meaning the weekly quota covers **29 % of the calendar**. That is the real frame for
pacing: past ~30 % average fill of the 5-hour windows it is the **weekly** limit that binds,
not the session one.

### N is a property of the plan, not a constant

**Do not hardcode it.** N depends on the subscription tier and the model mix: on another tier, or
with Opus in play, it will move. Anthropic also changes the limits announced and temporarily
(observed: *"weekly Claude Code limit is 50 % higher through August 19"*) — the same mechanism
described as an open question in
[#278](https://github.com/artem-from-ua/tokenpace/issues/278).

**But computing it from the user's own data is possible, and worth doing.** Since N is derived from
one's own series, it automatically reflects the tier, the mix, and whatever promotions are in
force. The prospect that follows: **watch N over time and notice it change** — that is, the app
could report "your weekly limit just got wider" instead of silently showing a jump in the
percentages.

### The conditions for showing it

If N ever becomes part of the UI (the natural home is Insights, [#241](https://github.com/artem-from-ua/tokenpace/issues/241)):

- **It needs ≥ 10–15 ticks of `d7_util`.** In the first two days of a cold start there will be 2–3
  and the CI is meaningless — until then, show "still computing", not a number.
- **Gaps in the data understate the absolute estimates.** If a gap fell during an active session,
  both counters will catch up together and **the ratio survives**, but "how many windows I burned"
  will come out low — that has to be labeled.
- **Several scoped models break a single N.** One overall coefficient would hide the fact that the
  weekly limit is being eaten by a window other than the one the user is looking at.
- **The ratio curve itself is useless** — it is a horizontal line that adds nothing once you have
  seen the number. What is worth showing is **the number**, not a chart: "weekly remaining = 8.3
  windows" is the one phrase that makes the two scales commensurable.

### What does not depend on N at all

**The asymmetry in the cost of a mistake** follows from the *duration* of the windows, not from the
quotas:

| | 5-hour | 7-day |
|---|---|---|
| Cost of exhaustion | 1–5 hours of waiting | until the end of the week |
| Resets per week | ~33 | 1 |
| Can be waited out | yes | no |

That holds for any N, and it is what
[#287](https://github.com/artem-from-ua/tokenpace/issues/287) rests on (which bar to hide when
both are calm).

## What the user does not see, and why

`spend.balance` and `spend.auto_reload` arrive as `null` from `/api/oauth/usage` (spike
[#142](https://github.com/artem-from-ua/tokenpace/issues/142)) — deliberately not decoded.
The consequence: the app does not distinguish "my money" from "a promo credit that expires".

This is **not our defect** and it is not cured by complexity on our side. The endpoint is
unofficial; nobody is obliged to extend its schema for a third-party client. Proposals to make up
for it by entering the balance by hand pay with our complexity for someone else's empty JSON.
