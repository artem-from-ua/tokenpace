---
status: accepted
date: 2026-07-26
superseded_by: [0105]
---

# ADR-0038: Idle "blocked" — a gray bar, "waiting for limit reset", and one blocking red reset

> Partially replaces [ADR-0027](0027-session-idle-no-phantom-reset.md) (idle as an always-blue
> "ready to start"). Implemented in [#158](https://github.com/artem-from-ua/tokenpace/issues/158).
>
> **Clarification:** [ADR-0048](0048-red-reset-badge-while-credits-cover.md) extends §D3 — the red
> reset badge now appears not only when `isBlocked`, but also when the subscription limit is
> exhausted and credits are covering it (#193).
>
> **Partially superseded by [ADR-0078](0078-idle-drawn-as-zero-in-both-styles.md):** "a solid gray
> bar" in §D2 is no longer a shape but a color. Idle now draws zero in both `BarStyle`s — a gray
> track with the pill at zero — so a blocked idle reads as an **empty track** (the pill the same
> tone as the track), under Progress plus a gray marker at zero. The color choice (blocked → base
> gray, ready → blue) and the rest of the decision still stand.
>
> **Postscript ([#381](https://github.com/artem-from-ua/cc-timer/issues/381)).** The contrast stays
> two-way, but the second color changed: **blocked → gray, ready → green**, with no blue at all
> ([ADR-0105](0105-color-advice-governs-pacing-bars-only.md); the intermediate three-way state from
> [ADR-0081 §4](0081-weekly-capacity-gate-for-blue.md) was itself superseded by it). The gray pill,
> as before, is not suppressed in any `Colors tell me` mode; the green one is suppressed along with
> the rest of the calm states and **unconditionally** under Pressure. The wording ("waiting for
> limit reset" / "ready to start") and the rest of the decision still stand.

## Context

[ADR-0027](0027-session-idle-no-phantom-reset.md) introduced an honest **idle** state
(`UsageSnapshot.sessionIdle`): the previous 5h window has ended, no new session yet → the 5h bar
draws **solid blue** with no indicator, and the popup status reads "ready to start" (D1/D4 of that
ADR). The intent: "quota is free, you can start."

But idle **does not always** mean "you can work." If at the exact idle moment **there is no path
at all to start a session**, the blue "ready to start" lies — the truth is you have to wait for a
reset. What can block you:

- the **7-day limit** (`seven_day.utilization >= 100`) — the main barrier when there's no 5h window;
  **or**
- **exhausted extra-usage credits** — the money cap reached (`spend_limit_reached`) or credits
  disabled: the paid "last line of defense" no longer covers anything (see
  [ADR-0037](0037-extra-usage-credits-model.md)).

We need to honestly show "wait for reset" and hint **exactly when** it unblocks.

## Decision

### D1. The "blocked" model (pure logic in Kit)

"Blocked" = there is no path to work right now — regardless of whether you're idle or had an
active session:

```
isBlocked = noFiveHourQuota  AND  seven_day >= 100  AND NOT creditsCanCover(spend)
noFiveHourQuota = sessionIdle  OR  five_hour >= 100
creditsCanCover(spend) = spend != nil AND spend.enabled AND NOT spend.spend_limit_reached
```

The 5h window is the near barrier: you can work if it has quota (an idle 5h you're allowed to
start, or an active 5h < 100). So `noFiveHourQuota` = idle **or** 5h exhausted. Plus 7d must be
exhausted **and** credits must not cover it. Per-model windows with headroom (e.g. a model at 60%)
do **not** unblock — the main 5h/7d gate all work. The computation lives in `make(...)` on both
layouts.

### D2. Gray bar + "waiting for limit reset" (idle only)

This is **idle-specific** (during an active session the 5h row shows the normal "limit reached",
not "waiting"):

- A **blocked idle** bar draws in the pacing strip's **base gray** (`PopupBarView.monochromeGrey` —
  the same tone as the bar's `used`/future zones), not the "ready" blue. In the menu bar — in
  **both** color modes (blocked does not depend on "Calm colours" #105). Flags: `BarView.blocked` /
  `LimitRow.sessionBlocked`.
- A **ready** idle bar stays blue (`idleBlue`); under "Calm colours" it now mutes to a **soft
  light gray** (`idleCalmGrey`) instead of pure white — white read as too bright for an idle strip.
  So menu-bar idle: ready = blue / calm→light gray; blocked = base gray (both modes).
- **Popup**, status word: `ready to start` → **`waiting for limit reset`**. The wording is neutral
  (not "7d"), since the blocker can also be the credits cap. The idle row stays **compact** (no
  detail row) — the unblock time is carried by the red badge (D3).

### D3. One blocking red reset — the "last line of defense" rule

In the popup exactly **one** reset time is shown as a **red badge** (a `PillView` pill in
exhausted-red, like the credits "active" badge, only red, with a **"Effective blocker"** hover
tooltip) — the one that actually unblocks work. It appears **whenever `isBlocked`** — both idle and
during an active session with every baseline limit exhausted (the `both-red` case: 5h+7d+per-model
at 100% → the badge lands on 7d, since its reset is later than 5h's). The menu bar shows the
**same** selected reset as a countdown.

The rule (`BlockingReset`, shared by the popup and menu bar) over the exhausted resets `5` (5h≥100),
`7` (7d≥100), `e` (credits `monthEnd`, when `CreditsPacing.isActive`):

```
e present:  e is not the latest → e ;  e is the latest → max(5,7)
e absent:   max(5,7)
```

Mentally: **credits are the "last line of defense"**; when they're available and don't reset last,
they unblock fastest (coverage resumes right after their reset). But if credits reset all the way
at the end of the month, the token limits come back sooner — in that case we show the later
**of the token limits**.

| Order | Shown in red |
|---|---|
| e<5<7, e<7<5, 5<e<7, 7<e<5 | **e** |
| 5<7<e | **7** (= max(5,7)) |
| 7<5<e | **5** (= max(5,7)) |

## Consequences

- Idle is no longer "always blue/ready": it now has two variants — **ready** (blue) and **blocked**
  (gray + "waiting…"). This **partially replaces** D1/D4 of
  [ADR-0027](0027-session-idle-no-phantom-reset.md); the rest of that ADR (honest idle detection, no
  phantom `now+5h` reset, `is_active` unused) still stands.
- One semantic choice of "blocking reset" lives in Kit and feeds both surfaces — the popup badge and
  the menu-bar countdown never diverge.
- The "last line of defense" rule is consistent with `MenuBarLayout.selectReset` (both-exhausted →
  the later reset), just with an added credits priority.
- Verification: stub `TOKENPACE_STUB=idle-blocked` (idle 5h + 7d@100 with no credits) — a gray bar in
  both color modes, "waiting for limit reset", a red 7d reset.
