---
status: accepted
date: 2026-07-24
superseded_by: [0038, 0059, 0060, 0074, 0078, 0107]
---

# ADR-0027: An honest "no active 5h session" state instead of a phantom reset

> **Partially superseded by [ADR-0107](0107-weekly-reset-reconstructed-from-the-last-known-one.md):**
> **D5 is canceled for the `seven_day` part.** Its rationale — "the weekly window always exists, so
> an exhausted chain stays on a local estimate" — is disproven by measurement: every week, the API
> **fails to return** `seven_day.resets_at` for 4–6 hours (three episodes in the Max journal, two in
> the Pro one), meaning that, in terms of what the response says, the weekly window doesn't always
> exist either — exactly like the 5-hour one. The local estimate for `seven_day` has been removed:
> instead of `now + 7d`, the last **server** reset is now rolled forward (error ±0.25 s against
> minutes), and with no anchor nothing is invented. The parameter `localEstimateAllowed` was renamed
> to `reconstructionAllowed`.
>
> **The `five_hour` branch of this ADR still fully stands** — and it turned out to be the right
> answer that wasn't extended to the weekly window at the time: the defect described in
> [#100](https://github.com/artem-from-ua/tokenpace/issues/100) was the same for both.

> **Partially superseded by [ADR-0078](0078-idle-drawn-as-zero-in-both-styles.md):** the "solid blue
> bar" in D1/D4 no longer stands — idle is drawn as **zero** (gray track + blue pill at zero) in both
> `BarStyle`; under Progress a time marker is added on top, at zero. The color and the "ready to
> start" status remain, only the shape changed.

> **Partially superseded by [ADR-0074](0074-one-reset-format-on-both-surfaces.md)
> ([#284](https://github.com/artem-from-ua/tokenpace/issues/284)):** **D3 is fully canceled** —
> `ResetClock.timeToResetCompactDays` no longer exists. It was needed only because `timeToReset`
> switched to a wall clock past 90 minutes, and `20:40` for a reset several days out reads as
> nonsense; once the threshold was removed, `timeToReset` **itself became** `relativeRounded`, so the
> separate entry point lost its purpose and merged into it. Accordingly, in **D2** "or "20:40" (< 24
> h)" now reads as "`20h` / `45m` — the same one-piece format." The rest of the ADR (honest idle
> detection, no phantom `now+5h`, "4d" for a distant 7d reset) still stands.
>
> **Partially superseded by [ADR-0038](0038-idle-blocked-status.md):** the D1/D4 decision — "idle →
> always solid blue + `ready to start`" — is canceled: when idle is **blocked** (7d exhausted and
> credits don't cover it), the bar turns **gray**, the status becomes "waiting for limit reset," and
> the blocking reset is highlighted in red. The rest of this ADR (honest idle detection, no phantom
> `now+5h` reset, `is_active` unused) still stands.
>
> **Partially superseded by [ADR-0059](0059-menu-bar-native-semantic-colours.md):** the D7 decision
> about "menu-bar idle bar = fixed sRGB `Palette.statusBlue` (70/140/230)" is canceled — the menu bar
> now draws `.systemBlue` (like the popup), which flips with the theme and honors Increase Contrast.
> The idle-state logic still stands.
>
> **Partially superseded by [ADR-0060](0060-popup-native-semantic-colours.md):** the popup's idle bar
> is **no longer desaturated** — it used to take `.systemBlue` muted ~15% toward gray (+~22% toward
> white in light mode); now it's a **pure** `.systemBlue`, the same unified `blue` as the menu bar.
> The idle-state logic still stands.

## Context

After a few hours of no Claude usage, the popup showed "5-hour / 0% / on pace / 5h at 17:40," and the
menu bar showed "17:40," even though an active 5-hour session **did not exist**. "17:40" is a
synthesized time (`now + 5h`, rounded up to a 10-minute grid) that "crawls" forward with every poll;
that day, the real reset turned out to be at 18:39. So the widget showed a confident, specific, but
**invented** time, and a false "on pace" pacing status on an empty window.

### Verified server semantics (2026-07-24, live payloads + raw session transcripts)

1. **`five_hour.resets_at: null` is the normal state of "no 5h window exists right now."** The window
   is **created by the first token spend**. The mechanics (verified against token records): start =
   first token spend, rounded **down** to a 10-minute grid; reset = start + exactly 5 hours (first
   tokens at 10:47:04Z → floor 10:40 → reset 15:40:00Z, reported as `15:39:59.63Z`; the preceding
   pause was 8 h 14 min — verified empty).  Every historical live capture of `resets_at` lies within
   ±1 s of a 10-minute boundary.
2. **`limits[].session.is_active` is an unreliable detector.** A live session at 2% had
   `is_active: false` (Payload B), while a June fixture had `true` at 26%. **Do not use it.**
3. **A reliable idle detection:** no `resets_at` in either `five_hour` or the matching `limits[]`
   entry (`session`/`five_hour` kind) — exactly the branch that previously synthesized a local
   estimate for `five_hour`.

### Payload A (idle, verbatim from a live capture)

```
{"five_hour":{"utilization":0.0,"resets_at":null,...},
 "seven_day":{"utilization":31.0,"resets_at":"2026-07-28T07:00:00.405400+00:00",...},
 "seven_day_opus":null,"seven_day_sonnet":null,
 "limits":[{"kind":"weekly_all",...,"is_active":true},
           {"kind":"weekly_scoped",...,"display_name":"Fable","percent":15,...}]}
```

There's no `kind:"session"` entry at all → there's nowhere to get `five_hour.resets_at` from → **the
window doesn't exist**.

### Payload B (an active session with `is_active:false`)

```
{"five_hour":{"utilization":2.0,"resets_at":"2026-07-24T18:39:00...+00:00",...},
 "limits":[{"kind":"session",...,"percent":2,...,"is_active":false},...]}
```

A real `resets_at` is present → the window **is active**, despite `is_active:false`. This pins down
why the flag is ignored.

### Community consensus

The `/api/oauth/usage` endpoint is not officially documented (an internal Claude Code endpoint). The
"no active window" state is widely known: OSS monitors (ccusage, Maciek, quotio, ClaudeBar, ccseva)
treat "no active session" as a first-class state — the label stays, the countdown degrades, **the
time is never invented**. The only synthesizer of a fake `now+5h` we found (Claude-Usage-Tracker)
already produced bugs of its own — an antipattern we had been repeating.

## Decision

Introduce an honest "no active 5h session" state, API-driven off the absence of `resets_at`.

- **D1. Model.** `UsageSnapshot.sessionIdle: Bool` (new, last in the memberwise init with a default of
  `false` → all fixtures still compile). `fiveHour` stays non-optional with `resetsAt: ""`.
- **D2. Menu bar.** Both bars remain (the idle collapse from ADR-0015 does **not** return). The
  5h mini-bar in idle is **solid blue, with no dot** (time indicator). The time on the right is the
  **7-day reset**: "4d" (≥ 24 h, a new short format) or "20:40" (< 24 h). `MenuBarMode` is unchanged;
  `BarView` gets `idle: Bool = false`.
- **D3. Day format.** A new `ResetClock.timeToResetCompactDays`: `≥ 24h` → `.relative("4d")` (the
  same arithmetic as the popup — menu bar and popup always agree); `< 24h` delegates to the unchanged
  `timeToReset`. No new enum cases.
- **D4. Popup, 5-hour row.** Title "5-hour" + status "ready to start"; **a solid blue bar with no
  dot**; **there is no second text line at all** (no "0%", no time). Tick marks remain.
  `LimitRow.sessionIdle: Bool = false`; the view skips the second line when `sessionIdle`.
- **D5. Decode.** `UsageSnapshot.window(...)` gets a `localEstimateAllowed` parameter and returns
  `(window, sessionIdle)`. The "own resets_at" and "limits[] fallback" branches are byte-for-byte as
  before (boundary blips don't regress). An exhausted chain: for `five_hour`
  (`localEstimateAllowed: false`) → `(UsageWindow(utilization: 0, resetsAt: ""), true)` with no
  decode log; for `seven_day` (`localEstimateAllowed: true`) → the current local estimate (the window
  always exists).
- **D6. Log.** Once per transition, not per poll: a pure `PollingEngine.sessionIdleTransition`.
  `nil|active → idle` ⇒ `"five_hour idle — no active session (resets_at absent)"`; `idle → active` ⇒
  `"five_hour window active again"` (`AppLogger.network.notice`).
- **D7. Color.** A neutral blue for "window not running, full budget available" — green is reserved
  for the pacing status of an active window. Popup: `NSColor.systemBlue` (paired with
  `gapGreen = systemGreen`). Menu bar: a fixed sRGB from the `Palette.statusBlue` family
  (70/140/230), because the menu-bar image is non-template.

## Why this is not a return of idle mode (ADR-0015)

[ADR-0015](0015-no-idle-mode.md) removed a **display collapse based on a local utilization
threshold** (both windows < 5% → collapse to `*`) — it fired incorrectly because it had no tie to
actual activity. This state is **API-driven**: the server says "the window doesn't exist"
(`resets_at` absent). It **cannot** fire incorrectly on an active window (that always has a
`resets_at`), and **the bars never disappear** — the 5h bar just recolors, the 7d bar stays normal.
ADR-0015's operational decision ("the bars are always visible while there's data") is preserved,
which is why 0015 remains `accepted`.

## Consequences

- The menu bar/popup never again show a phantom `now+5h` time and a false "on pace" status on an
  empty window. The idle-state time is a real 7-day reset that doesn't "crawl" between polls.
- The degenerate weekly case (both windows with no reset) still relies on a local estimate for
  `seven_day` → a blue 5h bar + an estimated "Nd" — honest enough.
- Polling cadence is unaffected: `AdaptiveCadence.changed` only compares utilization, so
  idle↔active transitions don't nudge the cadence.
- `is_active` is deliberately ignored in the detection (Payload B).

See also: #100 (this bug), #36 (replacing ⏰ with `<1m` — orthogonal),
[ADR-0014](0014-usage-decode-resilience-on-reset-boundary.md) (partially superseded — see its
postscript), [ADR-0041](0041-idle-grace-on-reset-boundary.md) (a grace period at the reset boundary
that suppresses a false idle right after an active window resets; this ADR's idle detection still
stands).
