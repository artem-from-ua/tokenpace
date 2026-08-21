---
status: accepted
date: 2026-08-19
supersedes: [0105]
superseded_by: []
---

# ADR-0111: The `degraded` dot is yellow on all three surfaces

> Supersedes **§3** of [ADR-0105](0105-color-advice-governs-pacing-bars-only.md) ("The `degraded`
> dot is unconditionally white in the menu bar, yellow in the popup"). **§1, §2, §4, §5, and §6
> still stand** — in particular §1 ("the scope of `ColorAdvice` is narrowed to pacing bars"), which
> this decision **confirms** rather than reverses: yellow is unconditional, and the dot never read
> the setting either before or after. Implemented in
> [#410](https://github.com/artem-from-ua/tokenpace/issues/410).

## Context

The service-status dot is drawn in **three** places, and before this change they disagreed in
exactly one state:

| Surface | Code | `degraded` |
|---|---|---|
| Menu bar | [`StatusItemView.statusDotTarget`](../../Sources/TokenPace/StatusItemView.swift) | **neutral** (`bright(Palette.calmWhite)`) |
| Popup | [`PopupViewController.dotColor`](../../Sources/TokenPace/PopupViewController.swift) | yellow |
| Legend | [`LegendPane.serviceStates`](../../Sources/TokenPace/Settings/LegendPane.swift) | yellow |

Neutral in the menu bar is §3 of [ADR-0105](0105-color-advice-governs-pacing-bars-only.md), and
it's important that it **was not an oversight**. That ADR weighed the alternative "detach the dot
from the setting but keep it yellow," described it as "the minimal change and the one least likely
to draw objections" — and rejected it, after a live check specifically on the light theme. The
argument: **a yellow dot in the menu bar is a state with no action to take**, and the widget's quiet
default exists precisely for states like that; no information is lost, only moved into the popup,
where the service name and the state text sit next to it, so color isn't the only carrier.

**What has changed since — the Legend page**
([#261](https://github.com/artem-from-ua/tokenpace/issues/261),
[ADR-0110](0110-legend-is-a-static-page-rendered-by-the-live-code.md)). It's obligated to name what
every color means, and it shows six service states **as a scale** — meaning it had to pick one
value for `degraded`. It picked yellow: a reference page whose own example is the exception teaches
the exception, not the rule. After that, the widget was left as the **only** surface disagreeing
with the other two, and a comment appeared in the code recording the mismatch as known debt.

That is the new fact that didn't exist when §3 was decided: until then the asymmetry was a private
agreement between two surfaces; now it had to be **printed in a reference page**.

## Decision

`statusDotTarget(.degraded)` returns `accent(Palette.statusYellow)`.

The consequence for the shape of the code matters as much as the color: the switch no longer has
**any** exception — all six states resolve through `accent(...)`, and the
`bright(Palette.calmWhite)` branch is gone. An attempt to bring the exception back would show up in
a diff as a change in shape, not as a swapped literal.

Three reasons the §3 argument didn't hold up:

1. **The widget doesn't reserve a color for states with an action attached.** `unknown` is gray, and
   its "action" ("we couldn't determine the state") is no more actionable than degradation. In
   other words, §3 wasn't establishing a rule — it was making **one** exception and calling it a
   rule.
2. **The scale carries the meaning, not an individual dot.** `gray → yellow → orange → red` reads
   without a legend precisely because it's monotonic. Drop the middle step and you're left with
   `gray → orange` — "fine, and then suddenly bad" — and the reader loses the ability to tell a
   **slow** service from a **broken** one at a glance. That is exactly the distinction the dot
   exists for.
3. **`degraded` does have an action**: check whether the slowdown is on their end before spending an
   hour on your own code. The same class of action `partialOutage` triggers, one notch quieter.

**The scope of this decision is the tone, not who owns the tone.** The dot doesn't read
`ColorAdvice` — neither before nor after. §1 of
[ADR-0105](0105-color-advice-governs-pacing-bars-only.md) still stands in full, and that statement
is deliberately repeated in four places (the comment in `statusDotTarget`, the doc comment on
[`ColorAdvice`](../../Sources/TokenPaceKit/ColorAdvice.swift), the "Colors tell me" line in
[ui-verification.md](../guides/ui-verification.md), and this ADR): the most likely misreading of the
reversal is to conclude that the link to the setting came back.

## Consequences

**Two objections that §3 weighed and accepted now cut the other way** — both are recorded there in
writing, so this decision can't route around them:

- [ADR-0071](0071-incident-subscriptions.md) (lines 32–35): `degraded` is **already**
  under-read — people read it as "will be slower," even though part of the functionality may not
  work at all. §3 acknowledged this and deliberately made the state **even quieter**, relying on the
  popup's text and the incident subscription. That answer still stands — but it is now
  **supplemented** by color, not replaced by it.
- [ADR-0013](0013-claude-status-line.md) (line 108): the severity ordering ranks `degraded`
  **above** `unknown` and `underMaintenance`, and those stayed colored. §3 accepted the formal
  anomaly of "a lower state more visible than a higher one"; this decision **removes** it — color is
  monotonic again along the same scale the dot itself is chosen from.

**One shade now carries two different meanings on the widget.** A yellow pacing gap means "slightly
ahead of pace" — a calm state **with no** action attached
([`PacingBucket`](../../Sources/TokenPaceKit/PacingBucket.swift), row 6 of the table in
[bar-status-conditions](../reference/bar-status-conditions.md)); a yellow dot means "the service is
degraded." Under Progress and Balance, both can appear on the bar at once. This is accepted
deliberately, and what distinguishes them is **not the hue but the shape and position**: the gap is
a horizontal strip inside the gray track, the dot is a 6 pt circle at the widget's right edge,
outside the track; there are no other circles on the bar. There's already a precedent — orange has
long carried both meanings (`partialOutage` and "spending too fast"), and that has never been
called a problem. Under **Pressure** the question doesn't arise at all: the calm side is
unconditionally suppressed there (§5 of
[ADR-0105](0105-color-advice-governs-pacing-bars-only.md)), so there is no yellow gap.

**The `calm-degraded` frame changed role.** It used to check for **divergence** between two
surfaces ("they're supposed to differ, and that's not a bug") — it now checks for **convergence**
across three ("any difference is a regression"). The light theme remains the deciding screenshot,
but the question is mirrored: not "does the neutral tone disappear into the background" but "does
the yellow read as an alarm."

**`swift test` won't catch a regression here.** `statusDotTarget` is `private` in the app target,
which links no test target at all ([`Package.swift`](../../Package.swift): there's only
`TokenPaceKitTests` on `TokenPaceKit`). So the stub line in
[ui-verification.md](../guides/ui-verification.md) is phrased as an invariant ("the white dot never
appears in any state") — a live check is the only net here.

**Incidentally:** the comment on
[`ColorCycleStub.statuses`](../../Sources/TokenPace/ColorCycleStub.swift) already promised a
"yellow → orange → red → blue → grey" pass — it had been a lie since #381, and it's true again now
with no code change at all.

## Alternatives considered

**Leave the widget as is and fix Legend instead** — show the menu-bar exception in the reference
page. Rejected: the reference page explains the **vocabulary**, not one surface; and it would create
a second copy of the rule, which would drift the same way these three did.

**Make the popup neutral instead of making the widget yellow.** The smallest code change, and it
also removes the divergence. Rejected: it drops the middle step from **every** surface, reinforcing
reason 2 — `gray → orange` is already everywhere, and the "slow vs. broken" distinction is lost for
good.

**A muted yellow specifically for the menu bar** (lower saturation than the popup). Rejected:
`accentSaturation` is a global hook on **every** accent on the widget, and a per-state exception is
exactly what this decision removes. The live check on the light theme passed without it.
