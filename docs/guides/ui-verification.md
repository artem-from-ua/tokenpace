# UI verification before a PR

A detailed reference for live-checking menu-bar / Settings changes before a PR: the list of stubs
(`TOKENPACE_STUB=…`), scenarios that have no stub (screen lock, auto-update), and features that
require signing. The short rules live in [CLAUDE.md](../../CLAUDE.md) ("UI verification before a PR");
the specifics are here.

> **The main rule:** do not open a PR until the maintainer has checked the change **live** — on stubs
> and/or on real data. Screenshots from temporary dev-only code **do not count** as verification
> (see below). The working cycle: commit to a feature branch → `swift build` → **hand it to the
> maintainer for review** → wait for confirmation → only then a PR.

> ⚠️ **Screenshot automation is unreliable: the menu bar holds several identically named TokenPace
> instances** (the release plus dev copies from various sessions). AX/`osascript` cannot tell them
> apart, so a blind click on a menu-bar item opens the wrong build; the dropdown (NSMenu) cannot be
> screenshotted at all. **Do not click a menu-bar item by name or index** — reliable UI verification
> means the maintainer opens the right dev icon live himself. The full method (launching, stopping by
> your own PID, why never a broad kill) is in [agent-workflow.md](agent-workflow.md), section
> "Launching the app to check the UI".

> 📸 **A full-screen screenshot is allowed ONLY with the maintainer's explicit permission. Every other
> screenshot captures individual windows only.** `screencapture` without an area restriction
> (`-x file.png`) grabs the maintainer's entire desktop (terminal, chats, private windows) — forbidden
> without his direct "yes", whatever the purpose.
>
> Capture **a specific window by window-id** (`-l<windowID>`), never the screen:
>
> ```sh
> # find the CG window-id of a TokenPace window (the popup is the larger window under the menu bar, layer 101):
> #   a Swift one-liner over CGWindowListCopyWindowInfo, filtering owner == "TokenPace"
> screencapture -o -l<windowID> popup.png   # captures exactly this window
> ```
>
> - **The popup dropdown and the Settings window** are real `NSWindow`s: **open the dropdown** and
>   capture its window by window-id. You do NOT need the whole screen for that.
> - **The menu-bar widget** is captured as **its own area**, not the whole screen — `NSStatusItem` has
>   no window-id, so grab **a tight frame around the widget itself** (`-R<x,y,w,h>` over its rect), not
>   the entire top strip and certainly not the whole desktop.

## `TOKENPACE_STUB` stubs

Launch: `TOKENPACE_STUB=<name> swift run`. A stub swaps out the transport for usage and status
requests (`StubUsageTransport` in `Sources/TokenPace/PollingShell.swift`). The source of truth for the
scenarios is `StubScenario` (`Sources/TokenPace/StubScenario.swift`): each case's `rawValue` = the
stub name from the table below, and `summary` is its description.

> **The live network turns on only explicitly (#267).** In `swift run` the default is `screenshot`,
> not the live API: `swift run` **without** `TOKENPACE_STUB` gives you a frozen frame. To get real
> data in a dev build, ask for it by name — **`TOKENPACE_STUB=real`** (or switch to "Real network (no
> stub)" in dev-tools). An unknown value (`TOKENPACE_STUB=healthy` — there is no such scenario) also
> yields `screenshot` **and** logs a `.notice` listing the valid ids; it used to silently fall through
> to the live network, so a run that looked stubbed was actually hitting production. An installed
> `.app` with no env var is live, as before — nothing changed for the end user.

> **Live switching without a restart (#187, ADR-0047).** With dev-tools enabled
> (`defaults write com.artem-n.tokenpace devToolsEnabled -bool true` on the **installed `.app`** —
> ADR-0053; the key has no effect under `swift run`, because a binary without a bundle id lands in a
> different `UserDefaults` domain), open ⌥ Option → menu → **Development tools…** and pick a scenario
> in the **Data source (stub)** dropdown at the top of the left column — the data source switches
> live (the menu-bar icon and the popup refresh within one polling cycle), and the current scenario's
> description shows below the dropdown. `TOKENPACE_STUB=…` at launch still works and **sets the
> dropdown's initial selection**; "Real network (no stub)" returns the app to the live API. For
> scripting, `TOKENPACE_OPEN_DEVTOOLS=1` still auto-opens the window (the dev-tools gate itself is
> `devToolsEnabled` now, so `.app` only).
> Sequence stubs (`stale-error`, `reset-grace`, `optimistic-reset`, `just-unblocked`,
> `subscription-reset-on-credits`)
> replay from poll #1 when reselected (a fresh `StubUsageTransport` resets the poll counter).
>
> **The stub tag next to Quit (#190).** While any stub is active, the **Quit TokenPace** item under
> ⌥ Option shows the scenario name — even in a **signed `.app`** (where the real notarized build is
> running): `"Quit TokenPace (stub – credits-onset)"` on the `.app`, `"… (dev build – credits-onset)"`
> on the dev binary. The tag also updates on a live stub switch. A clean `.app` on the real network
> carries no tag. This is the most reliable way to confirm at a glance which stub is actually running.
>
> **Stub time is detached from the current date (by default).** So that a frame is reproducible (the
> same day of the week and the same reset times every run), every stub runs off a **fixed** moment
> (`StubScenario.stubClock`) rather than the real clock: most of them off the shared anchor
> **2026-01-14 12:00 UTC (Wednesday)**; `screenshot` off **2026-01-31 22:00 UTC** (end of month), so
> that "Extra usage" reads as a **long green** one (the month is ≈99 % elapsed vs ~22 % spent) with a
> matching "<1d" reset. Both the stub body (`resets_at`) and the render read **the same** clock, so
> the bars and the reset lines never diverge. The exception is scenarios whose behavior **is** the
> passage of time: those run off the real clock (marked ⏱ in the dropdown).
>
> **Markers in the dev-tools dropdown:** **⚡** — the scenario pulls data from the **real usage API**
> (`Real network`); **⏱** — the scenario runs off the **real clock** (`optimistic-reset`,
> `reset-grace`, `color-cycle`); **⏭** — the scenario is a **sequence** that advances one step per
> poll, so you have to watch it **step by step**, and the **Refresh now** button in Troubleshoot is
> that step (`weekly-interp`, `weekly-reset-blackout`, `standby-floor`, `optimistic-reset`,
> `reset-grace`, `just-unblocked`, `subscription-reset-on-credits`, `credits-onset`, `stale-error`).
> Without ⏭ the frame is frozen: after a refresh it looks exactly the same.
> A stub with no markers is fully canned and runs on fixed time.

| Stub | What it shows |
|---|---|
| `1` | climbing — usage creeps upward |
| `screenshot` | a stable frame for screenshots (fixed time 2026-01-31 22:00 UTC): 5h **green** (10 % vs ≈65 % — well behind), 7d **yellow** (36 % vs ≈29 % — mild ahead, under the dynamic threshold `0.16·(1−time)`, deliberately off the amber/orange boundary where the old 40 % used to sit), Fable **orange** / Mythos **red**. **Extra usage** — $1088.00 / $5000.00 (USD, ~22 %) with ≈99 % of the month elapsed → a **long green** "on pace" bar, reset "<1d". There is no "active" badge (no **base** 5h/7d limit is exhausted — only Mythos, and it does not gate work) |
| `error` | an auth error (401) on a cold start → the menu bar shows a **struck-through antenna** (`antenna.radiowaves.left.and.right.slash`, [ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md)), **not ⚠️**: the triangle is reserved exclusively for "the data contradicts itself" (`broken-reset`). The popup shows only the banner, no limit lines |
| `stale-error` | **stale-while-erroring** (the spacing bug): the first poll is valid (full bars: idle 5h "ready to start", 18 % 7d, a Fable line, "Extra usage" €11.7 of €15.0), then every poll times out → the banner "Claude API connectivity issue" / "Authentication API timeout" sits **above** all the bars. **The menu bar has two phases, not three** ([ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md)): before the `max(15 min, 3 × pollInterval)` threshold — the stale bars **with no glyph**; after it — **the struck-through antenna alone**, with no bars. The intermediate "glyph next to stale bars" phase is gone; if you see it, that is a regression. (The transition itself cannot be reproduced with a stub — `failingSince` cannot be wound forward; it is covered by unit tests.) Check the **horizontal spacing between the error text and the "5-hour" line** (the same `sectionSpacing` used after the header) — without it the error block was glued to "5-hour". API + Code — major outage (red dots) |
| `standby-floor` | **the stand-by floor**: 7d is orange, but green is only **≈16 min** away → the `stand by … for green` line under ⌥ **does not appear** (the floor is 20 min). The frame was rebuilt around an **integer** `utilization = 99` ([#386](https://github.com/artem-from-ua/tokenpace/issues/386)): it used to hold a fractional 99.5536 %, which the API never returns for token windows, so the state was arithmetically possible but unreachable. Now the reconstruction pushes the raw `99` deep into the bucket (≈99.30 % against ≈99.14 % elapsed), and the state becomes real. The band is narrow — scanning the whole `(u, reset)` space, the suppression happens in **18 out of 10,064** combinations, all with `u` between 99.15 % and 99.40 %; the culprit is not the quantization step but the 20-minute end-of-window override, which eats every frame with a small lead and a distant reset. The stub moves `h5` by 4 pp per poll so the reconstruction has time to accumulate the required 0.8 pp |
| `weekly-interp` | **the 7d reconstruction** ([#386](https://github.com/artem-from-ua/tokenpace/issues/386)) — watch it as a **sequence**, not as a frame. The weekly counter sits on an integer the whole time (61, and 62 from poll 8) — which is exactly how the API behaves — while the five-hour one grows by 4 pp per poll. So any movement of the 7d bar is the reconstruction at work; there is no other source. Three acts (verified by running this same sequence through the interpolator): **polls 0–7** — the anchor is inherited, the value creeps from the center of the bucket (61.0) up to the ceiling and holds there from poll 6 (`clipped`); half a bucket is all an inherited anchor can honestly claim; **poll 8** — the counter ticks 61 → 62, the anchor hardens onto the lower bound of the new bucket (61.5), the first segment closes and `N` stops being the seed — note that the value **does not jump** at this transition, because the old bucket's ceiling and the new one's floor are the same point; **polls 9–19** — that same unchanging `62` walks the bar 61.5 → 62.5 in 0.1 pp steps, then clips. The key thing to check: the bar **does not jump backward** at either transition, and Troubleshoot shows both numbers the whole time |
| `weekly-reset-blackout` ⏭ | **the weekly 7d blackout, reconstructed** ([ADR-0107](../adr/0107-weekly-reset-reconstructed-from-the-last-known-one.md)) — watch it as a **sequence**, stepping with the **Refresh now** button. The first two polls return a healthy body with a real `seven_day.resets_at` — that seeds the anchor; after that every poll returns what the server actually sends for 4–6 hours after each weekly reset: `seven_day: null` plus a `weekly_all` record **with no date of its own**, meaning both sources of the reset vanish at once. The key thing to check: **the 7-day countdown stops moving** from poll 2 onward. Before this change it stepped forward by ~10 minutes on every refresh, because the `now + 7d` estimate was recomputed each time, and the time marker sat near the left edge permanently. Now the date holds and the marker creeps, as it should |
| `weekly-reset-unknown` | **a cold start** ([ADR-0107](../adr/0107-weekly-reset-reconstructed-from-the-last-known-one.md)): the same blackout body on every poll, but **there is no anchor** — a fresh install that has not spent a single token yet. **Remove the stored anchor first**, otherwise the app reconstructs from it and you will see ordinary bars: `defaults delete TokenPace lastSevenDayReset` (the `swift run` domain). The key thing to check: the menu bar shows the "no data" symbol (**not** ⚠️: that is reserved for "the data contradicts itself", and there is no contradiction here), and the popup **shows no limit at all** — only "Weekly reset time unknown" and a line telling you how to fix it. No countdown anywhere: the whole point is that nothing gets invented |
| `idle` | "no active 5h session" (#100): the 5h bar reads "ready to start" (**green** — there is no blue pill since [ADR-0105](../adr/0105-color-advice-governs-pacing-bars-only.md)), no phantom reset, and the time falls back to the 7d reset ("4d"). **With the default "Hide the top 5h bar" = `Until it needs attention`** ([ADR-0086](../adr/0086-tri-state-calm-bar-hiding.md) → [ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md)), an idle 5h counts as calm and **gets hidden** → only the **7d bar** remains, centered; the green "ready to start" pill is visible only in `Never` mode. Switch it in Settings → Appearance › Menu bar (key `menuBar.hideTop5hBar`, values `untilItNeedsAttention`\|`never`). **The shape is identical in both styles** ([ADR-0078](../adr/0078-idle-drawn-as-zero-in-both-styles.md)): a gray track plus a minimum pill at zero; **Progress** adds the time marker at zero on top (it covers the pill), **Pressure** leaves the pill alone. A solid full-width fill must not appear in either style — it used to read as Pressure "at maximum". When muted, idle in the menu bar must be neither dimmer nor brighter than the calm bars beside it (the same `calmWhite` at the same alpha). **`ColorAdvice` check** ([#343](https://github.com/artem-from-ua/cc-timer/issues/343), [ADR-0105](../adr/0105-color-advice-governs-pacing-bars-only.md)): Settings → Appearance › Menu bar → "Colors tell me" — under **How it's going** the pill is **green**, under both muting modes (`Slow down`, `Slow down or speed up`) it is **white**. There is no longer any difference between those two here: `mutesBlue` distinguished the blue pill, and the blue one no longer exists. Under **Pressure** the pill is white **always**, and the "Colors tell me" row itself is disabled and shows `Slow down` |
| `idle-blocked` | **blocked** idle (#158): idle 5h plus an exhausted 7d (100 %) with no credits → `isBlocked`. **The red pause glyph is always on the left** (#199/#227, ADR-0063) — it can no longer be turned off. There are **no bars at all** here ([ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md)): the menu bar = **pause + countdown**. The "Pause icon hides bars" toggle no longer exists — the hiding is unconditional, so there is nothing left to switch. The gray idle bar survives only in the popup. The credits icon (€) sits **between** the pause and the bars (#227). The popup always shows the full picture: status "waiting for limit reset", and the 7d reset carries a **red badge** (a pill). Compare with `idle`: there you get a **green** "ready to start", which turns **white** (`calmWhite`) under both muting `Colors tell me` modes (and unconditionally under Pressure). Here the **gray** pill is muted in no mode and no style — gray carries "there is nowhere to work", not calm ([ADR-0038](../adr/0038-idle-blocked-status.md)) |
| `active-blocked` | **active** blocked (#177): a live 5h session (48 %) with an exhausted 7d (100 %, `weekly_all` critical) and no credits → the weekly cap blocks despite the 5h quota (`isBlocked`). **The red pause glyph is always on the left** (#199/#227, ADR-0063). There are **no bars** ([ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md)): pause + countdown, and there is no toggle for it anymore. The credits icon (€) sits **between** the pause and the bars (#227). The popup always shows the full picture: the 7d reset gets a **red badge** reading "Effective blocker" |
| `optimistic-reset` ⏱ | the reset boundary (#36): 5h resets in ~20 s — the bar jumps 60 % → 0 % with no ⏰ plus a forced refresh. **Real clock** (⏱): the timer has to tick live, so this stub is not detached from time |
| `color-cycle` ⏱ | **smooth color transitions** (ADR-0070) — **real clock** (⏱: the color sweep drives its own 5-second timer). The 5h bar and the service dot walk the entire pacing palette: blue → green → yellow → orange → red and back, 5 s per zone (a 0.8 s transition plus a pause). **The 5h geometry is frozen** — the strip is pinned at half the track and the time marker parks at its end, so **only the color** moves; 7d / per-model / credits keep their real geometry as a motionless reference alongside. Check that: (1) the color **blends** rather than jumping, both in the menu bar **and** in the dropdown (the dropdown also exercises `.common` run-loop mode under NSMenu tracking); (2) switching "Colors tell me" / Style mid-sweep animates too — check **both** Style rows separately (the menu-bar one and the dropdown one, #329). While you are there, catch **two effects from #381**: switching to **Pressure** disables the "Colors tell me" row (the label and segments gray out, the highlight moves to `Slow down`, and clicks do nothing), and at that same instant the entire calm side turns **white** — the blue/green/yellow stages of the sweep must not be colored under Pressure for any value of the setting. The service dot in the sweep is no longer muted along with the bars — it walks **its own** scale (yellow → orange → red → blue → gray), and **not one** step goes dim under any setting ([ADR-0111](../adr/0111-degraded-dot-is-yellow-on-every-surface.md), [ADR-0105 §1](../adr/0105-color-advice-governs-pacing-bars-only.md)); this doubles as the frame for the `yellow→orange` transition — adjacent tones, the shortest fade distance: it has to read as a blend, not a jump; (3) Progress keeps its slider (it does not collapse into Pressure); (4) between transitions the timer is idle — sitting still must not heat up the CPU. **Not** for checking the pacing thresholds themselves: the `utilization` values here are synthetic and tuned to hit each zone |
| `reset-grace` ⏱ | the grace period at the reset boundary (ADR-0041, ADR-0045) — **real clock** (⏱: the "utilization rose recently" freshness window is measured in real time): an active 5h window (polls 0–1) → an **empty** post-reset body (polls 2–3: `five_hour.resets_at:null`, with no `session` limit — the decoder on its own would produce `sessionIdle`) → active again (polls 4+). In the "hole" the 5h line must show a calm **0 % "on pace" with a rolled-forward countdown** (`Nh at …`), and the menu bar must **not blink** — **never "resetting…" and never a full-width green bar** (ADR-0045). The grace period only arms while Claude Code is active (`claudeActive` — a journal written in the last 5 min, ADR-0117) — otherwise an honest idle "ready to start" shows immediately. Note this gate was silently dead until ADR-0117: the old process probe never matched, so the grace could not arm at all. Compare with `idle`: there the idle is **real** and is supposed to show |
| `broken-reset` | a broken `resets_at` (#167, ADR-0043 → [ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md)): an **exhausted** 5h (100 %) with an **unparsable but non-empty** `resets_at` (`"not-a-date"`, NOT `null` — `null` or empty would give an honest `sessionIdle` rather than an error) → the menu bar draws **a lone ⚠️** (`MenuBarMode.exhaustedUnknownReset`): no bars, no countdown — and **no pause or currency sign beside it**, even though the window is ostensibly at 100 %. The pair "⏸ + ⚠️" would read as a broken widget rather than a state, so contradictory data gets a single signal. If you see a red bar, a pill, a pause, or a fake `<1m`, that is a regression. 7d is calm with a valid reset (not the source of the error) |
| `calm-degraded` | calm bars plus a **`degraded`** service dot. Since [ADR-0111](../adr/0111-degraded-dot-is-yellow-on-every-surface.md) this is the frame about **three surfaces converging**: the menu bar, the popup, and the Legend page all draw this state in the **same yellow**. Check exactly that: open the popup over the bar and compare the two dots in a single capture — they must be **identical**; any difference is now a regression (before [#410](https://github.com/artem-from-ua/tokenpace/issues/410) they differed on purpose). Cycle "Colors tell me" through all three values and switch Style — **none** of them may shift that yellow: this is the check that [ADR-0105 §1](../adr/0105-color-advice-governs-pacing-bars-only.md) still stands (the tone changed, not who decides it). A white dot must not appear in **any** state. The louder states are unchanged on both surfaces (check them on `incident-*`: `partialOutage` orange, `majorOutage` red, `underMaintenance` blue, `unknown` gray). The screenshot **must be of the real menu bar**, and **separately on the light theme** — the question there is not "is it visible" but whether the yellow reads as an alarm next to the system icons |
| `all-green` | calm bars plus **all services operational** (green): `worstProblem == nil`, so the popup has **no status lines at all** — neither without ⌥ nor under it. Since #279, ⌥ switches the **dimension** (services → incidents) rather than "show more", so green lines no longer expand; with no incidents, the section under ⌥ is simply absent. This is the frame for checking that "nothing appears for nothing" (the remaining stubs are all-operational too — except `error`, `stale-error`, `calm-degraded`, and `incident-*`) |
| `just-unblocked` | the "Back to work!" edge (#160): the first poll is blocked (7d=100 %, no credits), then workable (7d=40 %) → the notification fires once. Without credits the old and new semantics coincide, so this is the **regression** scenario. See its own section below |
| `subscription-reset-on-credits` | the "Back to work!" edge **with credits active** (#161, [ADR-0113](../adr/0113-back-to-work-tracks-the-subscription-quota.md)): the first poll has 7d=100 % **with credits enabled** — work does not stop (`canWork` = `true`), but the subscription is exhausted — then 7d=40 % → the banner fires. This is exactly the edge the old signal could not see, so it is the **main** check of the change. See its own section below |
| `credits-onset` | the "Now using Extra usage credits" edge: the first poll is **not** on credits (7d=40 %, credits enabled but the base limit not exhausted → `isOnCredits=false`), then 7d=100 % with the same enabled `spend`/`extra_usage` → work spills over onto paid credit → the notification fires once (€10.77 / €15.00). See its own section below |
| `incident-active` | One active incident, Code + API `degraded`. Without ⌥ you get two service lines with ages (`2h7m · degraded`) and the subscribe line. Hold **⌥ Option** — the service lines are **replaced** by the incident line: the description wraps across several lines, and `2h7m · identified` sits on the right of the last description line; the stage word links to **that specific** incident |
| `incident-green` | An incident that is formally **open** (`monitoring`) while every monitored component is already `operational` — a measured 66-minute gap. **Nothing** may render: no service lines, no incident line under ⌥, no subscribe button. The most valuable of the four — "nothing is shown" breaks without anyone noticing |
| `incident-two` | Two simultaneous incidents over the same degraded components (the real shape from 2026-08-05 14:00). Under ⌥ you get two lines, each with its own dot, age, and link, and **one** subscribe line: you subscribe to the episode, not to the ticket |
| `incident-wrapped` | Three incidents chosen **for the way their titles wrap** (#351) — all three chip placements in a single capture. Under ⌥: (1) the first ends its last line early → `2h7m · identified` **shares** that line with it; (2) the second wraps onto two lines and pushes `13m · investigating` onto a **third**; (3) the third fits on **one** line, but there is still no room for the chip → `6m · investigating` stands **alone on the second line**, leaving a wide gap after the title — the most illustrative shape. Every chip must sit **on the right**; before the fix, wrapped ones dropped to the left edge |
| `incident-spacing` | Two degraded services and two **short, single-line** incidents — the frame for judging **vertical rhythm** (#351). Toggle ⌥ back and forth: two lines swap for two lines of the same height, so the gaps must not change. All four must match — incident↔incident, incident↔subscribe, service↔service, service↔subscribe. Before #351 the incident gaps were 8 pt against 3 pt for the service ones |
| `incident-recovery` ⏱ | A quiet recovery: the first two polls carry a degraded incident with an update, then the components turn green **with no new update at all** (the `mgp99sn4ynd4` case). The lines must disappear on their own; an update listener would have stayed silent for 43 minutes. See its own section below |
| `pressure-sweep` | **The Pressure scale** ([ADR-0076](../adr/0076-pressure-scale-for-marker-less-bar.md), [ADR-0101](../adr/0101-pressure-is-the-gauge-ahead-half.md), #307). 5h: three points from exhaustion with 7 % of the window left (`t≈93 %`, `u=97 %`) — on the window scale that is 4 % of the bar, i.e. **below** the minimum pill; on the remainder scale it is ≈ **57 %**. 7d: a moderate lead (`t=30 %`, `u=38 %`) → **11 %**, inside the yellow band (0–16 %) and just above the minimum pill (8.1 %) — this is the **tightest** pair in the app, so this is where you look at whether the yellow still reads as a short strip rather than a dot. Check that: (1) switching **both** Style rows to **Progress** makes the pacing bars look exactly as they did before #307 (marker in place, `subdivisions − 1` ticks); (2) under **Pressure** the 5h strip is five times wider than the 7d one, and there are no ticks in the popup at all — only the zero line, labeled `0` under ⌥; (3) switching **Menu bar** between **Pressure** and **Balance** must not move the 7d strip by a single pixel, because Pressure is exactly the ahead half of Balance; (4) set **Menu bar → Pressure** and **Dropdown → Progress** — that is the pair the "Mixed" case used to produce before #329, and it is where a stored `mixed` migrates ([ADR-0080](../adr/0080-per-surface-bar-style.md)) |
| `balance-sweep` | **The Balance scale** ([ADR-0079](../adr/0079-centred-zero-gauge-scale.md), #326). One line per side of center. 5h is deep behind (`t = 90 %, u = 70 %`): the headroom is twice the remaining time, so `r = −2` clamps to `−1` and **the left half is full**. This is precisely the state every other style draws as a minimum pill — Pressure collapses it to zero outright. 7d carries the same moderate lead as in `pressure-sweep` (`t = 30 %, u = 38 %`) → a short strip **to the right** of center (`+11.4 %` — **the same number** the Pressure bar draws: after [ADR-0101](../adr/0101-pressure-is-the-gauge-ahead-half.md) Pressure **is** that half, so switching styles does not move it). Check that: (1) the center line is present in **every** state, idle included, and only its tips stick out from under the track — it must not read as a Progress marker; (2) switching Pressure ↔ Balance does **not** change what the 7d line says; (3) on Balance the 5h line is the widest thing on screen, on Pressure the narrowest; (4) under a muting "Colors tell me" the direction is the only remaining cue — that is the case that decides whether the trade-off is acceptable. While you are there, compare against **Pressure**: the calm side there is white **unconditionally**, so Balance is where you can see that the "Colors tell me" choice still means something — and that is exactly why the row is disabled only under Pressure ([ADR-0105](../adr/0105-color-advice-governs-pacing-bars-only.md)); (5) both surfaces — in the popup there is a single tick, in the middle. Since #329 Balance is the **default** on both surfaces (the Work harder! preset), so on a fresh install it shows up right away, with no manual selection; while you are there, check that Balance leaves the preset on **Work harder!** rather than dropping it to `Custom`, as it did before [ADR-0080](../adr/0080-per-surface-bar-style.md) |

### The money credits icon (#144)

The currency icon (`coloncurrencysign` ¤ / `eurosign` €, and so on) sits in the **leading** position:
in the bar modes (`.expanded`/`.iconOnlyReset`) it leads; only in the diagnostic `.error` mode does it
stay trailing (to the left of the service dot). All three frames pin 7d at 100 % (the base limit is
exhausted → the display trigger fires) and differ in their `spend` block. Since credits cover the
exhausted window (`subscriptionExhaustedWhileCovered`, not `isBlocked`), there is **no** pause glyph
here — but since [ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md) this is a separate state,
"we're working on money": **there are no bars either**, and the widget = the currency sign + a
countdown to the subscription quota coming back. There is no user gate on the icon anymore — the data
decides it.

| Stub | Credits state | Icon color |
|---|---|---|
| `credits-active` | enabled, limit €15.00, spent €10.77 (~72 %) | usage-vs-time pacing (green when not ahead, amber/orange when ahead) |
| `credits-limit-reached` | `spend_limit_reached` (a €5.00 limit below €10.77) | **red** (forced usage = 1) |
| `credits-no-limit` | enabled, limit "unlimited" (`limit: null`) | **neutral** (foreground, no pacing) |
| `credits-zero-spent` | "€0 of €15 ⟷ `<reset line>`" — both halves drop their zeros, each for its own reason: the spend because it is untouched (`amountMinor == 0`), the cap because it is a whole number. Under **⌥** it becomes "spent €0.00 of €15.00", and the reset **stays**: in a 320 pt column (#396) the pair takes 276 pt. The cap stays on the line even at zero: without it the line would read as unlimited, and that is a different billing configuration. The bar is at zero. There is **no badge at all**: credits are enabled, but nothing is spilling over — and the mere presence of the section already says so (ADR-0108) |
| `credits-max-header` | **The widest first line** (#396), and the one that sets the popup's width: `Extra usage ･ progress ⟷ [$] well ahead of pace` = 307 pt against a 320 pt column. What to look at is that the two halves **do not touch** — a visible gap must remain between the badge and the status. The word `progress` (italic, after the `･`) appears only under **⌥**. The token limits here are deliberately **healthy** (7d at 42 %), otherwise the state "credits enabled but not in use" is unreachable |
| `credits-max-detail` | **The widest second line**: a four-digit cap, spent down to the cent, so both halves carry thousands separators — `spent $5,000.00 of $5,000.00`. Together with the longest reset phrasing that comes to 376 pt, so the fit gate **drops the right half entirely** (rather than truncating it into an ellipsis). The heading above it reads `limit reached` in **plain text, with no badge**: the cap exists, so the red belongs to the reset badge below, not to the heading (one filled red per line) |
| `credits-no-limit-spent` | **The only state where the red sits in the heading**: `limit: null` + `spend_limit_reached: true`. There is no reset (with no cap there is nothing to reset), so no carrier for the red exists below — and the `out of credits` badge settles into the heading. Compare with `credits-limit-reached`, which does have a cap: there the heading is plain text and the red capsule is on the reset |
| `all-exhausted-credits-block` | **Everything is exhausted — 5h, 7d, and the €15 cap at 100 %** — but the token windows reset **later** than the month does (7d in 40 days). By the last-line-of-defense rule (`BlockingReset.select`), the credits reset is then the first way back, so the **red reset badge sits only on the Extra usage line**. Both token lines say `limit reached`, but their resets are in ordinary dim text. The Extra usage heading has **no** state badge: the cap is exhausted, so the red belongs to the reset below |
| `all-exhausted-token-blocks` | **The same three limits are exhausted**, but the 7-day window resets **last** (in 24 days, past the end of the month). The red badge moves onto the **7-day** line, and the credits reset becomes ordinary. A pair with the previous one: identical percentages, identical amounts, one red badge each — on different lines. Run them back to back to see the rule itself rather than a coincidence |
| `credits-month-end` | A check of the **tightest spot** on the monthly ruler (ADR-0092): the clock is at 90 % of the month, so the time marker gets as close as it ever does to the right-hand `Jan 31` label. What to look at is that the marker and the label **do not touch** and that the label stays readable despite the marker's glow. This doubles as the main check of the decision itself: switch Settings → Appearance › Dropdown → Style to **Pressure** and to **Balance**; the token bars become marker-less strips while this one stays Progress with its marker and labels — the question is whether it reads as *a different instrument* rather than as a glitch |

> Check that the amounts carry the **€** currency (not `$`): the formatter takes the symbol from the
> currency code (EUR→€). The section's bar is the same `PopupBarView` as the token bars, but with
> **its own scale and ruler** ([ADR-0092](../adr/0092-extra-usage-own-ruler.md)): always **Progress**
> regardless of the dropdown's Style, and **without** ticks. The month-edge labels (`Jan 1` … `Jan 31`)
> have been **removed** ([ADR-0108](../adr/0108-extra-usage-one-anatomy-and-per-bar-style-caption.md)):
> they restated what already stands on the reset line directly above the bar, and added half a line of
> text below it every time you pressed ⌥. Under ⌥ the scale is now named by the **style word** in the
> heading — `Extra usage ･ progress`.

### Dropdown section visibility: "Show per-model and per-service limits" and "Show *Extra usage*" (#211)

Settings → **Dropdown**. Both options are `PopupSectionVisibility`, but their segment sets **differ**
([ADR-0087](../adr/0087-above-zero-section-visibility.md), narrowed in
[ADR-0100](../adr/0100-dropdown-style-tiles-and-retired-option-segment.md), renamed and reversed in
[ADR-0104](../adr/0104-appearance-named-for-behaviour-on-three-layers.md)):

```
Show per-model and per-service limits   [ When it needs attention | Once used | Always ]
Show *Extra usage*                      [ Once used | Always ]
```

**Segment order — quieter on the left** ([ADR-0104 §6](../adr/0104-appearance-named-for-behaviour-on-three-layers.md)):
the leftmost option leaves the least on screen. Before #381 both rows ran the other way (`Always` on
the left) — if you see the old order, that is an old build, not a styling variant.

| Mode | Behavior |
|---|---|
| `When it needs attention` (the `.chill`/`.workHarder` default for **per-model**; **not offered** for Extra usage) | visible when at least one of its lines is **orange or red** (`.ahead`/`.exhausted`) — **or** while ⌥ is held |
| `Once used` (the `.chill`/`.workHarder` default for **Extra usage**) | visible when it contains anything non-zero: a per-model line with `utilization > 0`, or money spent — **or** while ⌥ is held |
| `Always` | the group is always visible |
| ~~`With ⌥ Option`~~ | **Removed from both rows** (#374) and **deleted from the enum** (#381). The `.optionOnly` case no longer exists; the old raw value resolves to `onceUsed` through `PopupSectionVisibility.legacyRawValues` — see the recipe below |

The first gates the per-model/per-service lines (`Opus`/`Sonnet` from the legacy fields plus
`weekly_scoped` as `Fable`/`Mythos`), the second gates the **Extra usage** section. Blue `far behind`
is **not** alarming (`.farBehind` is calmer than green), so it does not expand the group.

> **The same words as in the menu bar — deliberately.** `When it needs attention` here and
> `Until it needs attention` on the "Hide the top 5h bar" row are **one threshold** viewed from two
> sides: the first decides when to **show** a section, the second when to **stop hiding** a bar
> ([ADR-0104 §7](../adr/0104-appearance-named-for-behaviour-on-three-layers.md)). The predicates
> differ, though: here it is `.ahead`/`.exhausted`, there it is `BarView.isCalm`, which counts a blue
> `farBehind` as calm. The divergence shows on `far-behind`: a blue 5h does **not** expand the group
> here, but it also does **not** stop being hidden there.

**The two predicates measure different things and do not substitute for each other.** `Once used`
reads the **value**, `When it needs attention` reads pacing's **verdict** about that value. That is
why 2 % at the start of the week is both "used" and "needs attention" at once (pacing reads that
small number as `.ahead`), while €10.80 spent against an **unlimited** cap is "used" but **never**
"needs attention": with no cap there is no bar, and therefore no severity. That is exactly why the
credits row does not offer `When it needs attention` at all.

```sh
TOKENPACE_STUB=screenshot swift run          # Fable 70 % (orange) + Mythos 100 % (red)
TOKENPACE_STUB=credits-active swift run      # €10.77 of €15 — the section with a bar
TOKENPACE_STUB=credits-zero-spent swift run  # €0 of €15 — Once used hides it
TOKENPACE_STUB=credits-no-limit swift run    # €10.8 unlimited — Once used shows it
TOKENPACE_STUB=credits-month-end swift run   # 90 % of the month — marker near the right edge
TOKENPACE_STUB=credits-max-header swift run  # widest 1st line (307 pt) + the [$] badge
TOKENPACE_STUB=credits-max-detail swift run  # widest 2nd line — the gate drops the reset
TOKENPACE_STUB=credits-no-limit-spent swift run  # unlimited + exhausted → red in the heading
TOKENPACE_STUB=all-exhausted-credits-block swift run  # everything exhausted → red on credits
TOKENPACE_STUB=all-exhausted-token-blocks swift run   # same thing, but red on 7-day
```

> On `credits-month-end`, look specifically at the bar's **right edge**: the time marker gets as close
> to the end of the track as it ever does, and the question is whether it reads separately from the
> capsule's end cap. The edge labels are gone from there
> ([ADR-0108](../adr/0108-extra-usage-one-anatomy-and-per-bar-style-caption.md)); the stub's clock is
> pinned to January 28 — [ADR-0092](../adr/0092-extra-usage-own-ruler.md).

- `Always` → the lines are in place; holding ⌥ changes nothing.
- `When it needs attention` on a stub with an orange/red per-model line (`screenshot`) → the lines are
  visible without ⌥.
- `Once used` on `credits-zero-spent` → the section is **absent** (€0 spent); on `credits-active` and
  `credits-no-limit` → the section is visible.
- **The key blind-spot check:** on `credits-no-limit`, switch the Extra usage row to `Once used` — the
  section must be visible. This is the case where the verdict-based mode hid the spending forever —
  and that is exactly why the credits row does not offer it.
- `When it needs attention` → hold **⌥ Option** with the menu open: the group appears **live** (the
  50 ms polling timer from ADR-0020) and the popup re-measures; release it → it disappears. Same for
  `Once used`.
- **⌥ remains the escape hatch even though the segment is gone:** in **any** mode, holding ⌥ expands
  the group. That was the reason to retire `With ⌥ Option` — that segment differed from the rest only
  in that it hid the group precisely when its data got interesting.
- **Settings width:** the "Show per-model and per-service limits" row has **three** segments, "Show
  *Extra usage*" has **two**; check that they neither overlap the heading nor get truncated. The Extra
  usage row's label carries **italics** on the section name (`Text(.init("Show *Extra usage*"))`), so
  make sure the markdown rendered rather than showing literal asterisks.
- The switch applies **immediately** (a live callback, no repoll) and persists across launches.
- **Separator:** when Extra usage is hidden, the last visible bar must not pick up extra spacing; the
  same holds when the per-model group is hidden (the view computes "the last line" from the visible
  set).
- **The red reset badge** (`blockingReset`) must stay on its own line in every mode: lines are hidden
  by skipping, without renumbering the indices.

> **Watch out while verifying:** several TokenPace instances may be running at once (yours from
> `/Applications` and the dev build). Do not click the status item through AX by name or index — you
> will hit the wrong build; look up the process by the **full path** to the worktree binary. The dev
> build writes to its own `com.artem-n.tokenpace.dev` domain, so it does not touch your real settings.

Migration from the old boolean toggle (one-time, on the first launch):

```sh
defaults write TokenPace showModelSpecificLimits -bool false
# after launch: dropdown.showPerModelLimits = whenItNeedsAttention, the old key is deleted
defaults read TokenPace | grep -i -e showPerModelLimits -e ModelSpecific
```

**The old `nonCalm` / `aboveZero` / `optionOnly` values no longer have migrations of their own.** Both
marker keys (`extraUsageVisibilityMigratedFromNonCalm`, `sectionVisibilityMigratedFromOptionOnly`)
were retired: the value is carried **along the way**, while the key is moving to its new name, through
`PopupSectionVisibility.legacyRawValues`
([ADR-0104 §4–§5](../adr/0104-appearance-named-for-behaviour-on-three-layers.md)). The full scenario is
in the section [Migrating Appearance keys from the old config](#migrating-appearance-keys-from-the-old-config-381)
below; briefly, for these two rows:

```sh
defaults write TokenPace modelLimitsVisibility -string optionOnly
defaults write TokenPace extraUsageVisibility  -string nonCalm
TOKENPACE_STUB=screenshot swift run
# after launch: dropdown.showPerModelLimits = onceUsed, dropdown.showExtraUsage = onceUsed,
# in Settings the "Once used" segment is highlighted in both rows, and the old keys are gone
defaults read TokenPace | grep -i -e Visibility -e showPerModelLimits -e showExtraUsage
```

The logs (`log stream … --level debug`, category `lifecycle`) must contain the lines
`show-per-model-limits: migrated optionOnly → onceUsed` and
`show-extra-usage: migrated nonCalm → onceUsed`. The second one is that same **fold** for the credits
row: `nonCalm` resolves to `whenItNeedsAttention`, which this control does not offer, so before being
written it folds into `onceUsed` (`foldedForCredits`). Without that, the row would open with **no
segment highlighted at all** — and that is the main thing checked here by eye rather than in the log.

**Idempotency without a marker.** The step is gated on "the new key does not exist yet" and **eats**
the old one, so completion is evident from the old key being gone. Check exactly that: a second launch
writes nothing to the log; set `defaults write TokenPace dropdown.showExtraUsage -string always` by
hand — the next start does **not** overwrite it back (the old key no longer exists).

An explicit `true` → `always`, an explicit `false` → `whenItNeedsAttention` (before #374 it was
`optionOnly`, which the control no longer offers), and a missing key → the preset default
(`whenItNeedsAttention`). Check all of this in the dev domain (`swift run` writes to `TokenPace`, the
signed dev build to `com.artem-n.tokenpace.dev`), **not** in the real domain with your own settings,
and do **not** run `defaults delete` on the domain — that wipes the real settings.

### The "Claude Code" header in the dropdown: update time + service list (#227)

Two behaviors in the popup's header, both tied to ⌥ Option (`PopupViewController.optionHeld`,
`rebuild()`):

- **The update time ("updated 2m ago" / "updated just now")** sits **on the left, right after the
  "Claude [plan]" brand** on the same line (the right edge of that line belongs to the awaiting-input
  indicator alone, and stays empty when there is none). It is now shown **whenever the data is stale**
  — that is, when its age exceeds `PopupViewController.staleAgeThreshold` (2× the base polling rate
  `PollingEngine.baseInterval` = 360 s / 6 min); below that threshold it appears **only while ⌥ Option
  is held** (as before). The check: open the dropdown shortly after a poll (< 6 min) — no time is shown
  until you hold ⌥; leave the dropdown open for > 6 min (or kill the network with the `stale-error`
  stub) — the time appears on its own without ⌥.
- **The service list** is shown when there is a problem (`serviceStatus.worstProblem != nil`, e.g. the
  `error` stub), when some component **turned green in the last 15 min** (#279 — so that something just
  fixed does not vanish instantly, leaving a popup indistinguishable from "nothing ever broke"), **or**
  while **⌥ Option** is held and there is something to show in the incident dimension.

  Since #279, **⌥ switches the dimension, not the level of detail** (ADR-0071 §2): incident lines are
  shown instead of service lines. Healthy green lines no longer expand under ⌥, and if there are no
  active incidents, the section under ⌥ is simply absent. Each service line carries the age of its own
  state (`2h7m · degraded`) from `components[].updated_at`.
  Three checks:
  - `TOKENPACE_STUB=error` — open the dropdown: only the non-operational lines are visible; ⌥ adds
    nothing (there are no incidents in this frame).
  - `TOKENPACE_STUB=all-green` — all services are green: there are **no status lines at all**, with or
    without ⌥.
  - `TOKENPACE_STUB=incident-two` — hold ⌥: the service lines are **replaced** by two incident lines
    (a live rebuild, no repoll), and the subscribe line stays in exactly the same place.

### The "stand by … for green" line under ⌥ (the 7-day bar)

When the **7-day** window is orange, a **third** line appears under ⌥ between the details line and the
bar, aligned to the **right** edge: `stand by 2d for green` — how long you have to not spend for the
bar to return to the green zone. The tone is the same `dimmedLabel` as the details line; the line has
**no color of its own** (the verdict is carried by the bar, not by the text).

The duration goes through the same formatter as the reset (`ResetClock.rounded(duration:)`), so there
is a single unit at any distance — `45m`, `3h`, `2d`. If you see `1h30m` or a wall-clock time, that is
a regression.

Checks:
- `TOKENPACE_STUB=calm5-orange7` — 7d is orange, the wait is ≈44 hours. Hold ⌥: `stand by 2d for green`
  appears under the `resets in 5d on Friday` line, its right edge in one column with the reset above it
  and with the right edge of the bar below it. Release ⌥ — the line disappears and the section's height
  comes back.
- **The line never appears on the five-hour row under any conditions** (`5h-orange`, `both-orange` —
  hold ⌥ and confirm that exactly one stand-by line appeared, under 7d). The five-hour window resets
  twice a day and fixes itself, so the price of pausing there interests nobody.
- `TOKENPACE_STUB=standby-floor` — 7d is orange, but green is only **≈16 min** away: the line is
  **absent** (give the stub a few polls — the reconstruction needs to gain ≈0.8 pp to enter the
  suppression band) even under ⌥ (the `PacingModel.standByFloorSeconds` floor, 20 min). The rest of the
  section under ⌥ behaves as usual — this is the check that it is this one line being hidden, not the
  whole detail level.
- A green/yellow/blue 7d (`calm-both`, `far-behind`) and a red one (`both-red`) — no line: there is
  nothing to wait for, and an exhausted window is cured only by a reset.
- **Popup height**: when the line appears and disappears, the bottom edge must not get clipped —
  `NSMenu` does not re-measure a hosted view on its own
  ([ADR-0021](../adr/0021-popup-two-column-layout-and-uniform-dropdown-typography.md) §2).

The product rationale (why the signal exists and why there are three layers of silence) is in
[users-and-goals.md](../reference/users-and-goals.md#the-stand-by--for-green-line-what-it-adds-and-why-it-is-almost-always-silent).

### The limit details line: words under ⌥ Option

The line under each limit's heading ("how much is eaten ↔ when it comes back") carries **bare numbers**
at rest — `20%` on the left, `2h at 02:50` on the right. With **⌥ Option** held, both halves expand
into sentences: `20% used` and `resets in 2h at 02:50`. The same gate as in the header (`optionHeld` →
`rebuild()`), so the switch is **live**, with no repoll.

The `resets in` prefix is added to **all** format bands, not just the clock one: `resets in 15d`,
`resets in 7d next Monday`, `resets in 5d on Friday`, `resets in 45m at 02:50`. The `resetting…`
fallback (the reset has already arrived) is already a sentence, and ⌥ does not change it.

The red badge of the blocking reset (`blockingReset`) expands **along with everything else** — ⌥
consistency matters more here than anything else.

> **Open defect.** The text inside the badge capsule has **more padding on the left than on the right**
> (most noticeable on the currency marker), and toggling ⌥ shifts its subpixel phase almost
> imperceptibly. The cause is not padding: it was measured that `NSStackView` stretches the capsule
> 4 pt beyond its `intrinsicContentSize`, and with the text pinned to the trailing edge, all of that
> slack opens up on the left. **The signature to check:** take two frames (⌥ down / ⌥ up), align them
> on the capsule's **right** edge, and XOR them. Right now the shared `5d on Monday` tail lights up
> with the full outline of every letter (measured: max difference 121, 77 columns out of 95) — which
> means the text sits at different positions. Once the defect is fixed, that tail must be **black**.
>
> Twelve approaches (rounding the capsule and text widths, separate padding for symbols, compensating
> for SF Symbol side bearings, `.required` hugging, an explicit width constraint, shifting
> `drawingRect`, `titleRect`, trailing kern, manual drawing) were measured and rejected — the list and
> the numbers are in
> [agent-workflow.md § "Subpixel phase comes from the STRING"](agent-workflow.md#subpixel-phase-comes-from-the-string-not-from-layout--fix-the-text-not-the-geometry).
> The next attempt has to start from **why** the 4 pt stretch happens despite `.required` hugging, not
> from tuning a constant.

Checks:
- Any ordinary stub (e.g. `screenshot`) — open the dropdown: the details lines are bare
  (`20%   2h at 02:50`). Hold ⌥ — the words appear on **all** lines at once, per-model lines included
  and **the red badge included**; release it and they disappear.
- `TOKENPACE_STUB=credits-active` — hold and release ⌥ while watching the **right edge** of the
  `resets in …` lines: they must stay perfectly still (that is the `addSplitRow` fix, measured
  0.167 → 0.000 pt). The badges still carry the defect described above.
- `TOKENPACE_STUB=credits-active` — under ⌥ the "Extra usage" line also picks up `resets in` (the
  credits reset goes through the same formatter, `CreditsRow.resetLineVerbose`).
- A stub with a distant reset (7d a few days out) — under ⌥ it must read `resets in 5d on Friday`,
  not just the clock form.

  Service statuses are **non-operational only in the stubs that actually check them** — `error`,
  `stale-error`, `calm-degraded`, and `incident-*`. The remaining frames (pacing, credits, idle,
  color-cycle, and so on) return an all-operational status, so that an unrelated service dot does not
  add noise to a frame that is checking something else entirely.

### Plan label next to "Claude" in the popup header

To the right of "Claude" (in the brand color) the plan name is drawn: `Claude ･ Max (5x)` — "Claude" and the
`･` separator are bold, the plan name is not, and all of it is terracotta (`claudeBrand`). The source is the Keychain's
`rateLimitTier` via `claudePlanLabel(rateLimitTier:)` (whitelist: `default_claude_max_<N>x`→`Max (<N>x)`, `default_claude_pro`→`Pro`,
everything else→nothing). An unknown/missing tier → just "Claude" **without** the separator.

- **On a stub:** any `TOKENPACE_STUB=…` (`StubTokenProvider` returns `default_claude_max_20x`) → the header
  shows `Claude ･ Max (20x)`. 20x is deliberate (rather than the usual local 5x), so that you can see the label is data-driven.
- **On real data (`swift run` with no stub):** shows your actual plan from the Keychain (e.g. `Claude ･ Max (5x)`).
- **Fallback:** if the Keychain's `rateLimitTier` is unknown/missing — it must be just "Claude", with no dot.

### The "Back to work!" notification (#160, ADR-0039; the signal — #161, [ADR-0113](../adr/0113-back-to-work-tracks-the-subscription-quota.md))

A system notification on the **"the subscription quota is available again"** edge — 5h/7d is no longer at 100%.
The signal is `WorkAvailability.subscriptionAvailable`; **Extra Usage Credit is outside it in both directions**:
a subscription reset is announced even if credits were covering the gap, and a reset of the credits themselves is
never announced (ADR-0113). **Requires a real `.app`** from `/Applications` — under `swift run`
`UNUserNotificationCenter` does not get authorized (same as launch-at-login and auto-update); in a dev build Settings
shows a hint about it.

Steps:

1. Settings → **Notifications** → turn on "Back to work" → confirm the system authorization prompt.
2. Make sure the current time is **inside the allowed hours window** and that today is **not** a suppress day.
3. Run `TOKENPACE_STUB=just-unblocked` (in the installed `.app`, not `swift run`).
4. About one poll after launch a **"Back to work!"** banner must appear.

**The main check for the new signal is `TOKENPACE_STUB=subscription-reset-on-credits`.** First poll:
7d at 100% **with credits enabled** (work does not stop — `canWork` is `true` here, so the old
"blocked" state signal never entered), then 7d at 40%. The banner **must** appear: this is exactly the reset
the old signal did not see at all. That is the proof of the change — on `just-unblocked` (without credits) the old and new
semantics coincide, so it stays a **regression** frame rather than a demonstrative one.

The mirror check (the banner must **not** appear): a reset of the credits themselves while 7d is still at 100% — on
`credits-onset` after the credits come off the ceiling. This used to falsely produce "Back to work!" with the subscription
exhausted.

**Quick check with the "Try" button (#193):** in Settings → **Notifications**, next to the toggle,
there is a **Try** button that sends the banner **immediately**, bypassing the edge detection and the allowed-hours window —
with no `just-unblocked` stub. Steps: turn on "Back to work" (confirm the authorization prompt) →
press **Try** → the banner appears at once. This is the simplest way to check the banner itself (content,
sound). The button is enabled **only when the toggle is on** and the banner is actually deliverable: in a dev build
(`swift run`, `.dev`) and when permission is refused (`.denied`) it is grayed out. Button states:

| Toggle | authState | "Try" button |
| --- | --- | --- |
| OFF | any | grayed out |
| ON | authorized | enabled |
| ON | denied | grayed out |
| — | dev (`swift run`) | grayed out |

The notification will **not** appear (by design) if: the current time is **outside** the hours window; today is a
**suppress** day (Fri-Sat / Sat-Sun — taking Rule A for a wrapping window into account); or notification permission has
**not** been granted (System Settings → Notifications → TokenPace).

**Restart scenario** (persisted state): run `just-unblocked`, **kill the app on the first
(blocked) poll**, run it again — the banner must appear after launch (the "blocked" state
survives a restart via `PersistedConfig.backToWorkWasBlocked`).

**Dynamic window duration:** in Settings, next to the time pickers, an "Nh window" label is shown that
updates live as the pickers change (including a wrap across midnight and `start == end` → "24h window").

### The "Now using Extra usage credits" notification

A system notification that fires on the `not-on-credits → on-credits` edge (the base limit is exhausted
and paid credit starts covering the work — `ExtraUsageOnset.isOnCredits`). The banner body carries the **amount
spent** and the **limit** (if one is set): `"… now spending paid credit: €2.40 of €50.00."`; with an
unlimited limit — `"… €10.77 so far."`. **Requires a real `.app`** from `/Applications` (same as
"Back to work"); it shares a single authorization permission with it. It obeys **the same** allowed-hours
window + suppress days.

Steps:

1. Settings → **Notifications** → turn on "Switching to *Extra usage*" → confirm the system authorization
   prompt (shared with "Back to work").
2. Make sure the current time is **inside the allowed hours window** and that today is **not** a suppress day.
3. Run `TOKENPACE_STUB=credits-onset` (in the installed `.app`, not `swift run`).
4. About one poll after launch a **"Now using Extra usage credits"** banner must appear, with the line
   "€10.77 of €15.00".

**Quick check with the "Try" button:** next to the "Switching to *Extra usage*" toggle there is a **Try** button
that sends the banner **immediately**, bypassing the edge detection and the allowed-hours window (the body takes the
amount/limit from the last snapshot, or a generic line if `spend` is missing). The simplest way to check the banner
itself without a stub is to turn on the toggle, grant permission, and press **Try**.

The notification will **not** appear (by design) if: the current time is outside the window / it is a suppress day;
notification permission has not been granted; or the credits are already at the ceiling (`spend_limit_reached` → that is a
block, the "Back to work" domain, not this one). The "was on credits" state is persisted (`PersistedConfig.extraUsageWasOnCredits`),
so the edge survives a restart — same as in back-to-work.

### Incidents and subscribing to an episode (#279, ADR-0071)

`status.claude.com` incidents in the popup and an opt-in subscription to their recovery. The banners, like the rest of the
notifications, require a **signed `.app` from `/Applications`** — under `swift run` authorization is
impossible. The popup itself (the lines, ⌥, the subscribe row) can be checked on a dev build too.

**The popup — steps:**

1. `TOKENPACE_STUB=incident-two swift run` — open the dropdown. Without ⌥: service lines with an age
   (`2h7m · degraded`), and under them the subscribe row with a **struck-through** bell and secondary text
   "Notify me when it's fixed".
2. Hold **⌥ Option** — the service lines are **replaced** by two incident lines. Check that the description
   wraps across several lines and that `2h7m · identified` sits **on the right of the last line of the description**
   (not on a line of its own, as long as it fits). The subscribe row has not budged.
3. Click the subscribe row — the bell becomes filled, the text reads "Following the incidents", and **the menu
   stays open**: the row toggles in place. Click again — it goes back to
   "Notify me when it's fixed". In the logs — `incident: followed the episode incidents=<n>` /
   `incident: unfollowed the episode`.
4. `TOKENPACE_STUB=incident-green` — the incident is open, the components are green: there must be **nothing**,
   neither with ⌥ nor without. This is the measured 66-minute gap, and "nothing" is the right result here.
5. `TOKENPACE_STUB=incident-active` — a single incident; the same as step 2, but with one line.

> **Two traps when checking this row from a script.**
>
> 1. **AppleScript's `click at {x, y}` does not reach** a view hosted inside an open `NSMenu` (menu
>    tracking spins its own modal loop) — not even a known-working link from the status word.
>    Post a real `CGEvent` (`.leftMouseDown` + `.leftMouseUp`).
> 2. **Several TokenPace instances on screen invalidate the result.** The maintainer's notarized app,
>    another session's build, and the stub all look identical; a click by element name/index (or
>    by coordinates read off "that" screenshot) lands somewhere else, and the conclusion will be about the wrong build.
>    Before checking, make sure exactly one is alive: `pgrep -f TokenPace`. This is exactly why one
>    run falsely recorded "the menu closes after the click".

**The banners — the fastest path (installed `.app` only):**

Settings → Notifications → **Preview** next to "Claude service incidents" — fires **all three**
banners at once: the text update, "Fix deployed" and "Claude is back". It bypasses quiet hours (a human pressed the
button) and needs neither a subscription nor a stub. This is what you check the wording with:
the question is not "does the banner arrive", but whether the two endings read as different statements side by side.

**The banners — the full flow (installed `.app` only):**

1. Make sure the current time is inside "Allowed hours" — otherwise the banner will be dropped (in the logs,
   `incident: suppressed by quiet hours`). There is **no** separate toggle for incidents: the subscription is already
   opt-in by click, and the system will ask for permission on the first subscribe.
2. `TOKENPACE_STUB=incident-recovery` ⏱ — the first two polls are degraded, then the components go green **without
   a new update**. After the debounce (90 s) a "🟢 Claude is back" must arrive.
3. Clicking the banner opens the incident page; the **Unfollow** button cancels the subscription without opening
   anything (in the logs, `incident: unfollowed from a banner action`).

**Will not fire, by design:** no banner until subscribe has been pressed — nothing arrives until the user
asks for it. The subscription state is persisted (`PersistedConfig.episodeSubscription`) and
must survive a restart: incidents run for hours (429 min measured).


### Severity frames, 5h × 7d

> **What changed here.** This section used to be called "Frames for reset-time selection (#103, ADR-0029)" and
> checked which reset the `selectReset` table would pick in each 5h × 7d cell. There is nothing left to
> check: under [ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md) the countdown does not
> exist next to the bars at all, and `selectReset` / `ResetSelection` / `ResetToShow` and the "Show reset
> countdown" option are gone. The frames themselves stay — they cover the **color and the hiding** of the
> bars, and those are live properties. **A check that runs through the whole table: in none of these frames may
> there be a number next to the bars.** If there is one, it is a regression — exactly the one ADR-0091 removed the field from the type for.

Fixed severity, 5h × 7d:

| Stub | 5h | 7d | Note |
|---|---|---|---|
| `5h-orange` | orange | green | by default (`Until it needs attention`, [ADR-0086](../adr/0086-tri-state-calm-bar-hiding.md) → [ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md)) 5h is **orange → not hidden**, 7d stays calm → **both bars, NO number**. The most visible ADR-0091 change for the default user: `.smart` used to show a countdown here, now it is silence. The key case that no mode hides a loud bar |
| `both-orange` | orange | orange | both ahead by ~26 pt; **two bars with no number** — the very frame where you used to have to guess whose "21m" it was |
| `both-red` | red | red | both exhausted → this is already a **barless** state: ⏸ + `4d`, the **later** of the two resets (`BlockingReset.forBlocked`, "the last line of defense"). There are no bars at all ([ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md)) |
| `red-orange` | red | orange | 5h is exhausted but 7d is not yet → there is no block, and the frame keeps its bars: **red 5h + orange 7d, no number** |
| `calm5-orange7` | calm | orange (days away) | **The key frame for the `Until it needs attention` mode** ([ADR-0086](../adr/0086-tri-state-calm-bar-hiding.md)): the calm 5h hides, **the orange 7d is left alone**, and there is **no number** next to it — this is the very "a distant orange 7d loses its number" named as the price in [ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md). Under `Never` — two bars, also with no number |
| `calm-both` | green | green | both calm and **green** (a small margin: 5h ~10 pt < 0.20, 7d ~9 pt < 0.143 — under the fixed behind threshold, so NOT blue). The best stub for going through both "Hide the top 5h bar" modes ([ADR-0086](../adr/0086-tri-state-calm-bar-hiding.md) → [ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md)): `Until it needs attention` (the default) → **a lone centered green 7d**; `Never` → two bars. They **never** both disappear together — that is an invariant, not a coincidence. No reset text in either. It is also the handiest frame for "Colors tell me": under `How it's going` both bars are green, under both muting modes they are white, and under **Pressure** they are white unconditionally and the row itself is not on the page ([ADR-0105](../adr/0105-color-advice-governs-pacing-bars-only.md)) |
| `near-reset` | orange (override) | green | ADR-0044: 5h is only ~2 pt ahead (usage 98 vs elapsed ~96%), but the reset is **12 min** away → the override turns the bar **orange** (without the override it would be yellow/calm). A check of the dynamic threshold + the 20-min override. The countdown does **not** appear here — work is running on the subscription ([ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md)); only the color changes |
| `mid-band-reset` | orange | green | [#284](https://github.com/artem-from-ua/tokenpace/issues/284)/[ADR-0074](../adr/0074-one-reset-format-on-both-surfaces.md): the 5h reset is **4 h 41 min** away — the 90 min – 24 h band, which used to print a wall clock (`20:40`) and now reads `5h`. The only stub for this band. After ADR-0091 the number is visible **only in the popup** (`5h at …`) — it is not in the bar, so checking the format on a single frame no longer works; check the popup line itself |
| `far-behind` | blue | blue | ADR-0061/0081: both base bars are deep behind (5h margin ~0.55, 7d ~0.61 — above the fixed behind threshold ×2 = 0.40/0.286, past the 20-min start override) **and the week itself is calm**, so the weekly gate is open → **blue**. A check of the blue zone + `ColorAdvice`: Settings → Appearance › Menu bar → "Colors tell me" — under **Slow down or speed up** blue stays colored (that is the entire difference between the two muting modes), under **Slow down** it is muted to white, under **How it's going** everything is colored. Under **Pressure** blue is white at any value, and the row itself is not on the page ([ADR-0105](../adr/0105-color-advice-governs-pacing-bars-only.md)) — so the three modes have to be checked on Balance or Progress. The per-model/credits lines (in the popup) always stay green |
| `weekly-gate` | green | green | [ADR-0081](../adr/0081-weekly-capacity-gate-for-blue.md): 5h is deep behind (u = 5%, t = 60% → 55 pp of margin, far past the 0.40 threshold) — but 7d is **exhausted**, so the weekly gate is closed and 5h must be **green**, not blue (and not yellow). In the popup the 5h line says "on pace", not "far behind pace". The pair to `far-behind`: the frames differ only in the state of the week |
| `idle-week-hot` | green (idle pill) | green (idle pill) | **The frame's role has changed** ([ADR-0105](../adr/0105-color-advice-governs-pacing-bars-only.md)). It existed as a contrast to `idle`: there the week is calm → a blue pill, here the week is ahead of pace (70% at t ≈ 29%) but **not** exhausted → green. The blue pill no longer exists anywhere, so **in the menu bar this frame is indistinguishable from `idle`** — both draw a green "ready to start". Do not waste time looking for a difference there: use the frame to check the **converse** — that the state of the week has **no effect** on idle (against `idle` the pill and the word must be identical, and against `idle-blocked` they must differ: gray, "waiting for limit reset"). The weekly gate does its real work on **active** bars — that is `far-behind` against `weekly-gate`, not this pair. In the popup the frame stays useful as a check that a 7d line at 70% with t ≈ 29% does not read as blocked |
| `near-zero` | green (pill) | green (pill) | Near-zero fill on **fresh** windows (5h 0%, 7d 4%, Fable/Mythos ~1–4%, almost zero elapsed) → a colored gap a hair thick. A check of the **min-strip pill geometry**: the colored part must be drawn as a rounded "pill" **inside** the track (both ends round), not a thin sliver poking out past the rounded edge. Both in the menu bar and in the popup; the interval labels and the time marker must line up with the scale compressed by `BS` |
| `edge-extremes` | pill at the very start | red (full width) | Both edges of the scale at once: 5h at 0% and 7d at 100% on **fresh** windows. A check that **the strip's ends are grafted onto the ends of the track**: 7d must fill the track **edge to edge** — no gray tail either to the left or to the right of the fill; 5h shows a pill flush against the left end. Measure in pixels (the fill and the track must end at the same x), because a 2 pt tail is easy to miss by eye. Both in the menu bar and in the popup |

> When adding a new feature with a state of its own — **add a stub and update this table** (as was done for #103, #94, ADR-0044, ADR-0061, ADR-0062).
>
> **Blue is for the base 5h/7d only.** The blue zone (`.farBehind`, ADR-0061) appears when the margin
> `time − usage` exceeds the behind threshold: a base of 1h / 5h, 1d / 7d, multiplied by the fixed
> `farBehindWidthMultiplier` = 2 (2h/2d = 0.40/0.286), more than 20 min of the window has elapsed, **and** the bar is entitled to
> blue (`blueAllowed`). Three cases are not entitled
> ([ADR-0115](../adr/0115-no-blue-on-per-model-windows.md)): the 5-hour bar when the weekly gate is closed
> (the week itself is ahead of pace, ADR-0081), **all per-model / scoped lines unconditionally** (they are slices
> of that same week), credits and idle. The existing "green" stubs (`calm-both`, `red-green`, `calm5-orange7`,
> `near-reset` 7d) have a **small** margin, so they correctly stay green at any interval.
>
> So on any stub the Opus / Sonnet / Fable lines in the popup are **always green on the calm side**
> — blue there would mean a regression.

### New Appearance options for how the bars are presented (#224, ADR-0062)

Check on any pacing stub (e.g. `far-behind`, `both-red`, `calm-both`):
`TOKENPACE_OPEN_SETTINGS=1 TOKENPACE_SETTINGS_SECTION=2 TOKENPACE_STUB=far-behind swift run`.

- **Change appearance preset** (a **radio group**, four rows `Chill` / `Work harder!` /
  `Control freak` / `Custom`, each with an explanation under its name — [ADR-0099](../adr/0099-appearance-nests-its-two-surfaces.md)):
  a click applies the preset; **the whole row** is clickable, not just the circle. `Custom` is not clickable
  while there is no saved setup, but **its description does not change because of that** — the row describes the option, not
  its reachability, so the list must not re-lay-out under the cursor. Check at the same time that the explanation does not
  promise too much: under `Control freak` it must read "Maximum info, but signals take a bit longer to
  spot", and **not** something about "the full picture without ⌥" — ⌥ reveals lines, but it does not change the bar's style.
  **Work harder!** is the default preset (fresh install / Reset), and since #329
  it sets **Balance on both surfaces** (it used to be Mixed) — which is exactly why a fresh install shows Balance.
  Each preset gives both surfaces **one** style, and the three presets cover the three styles exactly once each:
  Chill → Pressure, Work harder! → Balance, Control freak → Progress. Check that clicking a preset
  moves **both** Style rows in sync.
- **The config copy button** (the `doc.on.doc` icon at the **right edge of the "Change
  appearance preset" header row**, #257): a click puts pretty-printed JSON on the clipboard with the 7 Appearance keys + `preset` +
  `appVersion`; for ~1.2 s the glyph turns into a `checkmark`, then turns back (tooltip on hover: "Copy
  appearance settings to clipboard"). **Watch the layout while the glyph is swapped**: nothing
  may twitch — the box is fixed in both dimensions, and implicit animation is disabled. While the button shared a
  row with the segmented control, that control held the height; alone in its row it holds the height itself, and the shorter
  `checkmark` used to squeeze the row.
  The copy button in the Troubleshoot window must give the same feedback — the constants are shared in `CopyFeedback`.
  Paste it into an editor and check **two things at once**
  ([ADR-0104 §3](../adr/0104-appearance-named-for-behaviour-on-three-layers.md)):
  1. **the JSON is nested** — two groups, `"menuBar"` and `"dropdown"`, not flat top-level keys
     (they were flat before #381). The surface is visible without knowing the code;
  2. **the order inside a group matches the order of the controls on the page, top to bottom**
     (`menuBar`: `style` → `colorsTell` → `hideTop5hBar` → `showServiceStatusDot`; `dropdown`:
     `style` → `showPerModelLimits` → `showExtraUsage`), not alphabetical; that is the whole point of the feature, so
     check it against the panel side by side.

  A quick recipe (paste what you copied into `/tmp/appearance.json`):

  ```sh
  # key order as in the dump, with the group names — it must read top to bottom like the panel
  grep -nE '^\s*"' /tmp/appearance.json
  ```

  There is **no** `barStyle` key in the dump (it is legacy-only, read-only for old configs), nor
  any pre-#381 flat name (`calmColorMode`, `calmBarHiding`, `modelLimitsVisibility`,
  `extraUsageVisibility`).

  The `customAppearanceValues` slot is **gone**
  ([ADR-0112](../adr/0112-appearance-presets-preview-apply-commits.md)): the config is not rewritten behind
  the user's back, so there is nothing to stash. The key is swept away at launch — check exactly that as a separate
  step: on an old build do a manual setup (so that it gets written), verify
  `defaults read TokenPace customAppearanceValues`, update the build — the key is gone, and **the seven live keys
  are unchanged** (the value is deliberately not migrated: folding the snapshot into the live keys would mean silently
  changing the widget's appearance on update).

  The `"preset"` field describes the **saved** config: the raw preset (`chill`/`workHarder`/`controlFreak`)
  that it happens to equal, or the literal `"custom"` when it equals none of them (a string, not `null`,
  so that the field does not vanish from the dump). Change any toggle by hand → `"preset" : "custom"`. The button
  saves nothing — the config does not change after a click; **and during a preview it copies the saved
  config, not what is on screen**, so clicking `Chill` does not change the `"preset"` field.
- **Style — TWO separate rows** ([ADR-0080](../adr/0080-per-surface-bar-style.md), #329): the first
  in the **Menu bar** section, the second in **Dropdown**, both `Pressure | Balance | Progress`. The row is called
  **"Style"** (not "Bar style") and on **both** surfaces it is the same control — a picker with
  preview images (three tiles with captions, an accent-colored outline around the selected one, as in
  System Settings → Appearance). The asymmetry that ADR-0093 §5 called temporary was removed in
  [ADR-0100](../adr/0100-dropdown-style-tiles-and-retired-option-segment.md) (#374); the order and
  the captions are shared (`AppearanceBarStyle.segments`), so they cannot drift apart.
  **Style sits in its own `Section`** on both pages — with a separator below it, and the rows underneath
  (colors / visibility) live in their own card.
  The unnamed section at the top is **gone** — its only control (Far behind pace interval) was removed
  along with the option (ADR-0081).
  The styles: "Pressure" — a strip from the left edge with no marker, of length `pressureLength` =
  `max(0, balanceOffset)` = `clamp(r, 0, 1)`, where `r = (u − t)/(1 − t)` (zero on the bar = exactly on plan,
  16% = the start of orange, [ADR-0101](../adr/0101-pressure-is-the-gauge-ahead-half.md));
  "Progress" — a gap + a time marker on the window's scale; "Balance"
  ([ADR-0079](../adr/0079-centred-zero-gauge-scale.md), #326) — a strip from the **center**,
  `clamp(r/k, −1, +1)`: to the right when ahead, to the left when behind, plus a center rule in
  every state (in the menu bar, 1 pt under the track; in the popup, the zero rule drawn **through** the bar at 0.5).
  Check:
  1. **Independence** — switch the menu bar row, and the dropdown **must not budge**, and vice versa
     (click the icon to see the popup). That is the main thing that used to be impossible to do at all;
  2. **a mixed pair → `Custom`** in the preset control (no preset gives the surfaces different styles);
  3. **the hints are not duplicated**: under the menu bar row there are no hints at all — the preview shows the style
     right there ([ADR-0093](../adr/0093-bar-style-picked-by-picture.md)); under the dropdown row — a single line,
     "*Extra usage* bar always draws in *Progress* style." It sits **under the word "Style"**, in the left
     column of the row (a shared `VStack` with the heading), not under the tiles across the full width of the panel — otherwise the
     caveat about one bar ends up far away from the control it concerns;
  4. **three** tiles in the row (not four — "Mixed" was removed): check that the control is not
     clipped in the **narrowest** Settings window. In **each** picker also check: the "Style" label is
     aligned to the **top** edge of the row (not centered); the click registers **on the first try** when
     the Settings window is not active; selecting a tile **does not change the row's dimensions** (the outline is drawn
     inward, the caption has a fixed width — otherwise the row twitches); the tiles are not scaled —
     the widget in them must be the same size as in the real menu bar / dropdown;
  5. **the credits bar does not move** ([ADR-0092](../adr/0092-extra-usage-own-ruler.md)): switch the
     dropdown to Pressure and Balance on a stub with credits (`credits-active` / `credits-month-end`) —
     the token bars turn into markerless strips, while "Extra usage" stays Progress with its marker and
     month-edge captions. That is not a bug: it is exactly what the hint in item 3 is about;
  6. **the tiles are drawn at runtime** ([ADR-0097](../adr/0097-bar-style-preview-rendered-at-runtime.md)),
     so what has to be checked is not that the files exist but that the specimen **matches the live bar**: set
     the same style in the menu bar and compare the anatomy (Pressure — the zero rule + the pill, Balance — the center
     rule, Progress — the time marker). At the same time: cycle `Colors tell me` and `Hide the top 5h bar`
     — the tiles **do not react** (the frame is fixed, [ADR-0097 §1](../adr/0097-bar-style-preview-rendered-at-runtime.md));
     switch the menu bar Style to **Pressure** — the tiles stay the same, even though the `Colors tell
     me` row grays out and jumps to `Slow down`; toggle `Show service status dot` — the tiles **must not**
     get wider or shift (`isPreviewSpecimen` drops the slot reservation, and that is the one width input
     that is read past layout).
  7. **theme: the two surfaces behave DIFFERENTLY, and that is deliberate**
     ([ADR-0097 §2](../adr/0097-bar-style-preview-rendered-at-runtime.md),
     [ADR-0100](../adr/0100-dropdown-style-tiles-and-retired-option-segment.md)). Switch the system
     theme to Light and back:
     - the **menu bar** tiles stay **the same** — a black plate and baking under `.vibrantDark`
       always, because the menu bar is dark in the light theme too;
     - the **dropdown** tiles **must be redrawn**: the plate takes the popup card's color
       (`cardPlateFillOpaque` — 255 in light, 30 in dark), and the track and the green come from the **vibrant**
       palette (`211,211,211` light / `51,51,51` dark). If a tile stayed the old one after the theme switch,
       that is a caching bug, not "how it is supposed to be": the specimen is baked into an `NSImage`, and without a
       dependency on `colorScheme` the view will not rebuild.
     The fastest way to check the colors are honest is to open the **live dropdown preview** next to it (it is on the same
     page) and compare the tile's track with the track in the preview: they must be the same gray.
  8. **the dropdown specimen — two bars, 1:1** (ADR-0100): 5h on top (green, behind pace), 7d below
     (orange, ahead) — the same frame from the `climbing` stub as in the menu bar tiles. The track's thickness
     (6 pt) and the marker (7×14) are **as in the live dropdown**, unscaled; the bars split the tile
     into three equal parts vertically. ⌥ has **no** effect on the tile at all: it never has a ruler or a "0"
     caption, even though the live popup shows them under ⌥.
  Saved values: the pre-#329 `barStyle` key unfolds at launch into two —
  `mixed` → menu bar `pressure` + dropdown `progress` (exactly what it used to draw, so the appearance does not
  change), and every other raw (including the pre-#307 `pacing`/`simple`) — into itself on both surfaces.
  Anyone who did not have the key gets the new **Balance/Balance** default.
- **Colors tell me** (`Slow down | Slow down or speed up | How it's going`) — the former "Calm
  non-critical colors", renamed together with its key and values
  ([ADR-0104](../adr/0104-appearance-named-for-behaviour-on-three-layers.md)). The segments are named after
  **the advice the color carries**, not after the palettes that go dark, and they run **quieter to the left**:
  `Slow down` leaves only orange colored, `Slow down or speed up` adds distant blue to it,
  `How it's going` mutes nothing. Orange/red are **always** colored (an exhausted
  window is not drawn as a bar at all — [ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md)).
  All three segments are always enabled — blue can no longer be turned off, so the state "there is nothing to mute" does not
  exist ([ADR-0081](../adr/0081-weekly-capacity-gate-for-blue.md)).
  **The scope was narrowed to the pacing bars** ([ADR-0105](../adr/0105-color-advice-governs-pacing-bars-only.md)):
  cycle through all three values and check what does **not** react — the service dot (`calm-degraded`:
  as of [ADR-0111](../adr/0111-degraded-dot-is-yellow-on-every-surface.md) `degraded` is yellow unconditionally —
  the tone changed, not who decides it),
  the currency glyph (`credits-active`, `credits-no-limit` — it used to be muted there) and the idle pill in
  the "green or blue" part (`idle`, `idle-week-hot`). The only things that must react are the 5h/7d bars — and the
  pill itself, in the "colored or white" part.
  **The row is disabled under Pressure** — a separate scenario below.
- **Hide the top 5h bar** (`Until it needs attention | Never`) — the former "Hide 5h (top) bar" with its
  `When it's calm` segment ([ADR-0104](../adr/0104-appearance-named-for-behaviour-on-three-layers.md));
  the behavior has not changed ([ADR-0086](../adr/0086-tri-state-calm-bar-hiding.md) →
  [ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md)). The hint under the row is now **a single phrase** —
  "Either way, once a limit is actually reached both bars give way to the countdown to it": the first
  half of the old hint duplicated the segment itself, whereas this one describes what the row does **not** control. Check on
  `both-red` that the promise is true — there are no bars there at all.
- **Show service status dot** — its own **card** (#381), not in the same block as the three rows above:
  those read `PacingModel`, this one reads `ProviderMonitoring`. "on issues" is gone from the caption (the dot only
  appears on a problem anyway); instead there is a hint: "Appears next to the bars when a monitored
  service reports an outage" — and it is the only thing on the page that names the connection to Providers. Check that
  there is a separator between the cards, and that the second card has **no** heading (a single row does not need one).
- **The popup's ruler splits in two, and the toggle is gone**
  ([ADR-0098](../adr/0098-ruler-split-identify-always-explain-on-option.md)): the "Show ticks on
  bars" option was removed together with the `showTicks` key — it is gone from
  [`AppearanceConfigExport`](../../Sources/TokenPaceKit/AppearanceConfigExport.swift) too. Check in the popup, holding
  and releasing ⌥:
  - **always visible — the zero rule**, drawn **through** the bar (it is drawn **under** the track, so only
    its ends are visible) at the zero of every markerless scale: in **Balance** that is the center (0.5,
    [ADR-0079](../adr/0079-centred-zero-gauge-scale.md)), in **Pressure** — the start (0). The color's role is
    the same `centreTick` as in the menu bar rule ([ADR-0096](../adr/0096-zero-tick-on-pressure.md)),
    the height is scaled for the popup's taller bar (12 pt on a 6 pt bar against 10 on a 5 pt one), and the width is 5/7 of the zero
    pill's width. In **Progress** there is no zero rule at all: the position there is carried by the time marker;
  - **only under ⌥** — the scale's ticks: under **Progress**, fractions of the window (`subdivisions − 1`: 4 for 5h, 6 for
    7d). The `0` and month-edge captions were **removed**
    ([ADR-0108](../adr/0108-extra-usage-one-anatomy-and-per-bar-style-caption.md)) — each named what
    its own tick already showed, and added half a line under the bar, meaning ⌥ changed not only the content but also the
    popup's rhythm. Release ⌥ — the ticks disappear, and the zero rule alone remains;
  - the tick **at 20%** ("exactly on plan") in Pressure is **gone** — it was removed;
  - **the menu bar has not changed**: it has its own zero rule
    ([#371](https://github.com/artem-from-ua/cc-timer/pull/371)/[#372](https://github.com/artem-from-ua/cc-timer/pull/372)),
    but neither a 20-percent tick nor a
    `0` caption — ⌥ does not reach that surface.
- **the release notes** link in About to the right of the version — **only in a notarized `.app`** (in `swift run`
  it is not there; that is expected).

### Migrating Appearance keys from the old config (#381)

All seven Appearance keys moved to a **surface prefix** (`menuBar.*` / `dropdown.*`), and the values of
three enums were renamed
([ADR-0104](../adr/0104-appearance-named-for-behaviour-on-three-layers.md)). A single migration,
[`migrateAppearanceKeysIfNeeded()`](../../Sources/TokenPace/PersistedConfig.swift), does both
things at once. This is the **most expensive release bug** there is if it breaks: the user will open Settings and see
something other than their own choices — so the scenario is checked with your eyes in Settings, not with the log alone.

**Bring the stream up FIRST** — the migration happens at launch, before you manage to attach
(the rule from [CLAUDE.md](../../CLAUDE.md)):

```sh
( log stream --predicate 'subsystem == "com.artem-n.tokenpace"' --level debug > /tmp/tp.log ) &
sleep 2
```

Seed the **old** keys in the dev domain (`swift run` writes to `TokenPace`) — pick non-default values,
so that you can see it was your own setup that carried over:

```sh
defaults write TokenPace menuBarStyle            -string progress
defaults write TokenPace dropdownStyle           -string pressure
defaults write TokenPace calmColorMode           -string yellowGreen   # → slowDownOrSpeedUp
defaults write TokenPace calmBarHiding           -string never
defaults write TokenPace showServiceStatusDot    -bool   false
defaults write TokenPace modelLimitsVisibility   -string aboveZero     # → onceUsed
defaults write TokenPace extraUsageVisibility    -string always
TOKENPACE_STUB=screenshot TOKENPACE_OPEN_SETTINGS=1 swift run
```

The expected lines in `/tmp/tp.log` (the `lifecycle` category) — one per move:

```
menu-bar-style: migrated progress → progress
dropdown-style: migrated pressure → pressure
colors-tell: migrated yellowGreen → slowDownOrSpeedUp
hide-top-5h-bar: migrated never → never
show-per-model-limits: migrated aboveZero → onceUsed
show-extra-usage: migrated always → always
service-status-dot: migrated key → menuBar.showServiceStatusDot
```

Then come three checks, and the third is the most important:

```sh
# 1. the new keys are there, with their values
defaults read TokenPace | grep -E 'menuBar\.|dropdown\.'
# 2. NOT ONE of the old ones is left (the migration eats them)
defaults read TokenPace | grep -E 'calmColorMode|calmBarHiding|modelLimitsVisibility|extraUsageVisibility|"?menuBarStyle|"?dropdownStyle|"?showServiceStatusDot'
```

3. **Open Settings → Appearance and look with your eyes.** Menu bar → Style = **Progress**, "Colors tell
   me" = **Slow down or speed up**, "Hide the top 5h bar" = **Never**, "Show service status dot"
   **off**; Dropdown → Style = **Pressure**, "Show per-model and per-service limits" =
   **Once used**, "Show *Extra usage*" = **Always**. The worst possible outcome is a row **with no
   segment highlighted at all**: that means a value the control does not offer landed in the key.

**Idempotence without a marker.** There are no marker keys left at all
([ADR-0104 §4](../adr/0104-appearance-named-for-behaviour-on-three-layers.md)) — the step is gated on
"the new key is not there yet" and eats the old one. Check exactly that:

```sh
# second launch: not a single "migrated" line in the log
TOKENPACE_STUB=screenshot swift run
# and a manual change is not rolled back by the next launch
defaults write TokenPace menuBar.hideTop5hBar -string untilItNeedsAttention
TOKENPACE_STUB=screenshot swift run   # must stay untilItNeedsAttention
```

Check an **unrecognized** value separately: `defaults write TokenPace calmColorMode -string bogus` →
in the log, `colors-tell: dropped unrecognised legacy value bogus`, the new key is **not** created, and
the getter returns the preset's default. Copying an unreadable raw into the new key would be worse — it would fail to
decode anyway.

Do **not** run `defaults delete` on the domain, and do not seed keys into the real `com.artem-n.tokenpace` — that would wipe
the maintainer's actual settings.

### The "Colors tell me" row is disabled under Pressure (#381)

The fastest route is any calm stub with a visible bar:
`TOKENPACE_OPEN_SETTINGS=1 TOKENPACE_SETTINGS_SECTION=2 TOKENPACE_STUB=far-behind swift run`.

Settings → Appearance › **Menu bar**. Click the Style tiles and watch the row underneath them
([ADR-0105 §6](../adr/0105-color-advice-governs-pacing-bars-only.md)):

- **Balance / Progress** → the "Colors tell me" row is in place, in **the same card** as `Style`;
- **Pressure** → the row stays in place but **grays out entirely** (caption and segments) and highlights
  **`Slow down`**; clicks do not register. The card's height does not change;
- back to Balance → the row returns **with the same value**. The saved value is subject to neither migration nor reset —
  check `defaults read TokenPace menuBar.colorsTell` before and after.

**The animation is part of the check, not cosmetics.** The highlight must **travel** to `Slow down` and
back smoothly, together with the muting (`easeInOut`, 0.2 s — in step with the press of the tile itself), rather than
jumping. The gate here is **a picture two rows above**, so the movement leads the eye from the pressed tile to the
row that responded.

The key **negative** check: switch `Hide the top 5h bar` between segments — its own control
**must not** go anywhere. The animation is bound specifically to `menuBarStyle`; if everything moves, that is a regression to a
bare `.animation(_:)`.

And a check that the hiding itself is honest, **on the live bar**: under Pressure the calm side must be **white**
at any saved value. The sharpest frame is `far-behind` with `Slow down or speed up` saved:
before #381 a **blue** pill stayed there while the control was no longer on the page.

```sh
defaults write TokenPace menuBar.colorsTell -string slowDownOrSpeedUp
defaults write TokenPace menuBar.style      -string pressure
TOKENPACE_STUB=far-behind swift run
# on the real menu bar: the pill is WHITE, not blue
```

The same for green (`calm-both`) and yellow (`near-reset` 7d) — under Pressure **not one** calm state stays
colored.

### The yellow `degraded` dot on the LIGHT theme (#410)

`TOKENPACE_STUB=calm-degraded swift run`, System Settings → Appearance → **Light**.

In the menu bar the `degraded` dot is **yellow unconditionally**
([ADR-0111](../adr/0111-degraded-dot-is-yellow-on-every-surface.md)) — the same as in the popup and on the
Legend page. The light theme is still the decisive frame, but the question is **the mirror image** of what
it was under [#381](https://github.com/artem-from-ua/tokenpace/issues/381): back then the check was whether the
neutral disappears into the background, now it is whether the yellow is too loud:

- take a screenshot of **the top strip of the real screen** (not of a window — [the rule about the menu material and
  vibrancy](#testing-menu-bar-widget-colors-swatch-mode--color-picker)). The question to ask of the shot is not "is it visible", but whether the dot reads as an
  **alarm** next to the system icons: it says "take a look", not "here is what broke";
- **three surfaces — the same yellow.** The popup over the bar in **one** shot, and the Legend page
  (`TOKENPACE_OPEN_SETTINGS=1 TOKENPACE_SETTINGS_SECTION=2.0`). Any difference is a regression;
- cycle "Colors tell me" through all three values and switch Style — **none** of them may shift
  the yellow on any of the surfaces ([ADR-0105 §1](../adr/0105-color-advice-governs-pacing-bars-only.md)
  still stands: the dot does not read settings);
- **a white dot must not appear in any state** — the `calmWhite` branch in `statusDotTarget` is
  gone. This is the regression `swift test` will **not** catch: the function is `private` in the app target, and the test
  target links only `TokenPaceKit`, so a live check is the only net here;
- the louder states stay colored on both surfaces: `partialOutage` is orange, `majorOutage` is
  red, `underMaintenance` is blue, `unknown` is gray (the `incident-*` frames);
- repeat on the **dark** theme — there what gets checked is the contrast of the yellow against the dark bar;
- on `color-cycle` catch the frame where a yellow **pacing gap** and a yellow **dot** sit side by side. One
  shade carries two different meanings here ("a bit ahead of pace" and "the service is slowing down") — this was deliberately
  accepted ([ADR-0111](../adr/0111-degraded-dot-is-yellow-on-every-surface.md), "Consequences"): they are
  told apart by shape and position, not by tone. The shot is needed to keep that true.

### Stronger glow on the zero pill in the popup under Pressure (#381)

`TOKENPACE_STUB=far-behind swift run`, Settings → Appearance › **Dropdown** →
Style = **Pressure**, then click the icon and look at the popup.

Under Pressure the calm side is drawn as zero, so the strip degenerates into a **minimum pill** — and
the ambient glow, sized for a full strip (radius 21 pt, alpha 0.35), reads on it as a pale
smudge. For this case the pill gets a **triple** pass — radii **40 / 22 / 10 pt**, alpha
**1.0** each, from wide to tight.

Why three passes rather than one bigger number: `withGlow` sets the **shadow's alpha**, and `strength`
is clamped at 1. Once you hit that, more brightness can only come from the **number** of passes — each one
composites over the previous, so light accumulates where they overlap: bright
near the pill, falling off outward. The radii then set the **shape** of the falloff, not its strength.

- the pill must **glow** enough to read as a lit dot, not as a speck of dirt;
- compare with the same frame under **Balance/Progress**: there the strip has length, and the glow stays
  the ordinary ambient one — they must look **different**;
- **calm colors only.** On `both-orange` under Pressure the orange strip has its own length and must **not**
  get the stronger halo — otherwise the warning would become louder, and that is not what was being fixed
  here;
- check **both themes**: in light, a halo on a light card most easily turns into a dirty smudge.

This applies to **the popup only**. The menu bar has its own glow logic, and it has not changed.

### The look of the popup (#188 — a plate + a translucent background + bars with a glow)

The popup is **always** translucent: the "Claude" section sits on a rounded **plate** (Control-Center style,
with a shadow), around which `NSMenu`'s native menu material shows through. There is no toggle and no opaque mode —
check the unconditional look, **necessarily in both themes on the real menu bar** (a screenshot of the top strip,
not of a window — [the rule about the menu material/vibrancy](#testing-menu-bar-widget-colors-swatch-mode--color-picker)):

- **The plate**: a rounded card under the whole Claude section, inset from the edges (the menu
  material is visible around it) and with a soft shadow; its width = that of the separator between `Settings…`/`Quit` (there is no separator before Settings).
- **The bars**: a solid gray track → a colored strip with **rounded (capsule) ends** + a soft
  ambient **glow** around the color; the **marker** has a thin gray border frame and a stronger glow.
  The strip's free end is rounded; the end at the bar's edge merges with the edge. The idle bar (5h "ready to
  start") has a glow too — the same one as on a pacing strip (the same parameters).
- The services' **status dots** (e.g. the yellow "API degraded") have a glow and are redrawn correctly when
  the light/dark theme changes (this is `GlowDotView`, layer-backed — not a baked image).
- **The dropdown preview in Settings** must render the popup **identically** to the real menu (the same Vibrant
  appearance): gray bars/ticks/dimmed text of the same brightness; the preview renders **the popup**, so it reacts to a change of **Dropdown → Style** (not the menu bar one, #329).
  One bar deliberately does **not** react to Style — the credits one
  ([ADR-0092](../adr/0092-extra-usage-own-ruler.md)); that is not a preview bug.
  The preview also reads **section visibility** (`Show *Extra usage*` / `Show per-model and per-service limits`) from
  the settings: if the credits section is not visible on a credits stub, check this mode first, not the
  rendering. The preview used to keep a default of its own "by verdict" and silently hid calm sections, which meant a
  stub set up precisely to show one of them rendered without it.

## Scenarios without a stub

### Forced delegated refresh (#183)

The goal is to manually trigger a **real** spawn of `claude --safe-mode --model haiku -p '/usage'`
(delegated refresh, ADR-0017) without waiting for the token to expire naturally, in order to check its
behavior — in particular, the absence of a TCC prompt on TokenPace's behalf when the user has a
SessionStart hook that reads a file from a File Provider domain (iCloud/Dropbox/GDrive).

The **`TOKENPACE_FORCE_REFRESH=1`** stub swaps out only the token provider for one that always returns
an *expired* token → on every polling tick the engine takes the `.expired` branch and calls the
**real** `ClaudeCLIRefresher`. Unlike `TOKENPACE_STUB`, the transport and the engine stay real (which
is why it only works **without** `TOKENPACE_STUB`). The anti-flap gate holds back repeat attempts
(cooldown `1→5→30→60 min`), so the first spawn happens right at startup.

The check (bring the streams up **first**, then launch):

```sh
log stream --predicate 'subsystem == "com.artem-n.tokenpace"' --level debug &
log stream --predicate 'process == "tccd"' --info --debug | grep -i tokenpace &
tccutil reset FileProviderDomain com.artem-n.tokenpace   # reset the grant for a clean run
TOKENPACE_FORCE_REFRESH=1 /Applications/TokenPace.app/Contents/MacOS/TokenPace
```

→ the `keychain` logs must contain `delegated refresh: launching cli, path=…` followed by `expiresAt advanced`
(if the real token in the Keychain had genuinely expired and CC refreshed it) or `cli exited 0 but keychain
unchanged` (if the token is still fresh — the spawn happened either way). There must be **no** `tccd` line
`Prompting for access … by TokenPace`. Since the spawn touches the **real** Keychain, run this on your own Mac with
a working Claude Code.

### Pausing polling while the screen is locked (#114)

There is no dedicated stub — this is checked with any stub plus a real screen lock. Launch the
dev build, lock the screen (⌃⌘Q), unlock it, and check the logs:

```sh
log show --last 3m --predicate 'process == "TokenPace" AND eventMessage CONTAINS "screen-lock-pause"'
```

→ there must be `screen locked, pausing polling` and `screen unlocked, polling immediately`, and **no**
`interval`/usage log lines between them. The checkbox is Settings → General → "Pause polling while the screen is
locked".

### Auto-update signals — a single dropdown item (#130, ADR-0036)

The goal is **less noise**: no system notifications at all (`UpdateNotifier` was removed), everything lives in one
menu item that changes only the dot's color and the text. The **`TOKENPACE_UPDATE_STATE=<state>`** stub forces
the item's state without a real release or failure (it writes to memory only, **not** to `UserDefaults`):

| `TOKENPACE_UPDATE_STATE` | Dot | Text |
|---|---|---|
| `failed` | 🔴 | `New version available (update failed)…` |
| `available` | 🔵 | `New version available…` |
| `pending` | 🔵 | `Update pending…` |
| `whatsnew` | 🔵 | `What's new in the version…` |

The check: `TOKENPACE_UPDATE_STATE=whatsnew TOKENPACE_STUB=1 swift run` → open the menu, look at the
item's color and text (above Quit) and at the **dot's alignment** with the text (it must match the service
status dots in the popup). A click in the `failed`/`available`/`pending` states → **Settings → About** (not a
browser, from #210); in the `whatsnew` state → straight to the **GitHub release page** in the browser
(`…/releases/tag/vX.Y.Z`, #415) — the update is already installed, there is nothing to act on in About, only
the notes themselves are wanted. The tag is normalized through `GitHubReleaseClient.releaseTag(_:)`:
`pendingWhatsNewVersion` arrives from the API already carrying the `v`, while the `TokenPaceKit.version`
fallback is a bare `0.111.0`, and without the prefix the URL would 404. Under the `whatsnew` stub (there is no
real `pendingWhatsNewVersion`) what opens is the page of the running version — with the `v`. `whatsnew`
disappears after the click (except under the forced stub — that one holds the state). In the logs:
`update: menu item = <state>` followed by either `update: user opened About from update item` or
`update: user opened release notes from update item (tag=…)`.

### About: failed-update details + clickable versions (#210)

Several elements on the **About** pane were updated:

The pane has two sections:

- **Section 1 (identity):** `Source code` · `Version` (just the number, no link) · *(optionally)* a
  🔵 **New version available: X.Y.Z** row with **release notes** (a link to `…/releases/tag/vX.Y.Z`) on the left
  next to the text and **Download** (the web release) on the right.
- **Section 2 (behavior):** `Check for updates periodically` (+ Check now) · `Install updates
  automatically` · *(optionally)* a 🔴 **Update to version X.Y.Z failed during `<stage>`.** row +
  `Reason: <reason>` (selectable, wraps).

The dots take the same palette roles as the dropdown (`ColorRole.blue` for "an update is available",
`ColorRole.red` for "the install failed"). All versions are shown **without the `v`**; the release-notes URL still points at `vX.Y.Z`.

The **`TOKENPACE_FAKE_FAILURE=<stage>:<reason>`** stub forces the failure row in About (it writes to memory only,
**not** to `UserDefaults`); `<stage>` ∈ `download|unzip|verify|replace`; the tag comes from
`TOKENPACE_FAKE_LATEST` or defaults to `vX.Y.Z`. Combined with `TOKENPACE_SETTINGS_SECTION=0` it opens
About right away. Example:

```sh
TOKENPACE_STUB=1 TOKENPACE_SETTINGS_SECTION=0 \
TOKENPACE_UPDATE_STATE=failed TOKENPACE_FAKE_LATEST=v0.56.0 \
TOKENPACE_FAKE_FAILURE='verify:team id mismatch (expected S5A4U9798Y, got ABCDE12345)' \
swift run
```

→ open Settings (from the menu) → About: check both dots, click Version and "Update available"
(they open the release notes in the browser), and the long reason (not truncated, selectable).

#### The reason an update is deferred + "Update now" (#221)

When an update exists but an environment gate won't let the install through, About explains **why** — with a ⚠
"Update pending because …" row that lists **all** the active reasons (not just the one `decide` stopped at).
Next to the "Install updates automatically" toggle an **Update now** button appears
(only when there is something to install); it bypasses the power and network gates — but **not** free-space.

The **`TOKENPACE_FAKE_DEFERRAL=battery,metered,space`** stub forces the reasons (any subset, in
any order — the row always renders in `allCases` order; it writes to memory only, **not** to
`UserDefaults`). It also shows "Update now" on the dev build so the button is visible under `swift run`;
a click there legitimately refuses (`forced-skip reason=not-app-bundle`) — you can see that in the logs.

```sh
TOKENPACE_STUB=1 TOKENPACE_SETTINGS_SECTION=0 \
TOKENPACE_FAKE_LATEST=v99.0.0 TOKENPACE_FAKE_DEFERRAL=battery,metered \
swift run
```

Check: one / two / three reasons (the text reads as a sentence — "a", "a and b", "a, b and c");
there is no "Download" button, and "release notes" is lowercase and right-aligned; the height of the neighboring rows
does not jump when the reason row appears.

**Live** (a notarized `.app` from `/Applications`): on battery, with an update available, About must
show "Update pending because your Mac is on battery." → clicking "Update now" installs the update without
waiting for the cord. The free-space gate is **not** bypassed this way — with a full disk the install
legitimately refuses (`forced-skip reason=insufficient-space`).

#### Backup gates ([#306](https://github.com/artem-from-ua/tokenpace/issues/306))

When the session backup isn't running, the **Providers → Backup** section explains why with a ⚠ row under
the "Last archived …" status. Both states get the triangle: a row reporting a condition that **blocks a
feature** is a warning, regardless of whether it will clear on its own. The difference between them is in the text
("free up space" versus "will resume when you plug in"), not in the icon. The only rows drawn without a triangle in this
project are hints that **describe** what a control does.

The **`TOKENPACE_FAKE_ARCHIVE_GATE=battery,space`** stub forces any subset (it writes to memory only,
**not** to `UserDefaults`). It forces only the **display** — polling and "Archive now" keep working, so the button
can be checked in the same run (the same contract as `TOKENPACE_FAKE_DEFERRAL`).

The section is shown only when the backup is **enabled and a folder has been chosen** — otherwise there will be no rows at all.

```sh
TOKENPACE_STUB=1 TOKENPACE_SETTINGS_SECTION=7 \
TOKENPACE_FAKE_ARCHIVE_GATE=space \
swift run
```

Check:

- `=space` → the ⚠ row "Backup paused — not enough free space…"; **no measured numbers** in the text
  (only "5 GB" — the threshold constant), because Finder would show different ones (binary vs decimal units,
  purgeable space);
- `=battery` → the ⚠ row "Backup will resume when you plug in.";
- `=battery,space` → **only** the space row is visible: two hints would imply the cord helps, and it doesn't;
- without the stub → no row at all; the height of the neighboring rows does not jump as the hint appears and disappears.

**Live** (no stub needed): unplug the power and wait until the sync becomes due (24 h from
`lastArchiveSync`, or reset the marker) → the logs show `archive: deferred reason=on-battery`, the "Last
archived" date does not move, and "Archive now" meanwhile **does** work (it bypasses the battery gate deliberately).

Checking the space gate live requires a genuinely full volume — practically unreachable, which is exactly why the stub exists; the
arithmetic itself is covered by units (`ArchiveSpacePlanTests`).

**The two-phase scan and the atomic replace** (the same change) — two checks that are invisible in the UI:

- "Archive now" **twice in a row** → the second run copies **0** files (`archive: sync ok — 0 updated`).
  A nonzero number means the replace lost the source's mtime and the archive gets recopied every day;
- temporarily rename `~/.claude/plans` → sync → the archived files under that root still count toward "N files"
  (the "source is missing" branch after the refactor).

Read the logs with a **live stream** — `.notice` does not make it into `log show`:

```sh
log stream --predicate 'subsystem == "com.artem-n.tokenpace"' --level debug
```

### Automatic update installation (#122–#125, ADR-0033; signals in ADR-0036)

The full flow (download→verify→unzip→replace) works **only in a notarized `.app` from
`/Applications`** — under `swift run` the installer returns `.notApplicable` immediately. The
`installUpdatesAutomatically` option is **default-ON** (opt-out, since #130). After a success the menu item shows 🔵
"What's new…" (it survives a restart); after a failure — 🔴 "…(update failed)…", and that tag is not retried.

> ⚠️ The runs below go against the copy in `/Applications` **without a data stub**, so the journal writes to the
> maintainer's real file. Add `TOKENPACE_JOURNAL_FILE=/tmp/tp-test.jsonl` to every command in this
> section — details in ["Usage journal"](#usage-journal-242-adr-0067).

- The **`TOKENPACE_UPDATE_DRYRUN=1`** stub runs download→verify→unzip **without** the replace and the restart (and
  it skips the AC-power/metered gates — this is the forced path). Private repo: the asset is downloaded through `gh` given
  `TOKENPACE_GH_AUTH=1`. Verification: make a notarized build with a **lowered** version (so that the real
  GitHub release is newer), install it into `/Applications` (**back up the current release first!**), and run
  ```sh
  TOKENPACE_GH_AUTH=1 TOKENPACE_UPDATE_DRYRUN=1 /Applications/TokenPace.app/Contents/MacOS/TokenPace
  ```
  with both Updates checkboxes on. The evidence that it went through (the logs are invisible on a direct launch, not
  via launchd): `defaults read com.artem-n.tokenpace lastSeenLatestVersion` = the tag that was found, and the
  saved verified bundle `$TMPDIR/TokenPace-update-<tag>.app` (check `codesign -dv` +
  `spctl --assess`). After the test, **restore the current release** in `/Applications`.
- For a **real** replace + relaunch (no dry run) there is the **`TOKENPACE_UPDATE_TARGET=<path>`** stub — it points
  the installer at a test copy of the `.app` outside `/Applications`, so the working instance is left alone:
  ```sh
  cp -R build/TokenPace.app ~/UpdateTest/TokenPace.app
  TOKENPACE_GH_AUTH=1 TOKENPACE_UPDATE_TARGET=~/UpdateTest/TokenPace.app ~/UpdateTest/TokenPace.app/Contents/MacOS/TokenPace
  ```
  → the copy must be replaced with the newer tag and relaunch; check the copy's version + that the new process
  started + `codesign`/`spctl` on the replaced bundle. Remove `~/UpdateTest` after the test.

### Opening the Settings window automatically at launch

`TOKENPACE_OPEN_SETTINGS=1 swift run` (can be combined with a data stub) — the dev build opens the
**Settings** window right after startup, ~0.6 s in. This removes the need to click the menu bar item through AX, which is
**dangerous when several TokenPace instances are running** (the click can land on the wrong build — see below). Handy
for quickly looking over changes in Settings.

```sh
TOKENPACE_OPEN_SETTINGS=1 TOKENPACE_STUB=screenshot swift run
```

The flag is opt-in (not tied to the dev build), so a plain `swift run` starts quietly. The production `.app`
behaves the same way only when the env var is set explicitly, which never happens on a normal launch.

On top of that, `TOKENPACE_SETTINGS_SECTION=<index>` opens a **specific** Settings pane by index —
so you can screenshot the pane you need without an AX click on a sidebar row.

| Index | Pane |
|---|---|
| 0 | About |
| 1 | General |
| **2** | **Appearance** |
| **2.0** | **Appearance › Legend** (child page) |
| **2.1** | **Appearance › Menu bar** (child page) |
| **2.2** | **Appearance › Dropdown** (child page) |
| 3 | Notifications |
| ~~4~~ | ~~Extra features~~ — pane removed ([#341](https://github.com/artem-from-ua/tokenpace/issues/341)); the index is **retired and not reused** |
| ~~5~~ | ~~Menu bar~~ — no longer a section but a child of `Appearance`: addressed as `2.1` |
| ~~6~~ | ~~Dropdown~~ — same thing, `2.2` |
| **7** | **Providers** |
| **7.0** | **Providers › Claude** (child page) |
| 100–108 | scroll filler (`TOKENPACE_SIDEBAR_FILLER`, see below) |

**The indexes are stable identifiers, not the row order** (#333). The sidebar order is set by
`SettingsSection.groups`, and it is different: About / **General · Providers** / **Appearance ·
Notifications**. The split is exactly this way so that reordering rows does not silently redirect every
documented recipe to a different pane; `2` stayed with `Appearance` through all the renames —
it is the same pane. `4`, `5` and `6` stay as **holes**: old recipes still carry them, and pointing
them at a different pane would mean a recipe that lies instead of failing (`5`/`6` are now addressed in the dotted
form, because the pages themselves didn't go anywhere — they moved one level down).

**The dotted syntax means child pages** ([#341](https://github.com/artem-from-ua/tokenpace/issues/341),
[ADR-0084](../adr/0084-settings-drill-in-child-pages.md)): `<section>.<child index>`, where the index
counts the pages **in display order**, not by raw value. An unknown section or child is now **written
to the log** (`settings hook: unknown …`) instead of being ignored silently.

> ⚠️ **A child is addressed in the dotted form, never by its raw value.** `SettingsChildPage` has raw values
> of its own (50+), and they are **not** the hook's indexes: `=53` parses as *section* 53, which does not exist. The hook writes
> `settings hook: unknown section 53 — ignored` and opens the window wherever it was left last time —
> that is, a recipe that does nothing will look like it works if you already happened to be on the page you wanted.
> That is exactly how Legend was "verified" for a while ([#261](https://github.com/artem-from-ua/tokenpace/issues/261),
> [ADR-0110](../adr/0110-legend-is-a-static-page-rendered-by-the-live-code.md) §4). **Check the log**,
> not just what is on screen: nothing in `settings hook` = the value was accepted.
>
> Display order ≠ raw order. The `Legend` row is drawn **above** the presets, and both surfaces sit
> below it, so `2.0` is Legend even though its raw value (53) is the largest of the three. The hook reads
> `SettingsChildPage.reachablePages(of:)`, which sorts precisely by the row's position on the page; the neighboring
> `pages(of:)` returns **only the surfaces** and feeds the page's own unnamed section.

(Monitored services now lives in **Providers › Claude** together with the Claude Usage API toggle, #341.
Monitored services, Sessions and Backup stayed on the parent **Providers** — they belong to no single
provider. The "Usage history" section is in General, #317.)

```sh
TOKENPACE_OPEN_SETTINGS=1 TOKENPACE_SETTINGS_SECTION=3 swift run     # opens straight on Notifications
TOKENPACE_OPEN_SETTINGS=1 TOKENPACE_SETTINGS_SECTION=2.0 swift run   # straight to Appearance › Legend
TOKENPACE_OPEN_SETTINGS=1 TOKENPACE_SETTINGS_SECTION=2.1 swift run   # straight to Appearance › Menu bar
TOKENPACE_OPEN_SETTINGS=1 TOKENPACE_SETTINGS_SECTION=7.0 swift run   # straight to Providers › Claude
```

The hook **lands** on a pane, it does not "navigate": a window opened this way has **both chevrons ‹ › dimmed**, as it
should be in a freshly opened window. If ‹ is active right after launch, that's a regression.

### Detail-pane scrolling, toolbar rule, minimum height (#346)

The mechanics are described in [ADR-0088](../adr/0088-settings-hosting-safe-area-and-manual-separator.md);
the failure modes differ at different heights, so every item is checked **both at the minimum height
(560) and stretched out**. The minimum was raised from 470 when `Legend` appeared
([#261](https://github.com/artem-from-ua/tokenpace/issues/261)): at 470 its anatomical bars with
callouts did not fit without scrolling, and the page opened already scrolled.

```sh
TOKENPACE_STUB=1 TOKENPACE_OPEN_SETTINGS=1 TOKENPACE_SETTINGS_SECTION=2.1 swift run  # Menu bar — the longest
TOKENPACE_STUB=1 TOKENPACE_OPEN_SETTINGS=1 TOKENPACE_SETTINGS_SECTION=2.0 swift run  # Legend — the tallest
TOKENPACE_STUB=1 TOKENPACE_OPEN_SETTINGS=1 TOKENPACE_SETTINGS_SECTION=3 swift run    # Notifications
TOKENPACE_STUB=1 TOKENPACE_OPEN_SETTINGS=1 TOKENPACE_SETTINGS_SECTION=7.0 swift run  # drill-in Providers › Claude
```

1. **Scrolling**: a long pane scrolls all the way to its last row ("Suppress on weekends" on
   Notifications); rubber-band does not snap it back.
2. **The scroll bar** (easiest with System Settings → Appearance → "Show scroll bars: Always"): it runs from
   the bottom of the toolbar to the edge of the window, not clipped at either end.
3. **The toolbar rule**: absent at rest; appears the moment content slides under the toolbar; disappears when
   you scroll back up; does not "stick" after switching panes or after a drill-in (the rule is driven by our controller,
   not by `.automatic` — ADR-0087).
4. **The first card** — 52 pt from the top of the window, same as System Settings next to it.
5. **The minimum height** — shrinking all the way stops at exactly the same place as System Settings (put both
   windows side by side, drag both to the stop).
6. **Resizing up from the minimum** — smooth, with no size jump.
7. **Short panes** (About, General) — no phantom scrolling.

### Appearance and its two surfaces: what to check (#333, nested back under a single pane)

The three former neighboring sidebar rows (`UI presets` · `Menu bar` · `Dropdown`) are a single
**Appearance** pane again, and the two surfaces are its **child pages** (drill-in, like
`Providers › Claude`). What breaks most easily:

1. **Sidebar** — **five** rows, not seven: About / General · Providers / **Appearance ·
   Notifications**. `Appearance` and `Notifications` sit **in one group, with no separator between
   them**; the separator remains only above, over the `General · Providers` pair. Capsule tints:
   `Appearance` — green, `Notifications` — red, while `General` and `Providers` share **one**
   gray ([ADR-0094](../adr/0094-provider-row-brand-badge.md)) — if the `Providers` chip is purple,
   you are looking at an old build.
2. **Three navigation rows** — on `Appearance`. **`Legend` sits in its own section ABOVE the presets**
   (blue `map.fill` chip, the same blue as in `About` — both pages only inform), and below the
   presets section come `Menu bar` and `Dropdown`, each
   with a chip (black / white with a hairline — the same ones the sidebar used to have) and a **chevron**.
   The row's subtitle is that surface's current Style **with a label**: `Style: Pressure`, not a bare
   `Pressure`; switch the style inside and come back with ‹ — the caption must change. **The whole row**
   is clickable, not just the chevron.
2a. **Legend** ([#261](https://github.com/artem-from-ua/tokenpace/issues/261),
   [ADR-0110](../adr/0110-legend-is-a-static-page-rendered-by-the-live-code.md)) — a page that
   **configures nothing**; it has neither a style subtitle nor a surface chip, because it configures no
   surface at all. What to check on the page itself:
   - **Theme.** Switch the system theme with the page open: the dropdown bars and glyphs must
     **redraw**, not freeze. This is the page's main risk — the samples are baked into an
     `NSImage`, and colors resolve at bake time. The menu-bar samples deliberately stay
     dark under a light theme: the menu bar is dark under both.
   - **The page is static.** Switch `Bar style` or `Calm colors` on the neighboring pages and come back:
     Legend must look **exactly the same**. It explains the vocabulary, not your configuration.
   - **Ticks are visible without ⌥** — and this is the only such place in the app
     ([ADR-0098](../adr/0098-ruler-split-identify-always-explain-on-option.md)). On the anatomical
     Progress bar the ticks must be **the same height and width** as in the live dropdown (compare
     with two windows side by side); clipped in height is a `rulerDepth` regression.
   - **The callout lines touch what they point at.** The line from `now-marker` reaches the marker, the one
     from `hour/day ticks` reaches the last tick, the one from `tokens/credits spent` reaches the bar. Both
     bottom captions sit **on one line**, and the text↔bar spacing is the same above and below.
   - **Captions are centered on their callout lines**, not pushed to the edges of the bar: the middle of the
     text sits exactly over the line. This breaks most easily when a **caption is renamed** — the old version
     stretched the text across the full width and hugged the edge, so hitting the target depended on word length.
     Renamed a caption? Check this first.
3. **Navigation** — a drill-in puts the page title in the toolbar (`Menu bar`), ‹ returns to
   `Appearance` rather than "through" it; switching a sidebar row from an open child lands on the
   root of the new section.
3a. **Clicking an already-highlighted sidebar row exits the child** (#374,
   [ADR-0100](../adr/0100-dropdown-style-tiles-and-retired-option-segment.md)): go into
   `Appearance › Dropdown` and click `Appearance` — the parent page must open. Previously this did
   **nothing**: the sidebar highlighted the parent while the column showed the child.
   **It breaks easily, so check it by actually clicking, not by reasoning:** SwiftUI's `List` does not report
   a click that does not change the selection, so this is done with an AppKit event monitor
   (`SettingsWindowController.watchSidebarClicks(in:)`). While you are at it, check that **ordinary** selection
   is not broken: clicking another section switches as before, and clicking the empty area of the column below
   the rows also exits the child (the monitor watches the whole column).
4. **Presets reach both surfaces** — apply `Chill` on *Appearance*, then go into both
   children and check that **both** "Style" values changed, not one.
5. **Custom** — change anything by hand, apply a preset, then hit `Custom`: your setup must come back.
   On a clean install (nothing saved) the segment is unclickable and explains itself with a popup.
   **A selected `Custom` must not dim** (#374): it becomes unclickable exactly when it is active
   (there is nothing left to return to), and a gray title means "clicking will do nothing" — on an
   already-selected option that message is false. Compare with the neighboring options: the `Custom` title
   must be as bright as `Chill`/`Work harder` when it is selected.
6. **Copy config** — the button on *Appearance* collects values from **all three** pages, including
   both surface children. `Legend` is not part of the config: it sets nothing.
7. **Awaiting-input** — turn off "Detect sessions waiting for input" in *Providers → Sessions*, go
   to *Appearance › Menu bar*: the "Show waiting sessions" there must be **disabled**, and the hint
   must read "…in Providers › Sessions first". The names differ deliberately (#341): on Providers you turn on
   **detection**, on Menu bar only the **display** of the icon.
   The global switch controls the hand in the dropdown, this one controls it in the menu bar.
8. **The preview follows the pane** — see the "Dropdown live preview" section below: it is present on
   `Appearance` and both of its children and **disappears** on About / General / Providers / Notifications.
9. **`Menu bar` is TWO cards** (#381,
   [ADR-0104](../adr/0104-appearance-named-for-behaviour-on-three-layers.md)): the first holds `Style`,
   `Colors tell me` and `Hide the top 5h bar` — all about the **pacing bars**; the second holds
   `Show service status dot` alone — about **external incidents**, hence a separate card and **no header**
   (a single row does not need one, same as the polling-pause section on `Providers`). Check that the
   separator between the cards is there, and that `Colors tell me` sits in the **first** one — it gets disabled
   under Pressure together with the picture it drives, so in the second card its disappearance would read
   as a glitch.

**The source of truth for composition and indices** is `enum SettingsSection: Int` (the raw values) plus
`SettingsSection.groups` (order and grouping); when you change the composition, update them and the table
above together. The detail panes are SwiftUI `Form.formStyle(.grouped)`
([ADR-0042](../adr/0042-settings-swiftui-form.md)), so grouped-inset card parity is proven with light+dark
screenshots the same way it was for the AppKit version.

### Appearance preset preview ([ADR-0112](../adr/0112-appearance-presets-preview-apply-commits.md))

Clicking a preset row **saves nothing** — it merely draws the preset on the live surfaces. Only the
`Apply` button writes. The fourth row, `My setup`, is the saved config itself, not a snapshot; it is always
clickable and returns you out of the preview.

```sh
TOKENPACE_STUB=far-behind TOKENPACE_OPEN_SETTINGS=1 TOKENPACE_SETTINGS_SECTION=2 swift run
```

The most important thing here is **not what you see, but what did not get written**. So check every preview
step against `defaults read TokenPace` (the `swift run` domain; the installed copy writes to
`com.artem-n.tokenpace`).

1. **The preview draws but does not write.** Click `Chill` — the widget in the bar and the dropdown change
   immediately, while the seven keys in `defaults read` stay as they were. In the log — `appearance preview: chill`.
2. **Switching without modality.** `Chill` → `Control freak` → `My setup` → `Chill`, in any
   order, as many times as you like. There is no `Cancel`, no state you have to get out of.
3. **Closing cancels.** Without pressing `Apply`, close the window (⌘W): the look returns to the saved one,
   and the log shows `appearance preview: ended`. Open Settings again — `My setup` is active.
4. **`Apply` commits.** Preview `Control freak` → `Apply`: the log shows `appearance preset applied:
   controlFreak`, and `defaults read` shows seven written keys. The selection moves to **`My setup`** (that
   *is* the saved config), and the note becomes `· same as Control freak preset`. Close the window — the look
   does **not** roll back.
5. **The note is gray, the preset name is italic.** `· same as *Chill* preset` in secondary ink, so it
   reads as an observation rather than as part of the row's title.
6. **A manual config clears the note.** *Menu bar* → change `Hide the top 5h bar` → come back: `My setup` is
   active **without** the suffix, and `Apply` on the presets is inactive.
7. **⚠️ A child page UNDER a preview — the easiest one to miss.** Preview `Chill`, go into *Menu bar*, change
   `Show service status dot`. The remaining **six** options must instantly return to the saved config, not
   stay Chill's. Go back to *Appearance*: `My setup` is active. Close the window — the look
   does not change.
8. **Quit under a preview.** Preview `Chill` → Quit from the widget's menu → launch again: the config is the
   one you had before the preview. Nothing was written, so there is nothing to restore.
9. **The dropdown preview window.** Keep it open at the side and flip the radio buttons: the bar in it must
   change **together** with the live surfaces — it reads the same getters.
10. **The rows do not jump.** Switch through all four quickly: the neighboring rows must not move vertically
    when `Apply` appears and disappears (the row height always reserves space for the button).
11. **`Apply` is inactive when there is nothing to apply.** Land on `My setup · same as Chill preset`,
    click `Chill`: the button is there but gray, with the tooltip `Already matches your setup`.

**What `swift test` will NOT verify here** — almost everything: the overlay and the setters live in the app
target, which no test target links. Only `AppearanceChoice` is under test (which row is active, what the note
says, whether `Apply` has work to do) — `Tests/TokenPaceKitTests/AppearanceChoiceTests.swift`.

### Providers and the widget's two states ([#341](https://github.com/artem-from-ua/tokenpace/issues/341))

This part **has no stub and cannot have one**: what is being checked is polling behavior itself, and a stub
replaces it. You have to flip the switches by hand in Settings, on live data.

1. **Drill-in** — `Providers` → the `Claude` row (terracotta cloud badge on the left, a `›` arrow on the right,
   the subtitle reading the state) → the `Claude` page. The toolbar title is exactly **"Claude"**, not
   "Providers › Claude". ‹ returns to `Providers` rather than jumping to the previous section.
2. **The row badge** ([ADR-0094](../adr/0094-provider-row-brand-badge.md)) — 26 pt, as tall as both
   lines of text (not a bullet before the title), gradient **lighter at the top left**. The numbers are `#D97757`
   at the bottom right and `#E7AA96` at the top left, and **the light end was derived by formula, not measured**:
   if you are checking it, use only Digital Color Meter in sRGB mode — a screenshot is no proof here. Defocus the
   window: the badge must **dim along** with the rest of the row, not stay at full strength.
3. **Landing on a child** — `TOKENPACE_SETTINGS_SECTION=7.0`: both chevrons are **dimmed**. An active
   ‹ right after launch is a regression.
4. **Claude API interlock** — turn on the Usage API: the `Claude API` row goes on, disabled, with the note
   "required by the above". Turn everything off: the row goes dark and the note reads "nothing to monitor".
5. **`zzz` mode** — Usage API off, at least one service on: **`zzz`** in the bar, with no bars and no time; in the
   popup, "Claude" plus a green "All services" plate with the age of the **status poll**. The age is neither
   "0 s ago" nor empty.
6. **The same mode past the glyph threshold** — `max(15 min, 3 × pollInterval)`, i.e. 15 min during an
   active session and 45 min without one ([ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md)).
   `zzz` does **not** turn into a struck-through antenna or into ⚠️. If it did, the state slid into the
   `.error` branch — and that is the regression this case exists to catch.
7. **Nothing enabled** — **⚠️** in the bar; in the popup, a **non-red** "Monitoring is off" block plus a
   clickable row leading into Settings. A red banner here is a regression.
8. **Switching is immediate** — after each toggle the bar must change **within seconds**, not
   minutes: `.manualRefresh` wakes the loop right away.

The subtitle under `Claude` counts **the services that actually resolve** (`Claude API` included, `Cowork` —
only in cowork mode), so the number must match the row count in the popup under ⌥.

### The dropdown preview beside Settings ([ADR-0083](../adr/0083-live-dropdown-preview-in-settings.md))

The "Dropdown live preview" window is stuck to the side of Settings and shows **the same** `PopupLayout` as the
live dropdown.

```sh
TOKENPACE_OPEN_SETTINGS=1 TOKENPACE_SETTINGS_SECTION=2.2 TOKENPACE_STUB=screenshot swift run
```

**The feature has no states of its own — no new stub is needed.** Everything it shows comes from the
common render path, so it is covered by the existing scenarios.

What breaks most easily:

1. **Visible only on Appearance and its children.** The preview is bound to the **pane**, not merely to the
   window being open (`SettingsSection.showsDropdownPreview`): it is present on `Appearance`,
   `Appearance › Legend`, `Appearance › Menu bar` and `Appearance › Dropdown`, and **disappears** on
   About / General / Providers / Notifications. It is present on `Legend` too — deliberately
   ([ADR-0110](../adr/0110-legend-is-a-static-page-rendered-by-the-live-code.md) §4): the legend is read
   next to the live dropdown so you can compare the ticks and colors with the real ones. Click back and forth a few times — it must return to the same place every time,
   not appear offset. While you are at it: open the window **on a pane with no preview** (`…SECTION=0`) —
   Settings must be **centered on its own**, with no leftward shift of half a preview width
   (`occupiedWidth` = 0 when the preview is hidden).
2. **⌥ Option.** Hold it over Settings → the model/service rows and the data age unfold in the preview and the
   window **grows** (without a refit the block is clipped). Arrive with ⌥ already held — it must be unfolded
   right away (seeding). The window's subtitle advertises exactly this and reads
   **"try alt view with the ⌥ Option key"** (#374; before that — "Alternative view with the ⌥ Option key").
3. **The real menu regression.** Click the icon in the menu bar, hold ⌥ → "Troubleshoot…" as always. If it
   is gone, the monitor swallowed `.flagsChanged` for the whole process (it must `return event`).
4. **The truth.** Open the real dropdown next to it and compare row by row — the contents must match.
5. **Focus.** Click into another app: the material fades to an opaque tone and the title dims.
   Bring focus back — transparency and blur return. **Transparency without blur** means somebody
   took the layer away from `NSVisualEffectView` (see ADR-0083).
6. **Position.** Push Settings to the right edge → the preview flips to the left. Minimize to the Dock →
   it disappears; restore → it comes back.
7. **The sidebar divider.** It does not drag **and** the cursor over it stays an arrow. These are two separate
   mechanisms and they break independently (ADR-0083).
8. **Theme.** Flip light↔dark with the preview open: neutrals re-resolve and the colors **snap** rather
   than blend. Measure colors with Digital Color Meter in sRGB, not off a screenshot.

The chrome types (`PreviewChrome`/`ThemedFillView`/`TitlePlaqueView`) from ADR-0107 have a single consumer —
this preview; the second window they once shared no longer exists.

### `TOKENPACE_SIDEBAR_FILLER` — make the sidebar long enough to scroll

The sidebar is too short to scroll at any supported window height, so the divider that should
appear under the titlebar **when the list slides beneath it** cannot be reproduced any other way — nor can the
bug where it shows up during an ordinary window drag (#312 follow-up).

```sh
TOKENPACE_SIDEBAR_FILLER=1 TOKENPACE_OPEN_SETTINGS=1 swift run   # +9 dummy rows after Notifications
```

The rows are called `ITEM_1`…`ITEM_9`, have no pane of their own (the detail shows just the title) and take
raw values starting at 100 — deliberately above every real page, so the
`TOKENPACE_SETTINGS_SECTION` indices stay put. When you add pages, preserve that headroom.

### Settings window geometry (ADR-0069)

The window is **resizable in height** (≥480, default 732), the width is pinned at 857, and the frame persists
across launches. Check it on **Appearance** — the tallest pane:

```sh
TOKENPACE_OPEN_SETTINGS=1 TOKENPACE_SETTINGS_SECTION=2 swift run
```

The state lives in `UserDefaults`. Careful: the `swift run` binary **has no bundle identifier**, so it writes to
the `TokenPace` domain, not `com.artem-n.tokenpace`:

```sh
defaults read   TokenPace settingsWindowFrame     # [x, y, width, height]; the width is always 857
defaults delete TokenPace settingsWindowFrame     # reset — the next launch opens centered
defaults read   com.artem-n.tokenpace settingsWindowFrame   # same thing for the installed .app
```

What to check:

1. **Drag the bottom/top edge** — the height changes, the width stays 857.
2. **Squeeze it all the way down** — the `Form` scrolls inside (verified down to 300 pt: both the detail and the
   sidebar scroll), and the content is not clipped.
3. **The green button** — stretches to the full height of the working area, the width and x do not change; a second
   click restores the previous size. Full-screen does not engage.
4. **Reopening the window** within a session — the size is not reset.
5. **Restart** — the size and position are restored.
6. **A display configuration change** — save on an external monitor, disconnect it, launch:
   the window must open **centered on the main screen** at the default height, not off-screen. Symmetrically:
   a frame saved on a tall monitor, opened on a short one — the height is clamped and the window is fully visible.
7. Both themes (light + dark), as always.

> **Known limitation:** on the left/right edges the cursor still shows ↔, even though horizontal resizing does
> not happen (`windowWillResize` rejects it). AppKit offers no supported way to remove that cursor for a single
> axis — do not treat it as a regression.

### Auto-opening the Troubleshoot window at launch

`TOKENPACE_OPEN_TROUBLESHOOT=1 swift run` likewise opens the **Troubleshoot** window right after
startup (~0.6 s). In the normal flow it hides behind a ⌥-revealed menu item, which is even more awkward
to click via AX (the modifier has to be held while the menu is being tracked), so the stub is needed for
screenshots. It combines with a data stub:

```sh
TOKENPACE_OPEN_TROUBLESHOOT=1 TOKENPACE_STUB=screenshot swift run
```

**The copy button (`doc.on.doc`, at the right of the "Usage API — last response" header)** — since #257 it gives
the same feedback as the copy-config button in Settings → Appearance: for ~1.2 s the glyph becomes a
`checkmark`, then returns (the shared constants are in `CopyFeedback`). Check **both** buttons in
one run: the duration and the glyphs must look identical. Separately, look at whether **holding**
the button down makes the image "blink" — the button type was changed to `.momentaryPushIn` precisely because
`.momentaryChange` restored the glyph on mouse-up and wiped out the checkmark.

### Development tools — the stub selector and the payload log (#187, #279)

A dev-only window with two tools that have nothing to do with each other beyond a shared gate.
Before [ADR-0107](../adr/0106-remove-dev-color-tuner-and-dissolve-colorstore.md) there was also a color tuner
here with its own preview window — both were removed; color picking is now done the way the
next section describes (swatch + color picker).

**1. `Preview data source (stub)`** — a dropdown that switches the `TOKENPACE_STUB` scenario **without
a restart** (#187, [ADR-0047](../adr/0047-live-stub-selector.md)). Below it, a description of the current scenario.
`Real network (no stub)` returns the app to the live API. This is the fastest way to walk through the states:
you switch, and the menu bar and popup redraw immediately.

**2. `Log status payloads (JSONL)`** — a checkbox for the raw log of `status.claude.com` responses (#279,
[ADR-0071](../adr/0071-incident-subscriptions.md) §10), and next to it **`Reveal in Finder`**. It writes only
**materially changed** payloads and only on the **live network** (on a stub there is nothing to write). The flag
is read on every poll, so it takes effect immediately, with no restart. The button opens the current month's file
(`status-payloads[-dev]-YYYY-MM.jsonl` in the journal folder), or the folder itself if the file does not exist yet;
"no file" right after you enable it is a normal state. The full format description is in
[incident-subscriptions.md](../design/incident-subscriptions.md) §11.

The gate is the **`defaults` key `devToolsEnabled`** (`defaults write com.artem-n.tokenpace devToolsEnabled
-bool true`, [ADR-0053](../adr/0053-devtools-flag-via-defaults.md)) **plus** a held ⌥ Option on the
"Development tools…" menu item. It does not depend on the build type: the gate is a `UserDefaults` key, not
`#if DEBUG`.

> **Only on a built `.app`.** The key is read from the bundle id's domain, so under `swift run` (a binary with no
> bundle id → a different domain) `defaults write com.artem-n.tokenpace …` has no effect on it (ADR-0053).
> You have to build **your own** bundle — `scripts/build-app.sh` puts it in `./build/TokenPace.app` with the
> same bundle id. Launching the installed copy from `/Applications` to check **your** changes is not
> allowed: that is a different build, and you will see something other than what you made.

The launch for verification (auto-open bypasses the awkward ⌥-click on the menu bar, same as for Troubleshoot):

```sh
scripts/build-app.sh
TOKENPACE_OPEN_DEVTOOLS=1 TOKENPACE_STUB=both-orange ./build/TokenPace.app/Contents/MacOS/TokenPace
```

→ the window (always-on-top) opens by itself. What to check: the dropdown switches the scenario and the widget
in the bar changes **without a restart**; the log checkbox toggles; `Reveal in Finder` opens the file or the folder.
Without `devToolsEnabled` the menu item does not appear even under ⌥, and `TOKENPACE_OPEN_DEVTOOLS`
is ignored.


### Testing menu-bar widget colors (swatch mode + color picker)

Picking and checking menu-bar colors (so that the glyph/bars/text match the native icons — moon, clock,
Wi-Fi, battery) has a **strict method**, earned the painful way (the semantic-colors refactor session):

1. **No screenshot is a source of color — not ours, not one sent to us, not one from any other source.**
   macOS applies color management: the display profile is embedded in the file, and on wide-gamut/XDR screens
   a pixel in a PNG **does not equal** what is on screen. Two elements that are noticeably different in the flesh
   can look identical in a screenshot — and vice versa. Do not calibrate or compare colors from pixel measurements
   taken off a screenshot (`NSBitmapImageRep.colorAt(...)` and friends): that cost a session hours of false calibration
   ([#202](https://github.com/artem-from-ua/tokenpace/issues/202)). The source of truth is **Digital Color
   Meter** (the native color picker) in **sRGB** mode (View → Display in sRGB), or values from there dictated by the
   maintainer; compare TARGET and RENDER **in the same space**. A screenshot is fine for **seeing** the
   problem (layout, "lighter/darker", what is where), but not for exact RGB.
2. **Always on the REAL bar, a screenshot of the TOP STRIP of the full screen — not of a window.** A window
   screenshot (e.g. the dropdown preview in Settings) renders the widget **without menu-bar vibrancy and without the
   wallpaper** → it lies. Transparency effects (the color "breathing" with the background) are visible only on the real
   bar next to the system icons (moon/Wi-Fi/battery): what looks "fine" in a window can be pale or invisible on the
   live bar. The right way is `screencapture -x` of the whole screen + a crop of the top **~46 px**; compare our element
   and its system neighbor **on the same shot of the real bar**.
3. **Vibrant surfaces draw their own material, not `windowBackgroundColor`.** A real `NSMenu` popup
   sits on the **menu material** (dark ≈ `0x212121`), so a solid `windowBackgroundColor` fill in an
   ordinary window reads noticeably lighter — that is exactly what the false calibration in
   [#202](https://github.com/artem-from-ua/tokenpace/issues/202) was built on.
4. **Swatch mode `TOKENPACE_SWATCHES=1`.** Instead of the widget it draws **large color squares**
   (`StatusItemView.render`) — color/alpha candidates side by side. That makes them easy to sample and compare
   against a neighboring system icon on **the same** real bar. Launch:
   `TOKENPACE_SWATCHES=1 TOKENPACE_STUB=screenshot swift run` (or on the `.app`). Edit the swatch set in
   `render` to suit the specific check.
5. **Check against different solid wallpapers** — black / dark blue / light gray / white / colored
   (teal). Menu-bar lightness is decided **per display from the wallpaper's brightness**, NOT from the system theme:
   on a light wallpaper the bar is light even in Dark mode. So a light bar and a dark bar are separate cases.
   To set/restore the wallpaper: `osascript -e 'tell application "System Events" to set picture of every
   desktop to "…"'` (leave the system in its original state after the test).
6. **The bar's real mode is `NSStatusBarButton.effectiveAppearance`** (not `NSApp.effectiveAppearance` and
   not `view.effectiveAppearance` — those echo the system theme, not the bar). `bestMatch(from:[.aqua,.darkAqua])`
   on it flips correctly with the real bar (ADR-0059 / ticket §2.4).
7. **Target values (measured on this display, a reference point):** the moon — light bar `~0xC1C1C1`, dark
   `~0x4C5A6D` (it breathes with the wallpaper's tint); system text (the clock) — light `~0x24`, dark `~0xE7`.

### The "sessions awaiting input" indicator (#233, ADR-0066)

A count of Claude Code sessions awaiting the user's input, in the menu bar and in the popup. The feature is
**opt-in** (Settings → Providers → Sessions → "Detect sessions waiting for input", default OFF); showing it in
the menu bar — Settings → Menu bar.

Under the toggle there is **one** neutral description line ("Shows how many Claude Code sessions are waiting for
your reply in the dropdown."). The permanent ⚠️ warning "Experimental. This reads Claude Code's
internal files…" (#243) was **removed in #341**: it described a property of the whole app rather than of this
one feature, so it was not doing its job — singling out the risky option among the ordinary ones. That the
feature rests on a private Claude Code format stays on the record in
[ADR-0066](../adr/0066-detect-sessions-awaiting-input.md).

The conditional ⚠️ "Stubbed in this development build." in the section **header** stays — it is about the state
of the build, and under a stub it has to be visible.

> **Under any `TOKENPACE_STUB` the watcher does not run at all.** A stub is a frozen, reproducible
> frame, while the watcher reads the **live** `~/.claude/sessions|jobs`, so under a stub real sessions that
> happen to be awaiting input at capture time would leak into the frame. The gate is the same one the journal
> uses (`currentScenario == .realNetwork`), and it is recomputed when the stub is switched **live** in
> dev-tools. Consequences: under a stub without `TOKENPACE_AWAITING` there is no indicator **even with the
> toggle on**, and Settings (Providers → Sessions and Menu bar) shows ⚠️ "Stubbed in this
> development build.".
>
> **`.realNetwork` alone was not enough for a live watcher — that live mode has to be chosen explicitly (#267).**
> That is, `TOKENPACE_STUB=real` or switching to "Real network (no stub)" in dev-tools; in both cases the
> indicator works on a dev build too, and this is the standard way to check the raised hand on live sessions.
> If the app ends up in live mode **not** by an explicit choice, the watcher stays down — that exact
> desync (the hand showing real sessions in a "stubbed" run) is what exposed #267.

The stub **`TOKENPACE_AWAITING=<N>`** synthesizes `N` awaiting sessions, bypassing the watcher (no live
Claude sessions needed), **and** turns the display on (it bypasses the master toggle — under a stub only), so the
feature is visible right away under `swift run` — and it is the only way to see the indicator under a stub. `N=0`
hides the indicator (just as in reality). Additionally:

- **`TOKENPACE_AWAITING_DAYS=d1,d2,…`** — days until deletion for each session (drives the color:
  `<7` → red, `<15` → orange, the rest → neutral). Omitted ones default to 20 (neutral).
- **`TOKENPACE_AWAITING_PROJECTS=a,b,…`** — project names for the sessions (round-robin), for the per-project
  breakdown.
- **`TOKENPACE_AWAITING_NAMES=n1,n2,…`** — session names, **positionally** (not round-robin, unlike
  `_PROJECTS`: projects repeat by design, whereas names identify — cyclic duplicates would make the
  "several differently named sessions in one project" scenario impossible). An **empty element**
  (`a,,c`) or an omitted one means a session with no name, i.e. an italic `<unnamed>` row. A long name in the list —
  that is how tail truncation is checked.
- **`TOKENPACE_AWAITING_CYCLE=<sec>`** ⏱ — the counter blinks between `N` and zero with this period
  (its own timer, as with `color-cycle`: polling cannot be sped up below 60 s, and the slide-out takes 0.8 s).
  It is the only way to see the **transition** — `TOKENPACE_AWAITING` on its own freezes the state. It is a knob,
  not a scenario, so it combines with any data world (bars, `blockedReset`, the pause glyph) and
  does not disable `_DAYS`/`_PROJECTS`. `3` is recommended — enough to make out both ends.

Verification (menu bar + popup + colors + the ⌥ breakdown):

```sh
TOKENPACE_STUB=1 TOKENPACE_AWAITING=6 TOKENPACE_AWAITING_DAYS=3,28,10,5,25,12 \
  TOKENPACE_AWAITING_PROJECTS=tokenpace-menubar,claude-code-daemon \
  TOKENPACE_AWAITING_NAMES="refactor popup layout,,рефакторинг індикатора очікування вводу дуже довга назва,fix flaky test,,add awaiting session names" \
  swift run
```

One launch covers every render branch: two projects (checking alphabetical order), a long
**Cyrillic** name (truncation), two empty positions (`<unnamed>`), different color buckets.

Projects alternate round-robin (`i % 2`), so even-indexed sessions go to `tokenpace-menubar` and
odd-indexed ones to `claude-code-daemon`. Expected look under ⌥:

- **`claude-code-daemon` first** — even though the most urgent session (3 days, red) sits in the
  *second* project. That is exactly the check for sorting by name: before #438 the project with the red
  session would have headed the list.
- Under each header, the session rows are indented, **the fresher ones on top** (28 → 25 → 12 → 10 → 5 → 3
  days until deletion).
- The long Cyrillic name is truncated **at the tail** with `…` and does **not** push the hand off the shared
  right-hand column.
- Two sessions are shown as `<unnamed>`, **italic** and dimmed.

The indicator's overall tone is **red** (the most urgent session wins).

- **Indicator** = `N✋` — **the number BEFORE the hand** (a count of "N sessions"), with no `×`. The hand is
  **tinted by urgency** (red <7d / orange <15d / neutral until deletion); the number is plain.
- **Menu bar**: `hand.raised` as the **first (leading) element** of the widget (ahead of pause/credits/
  bars), **the hand only, without the number**. Display is controlled by the Appearance option "Show awaiting-input icon
  in the menu bar" (the workHarder/controlFreak presets = ON). Screenshot — **the top strip of the full screen**.
- **The slot and the slide-out** (#283/ADR-0073) — with `TOKENPACE_AWAITING_CYCLE=3`:
  - **The width does not move** throughout the transition, not just at rest: capture the top strip of the full
    screen in both phases and check that `$`/the bars/the neighboring system element sit on the same
    pixels. This is #283's main criterion — the reservation comes from the option, not from the counter.
  - **The slide-out** — the hand appears from below the bottom edge and hides back the same way; in an
    intermediate frame you see the fingertips **clipped**, nothing sticks out past the widget or rides over the
    pause glyph. No fade, no width change.
  - **Option OFF** — the width is the same as it was before #283 (no reserved space at all). Check
    **both** toggles separately: "Show waiting sessions" on *Menu bar*, and the master
    "Detect sessions waiting for input" in *Providers → Sessions*. Turning the master off only disables
    the menu-bar toggle without resetting its value, so
    the slot has to be freed by it as well — otherwise ≈18 pt are held for a feature that is off.
  - **Color on the way out** — with `TOKENPACE_AWAITING_DAYS=3` the red hand stays red all the way
    down (it does not gray out mid-motion). Without `_DAYS` it is neutral = **white**.
  - **First frame** — launch with the option on and `TOKENPACE_AWAITING=2` (no `_CYCLE`): the hand is
    there in the very first draw, **without** a slide-out (a state, not a change).
  - **Toggling in Settings** while sessions are active — the slot is reserved/freed instantly, with no
    stuck half-state.
  - **Reduce Motion** (System Settings → Accessibility → Display) — the hand appears and disappears
    **instantly**; color fades stay smooth. Turning it on mid-slide immediately lands the
    glyph.
- **Popup (without ⌥)**: `Claude [Nm ago]` on the left, `N✋` — **flush right**. With `TOKENPACE_AWAITING=1` —
  the hand only, no number. Hover → tooltip "Sessions waiting for your answer.\nHold ⌥ (Option) for
  per-project stats".
- **Popup (holding ⌥)** (#438): `N✋` on the right **disappears** (the "updated just now" age stays next to
  "Claude"); below it — **a list of sessions, grouped by project**:
  - **the project header** — the name itself, **nothing** on the right. The `2✋ 1✋` chips were removed: they were
    an aggregate of the very sessions now visible by name. Hovering the header → a tooltip with
    the count ("3 sessions waiting").
  - **a session row** — the name, indented (the same one Claude Code's agentic view shows), and on the right
    **one** hand, tinted by **that** session's urgency. The name is in dim ink, the header in regular
    ink: the hierarchy reads by color too, not by indentation alone.
  - **an unnamed session** — `<unnamed>` in **italics**. On disk such a session carries not an empty field but
    a placeholder — its own 8-character `jobId`; it must not be shown, because it looks like an
    identifier to copy, while `--resume` accepts only a full UUID or a session name.
  - **a long name** is truncated **at the tail** (`…`), the hand stays on the shared right-hand column.
  - Hovering a row → a tooltip with the **full** (untruncated) name and the bucket
    ("<7d/<15d/>15d till deletion").
  - **order**: projects by name, sessions within them fresher on top.
  - **there is no row limit** and no scrolling either — deliberately. Under ⌥ the question is "what exactly is
    waiting on me", and the answer "5 of 17" does not answer it; a long list at the same time makes visible the
    cost of the habit of keeping many sessions open. The popup's height here is a gauge, not a defect.

  (The popup always shows the indicator while the feature is ON.)
- **The Menu bar option** "Show waiting sessions": ON → the hand in the bar (leading); OFF → in the popup only.
  Active only while the master is ON; otherwise it is unavailable with a **⚠️ hint**
  "Enable *Detect sessions waiting for input* in Providers › Sessions first.".

The real (non-stub) path: the watcher reads `~/.claude/sessions` + `jobs/` via FSEvents; to see the
counter live, start a few Claude sessions waiting on a permission/plan (**strictly without a stub**, with
the toggle on). Cadence details — `docs/design/awaiting-input-refresh.md`.

Checking the gate itself (there is no way around live sessions — at least one session awaiting input is needed):
launch `TOKENPACE_STUB=screenshot swift run` with the toggle on → there is **no** indicator, neither in
the bar nor in the popup; in dev-tools switch "Data source (stub)" to **Real network** → the counter
appears without a restart and the ⚠️ lines in Settings go away; back to the stub → it goes dark again.

#### The screen-state gate (#275)

There is no stub — you need a real screen lock **and** a live session awaiting input
(`TOKENPACE_AWAITING` will not do: it short-circuits the watcher). `.notice` is not written to the persistent
store, so **a live stream only**, brought up *before* the launch:

```sh
( log stream --predicate 'subsystem == "com.artem-n.tokenpace"' --level debug > /tmp/tp.log ) &
sleep 2
TOKENPACE_STUB=real swift run
```

1. Turn the toggle on → the indicator shows the counter live.
2. Lock the screen (⌃⌘Q) → `awaiting-input: parked (screen locked)`; after that, while locked, **not a single**
   `awaiting-input` line. The indicator deliberately does **not** go dark meanwhile.
3. **Without unlocking**, change a session's state (answer in another session, or let a new one block) —
   that guarantees the FSEvents event lands inside the pause window.
4. Unlock → `awaiting-input: resumed (screen available)`, immediately followed by `awaiting-input N → M`, and
   the menu bar is up to date **without** the 45-second delay.
5. **Unconditionality** is the main check: repeat steps 2–4 with the Settings →
   Providers → "Pause usage API polling while the screen is locked" checkbox **off**. `awaiting-input: parked/resumed`
   must be in place, and there must be **not a single** `screen-lock-pause:` line (the usage poll does not go on
   pause after all). This proves the watcher runs on its own ungated path.
6. System sleep: `pmset sleepnow` → wake → `parked (system sleep)` / `resumed (screen available)`.

#### How long sessions survive (#275)

Drive a session into the awaiting state, then kill its process: `kill -9 <pid>` (the pid is the file name in
`~/.claude/sessions/`). The file stays with `status:"waiting"`, but within ≤45 s (the safety tick) the
counter must **go down**. Before #275 such a hand would hang until the 30-day cleanup.

### Usage journal (#242, ADR-0067)

The journal **has no `TOKENPACE_STUB` scenario**: it writes only on live real data
(`currentScenario == .realNetwork` AND the "Record usage history" toggle in Settings → **General →
Usage history** turned on) — synthetic stub data deliberately never reaches the journal.

> ⚠️ **Testing on the notarized copy from `/Applications` — set `TOKENPACE_JOURNAL_FILE`.**
> The `-dev` suffix in the file name means "a bundle outside `/Applications`", so the copy from `/Applications`
> writes into the **same** `usage-journal-YYYY-MM.jsonl` as in real work — and that is the maintainer's real
> series, which must not be mixed with test runs. The `.realNetwork` gate protects only
> against stub data; three things slip past it:
>
> - **`TOKENPACE_GENERATE_JOURNAL=<days>` without the override** — the fixture lands straight in the real file
>   (the hook deliberately bypasses the live-only gates; it is a fixture, not a poll);
> - **runs on `real`** (checking features that require signing) leave a `resume` line and a gap
>   in the series on every restart — `lastWriteInstant` lives only in the process's memory;
> - **`migrateIfNeeded()`** starts on every launch **without** the stub gate and rewrites the existing file
>   into the current format (no data is lost — every generation leaves a `.v<n>.bak` that the app never
>   deletes — but the file was rewritten during a "purely visual" test). As of
>   [ADR-0115](../adr/0115-no-blue-on-per-model-windows.md) the pass also **recomputes `sev`** for all
>   windows using the current color model, so even lines whose format is already current get rewritten.
>
> That is why on **every** launch of the notarized copy for a check — not only with the fixture
> generator — point the journal at a temporary file:
>
> ```sh
> TOKENPACE_JOURNAL_FILE=/tmp/tp-test.jsonl /Applications/TokenPace.app/Contents/MacOS/TokenPace
> ```
>
> The override wins in `fileURL(for:)` unconditionally, so `usage`, `status` and `resume` lines all go
> there. It does not stop the migration (that one walks the files in the journal folder), but the migration
> is covered by its backups anyway.

- **The toggle:** Settings → **General** → the "Usage history" section → "Record usage history"
  (default-off); under it a read-only "Location" (the path in Application Support) with an "Open in Finder" button.
  Viewing the data is a separate **"Insights"** window; its **"Insights…"** item in the dropdown menu (together with
  the separator after it) is **temporarily commented out** in `App.swift`, because there is nothing to show there yet:
  the window remains a placeholder shell (#242) until the #244 aggregator and the #245 pilot chart land.
  So the item is not in the dropdown right now — there is nothing to check; bringing it back = uncommenting the block.
- **Live writing:** bring the log stream up **first** (`log stream --predicate 'subsystem ==
  "com.artem-n.tokenpace"' --level debug`), then `swift run TokenPace` (without a stub) with the toggle
  on → the file `~/Library/Application Support/com.artem-n.tokenpace/usage-journal-dev-YYYY-MM.jsonl`
  (the `-dev` suffix, because `.build/debug` is outside `/Applications`) fills up with valid `usage`/`status` lines
  (the usage line also carries `plan`/`tier` from the Keychain). Toggle OFF → nothing is written.
- **A multi-day file for downstream readers** (dev hooks; they bypass live-only — it is a fixture, not a poll):

  ```sh
  # generate a 14-day journal into the given file and exit:
  TOKENPACE_GENERATE_JOURNAL=14 TOKENPACE_JOURNAL_FILE=/tmp/journal.jsonl swift run TokenPace
  # feed that file to the reader (once the downstream chart #245 exists):
  TOKENPACE_JOURNAL_FILE=/tmp/journal.jsonl swift run TokenPace
  ```

  The file contains `usage`/`status`/`error`/`resume` lines with gaps — the input for the `UsageGridAggregator`
  (#244) and the pilot chart (#245), as well as for the consumer features #239/#240/#241.

## What does NOT count as verification

- **Screenshots from temporary dev-only code.** A synthetic `StatusItemView` render / PNG matrix
  proves only the drawing logic, not that the feature works in the live widget, the Settings window and the data
  flow. Do not claim "works" / `done` on that basis.

## Features that require signing

Features that depend on signing (launch-at-login / SMAppService, update banners) need a
**locally notarized `.app`** from `/Applications` — under a dev `swift run` they do not work.

**Launch such a copy with `TOKENPACE_JOURNAL_FILE`**, otherwise the test run writes into the maintainer's real
journal (the file without the `-dev` suffix — the same one used in real work):

```sh
TOKENPACE_JOURNAL_FILE=/tmp/tp-test.jsonl /Applications/TokenPace.app/Contents/MacOS/TokenPace
```

Why this applies even to runs without a stub — see ["Usage journal"](#usage-journal-242-adr-0067)
above.
