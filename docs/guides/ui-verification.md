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
> apart, so a blind click on a menu-bar item opens the wrong build. **Do not click a menu-bar item by
> name or index** — and do not address the process by name at all:
> `tell process "TokenPace"` answered `0 windows` for a process that had one
> open, where a `unix id is <pid>` query answered `1` (#492). **An AX query that picks the wrong
> instance returns an empty answer, not an error**, so a script reads it as "nothing to do here" and
> reports a pass — assert the window was actually found before trusting any result. What *is* safely
> automatable is the capture itself: the open dropdown is a layer-101 window owned by your PID, so it
> screenshots by window-id (recipe below). The maintainer's live check on the right dev icon is still
> what a PR waits on. The full method (launching, stopping by your own PID, why never a broad kill) is in
> [agent-workflow.md](agent-workflow.md), section "Launching the app to check the UI".

> 📸 **A full-screen screenshot is allowed ONLY with the maintainer's explicit permission. Every other
> screenshot captures individual windows only.** `screencapture` without an area restriction
> (`-x file.png`) grabs the maintainer's entire desktop (terminal, chats, private windows) — forbidden
> without his direct "yes", whatever the purpose.
>
> Capture **a specific window by window-id** (`-l<windowID>`), never the screen:
>
> ```sh
> # find the CG window-id over CGWindowListCopyWindowInfo, filtering kCGWindowOwnerPID == your own
> # PID (never by owner *name* — that is the wrong instance waiting to happen)
> screencapture -o -l<windowID> popup.png   # captures exactly this window
> ```
>
> - **The popup dropdown and the Settings window** are real `NSWindow`s: **open the dropdown** and
>   capture its window by window-id. You do NOT need the whole screen for that.
> - **The open dropdown (NSMenu) is capturable — verified (#513).** Its host appears in the window
>   list as **layer 101 owned by your PID**, sized like the popup and sitting just under the menu bar;
>   `screencapture -l<id>` grabs it cleanly, no full-screen grab and nothing for the maintainer to
>   open by hand. The layer-25 `Item-0` next to it is the status item, not the menu.
> - **No layer-101 window under your PID → the run is INVALID, not a pass.** The menu never opened, so
>   there is nothing to capture and nothing was tested — the #492 trap in a new place. Assert the
>   window was found before believing any result built on it.
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
> yields `screenshot` **and** logs a `.notice` listing the valid ids. An installed
> `.app` with no env var is live.

> **Live switching without a restart (#187, ADR-0047).** With dev-tools enabled
> (`defaults write com.artem-n.tokenpace devToolsEnabled -bool true` on the **installed `.app`** —
> ADR-0053; the key has no effect under `swift run`, because a binary without a bundle id lands in a
> different `UserDefaults` domain), open ⌥ Option → menu → **Development tools…** and pick a scenario
> in the **Data source (stub)** dropdown at the top of the left column — the data source switches
> live (the menu-bar icon and the popup refresh within one polling cycle), and the current scenario's
> description shows below the dropdown. `TOKENPACE_STUB=…` at launch still works and **sets the
> dropdown's initial selection**; "Real network (no stub)" returns the app to the live API. For
> scripting, `TOKENPACE_OPEN_DEVTOOLS=1` still auto-opens the window.
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
| `screenshot` | a stable frame for screenshots (fixed time 2026-01-31 22:00 UTC): 5h **green** (10 % vs ≈65 % — well behind), 7d **yellow** (36 % vs ≈29 % — mild ahead, under the dynamic threshold `0.16·(1−time)`), Fable **orange** / Mythos **red**. **Extra usage** — $1088.00 / $5000.00 (USD, ~22 %) with ≈99 % of the month elapsed → a **long green** "on pace" bar, reset "<1d". There is no "active" badge (no **base** 5h/7d limit is exhausted — only Mythos, and it does not gate work) |
| `error` | an auth error (401) on a cold start → the menu bar shows a **struck-through antenna** (`antenna.radiowaves.left.and.right.slash`, [ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md)), **not ⚠️**: the triangle is reserved exclusively for "the data contradicts itself" (`broken-reset`). The popup shows only the banner, no limit lines |
| `stale-error` | **stale-while-erroring** (the spacing bug): the first poll is valid (full bars: idle 5h "ready to start", 18 % 7d, a Fable line, "Extra usage" €11.7 of €15.0), then every poll times out → the banner "Claude API connectivity issue" / "Authentication API timeout" sits **above** all the bars. **The menu bar has two phases, not three** ([ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md)): before the `max(15 min, 3 × pollInterval)` threshold — the stale bars **with no glyph**; after it — **the struck-through antenna alone**, with no bars. If you see a glyph next to stale bars, that is a regression. (The transition itself cannot be reproduced with a stub — `failingSince` cannot be wound forward; it is covered by unit tests.) Check the **horizontal spacing between the error text and the "5-hour" line** (the same `sectionSpacing` used after the header). API + Code — major outage (red dots) |
| `standby-floor` | **the stand-by floor**: 7d is orange, but green is only **≈16 min** away → the `stand by … for green` line under ⌥ **does not appear** (the floor is 20 min). The band is narrow — 18 out of 10,064 `(u, reset)` combinations, all with `u` between 99.15 % and 99.40 %. The stub moves `h5` by 4 pp per poll so the reconstruction has time to accumulate the required 0.8 pp |
| `weekly-interp` | **the 7d reconstruction** ([#386](https://github.com/artem-from-ua/tokenpace/issues/386)) — watch it as a **sequence**, not as a frame. The weekly counter sits on an integer the whole time (61, and 62 from poll 8) while the five-hour one grows by 4 pp per poll, so any movement of the 7d bar is the reconstruction at work. **Polls 0–7** — the value creeps from the center of the bucket (61.0) up to the ceiling and holds there from poll 6 (`clipped`). **Poll 8** — the counter ticks 61 → 62, the anchor hardens onto the lower bound of the new bucket (61.5); the value **does not jump** at this transition. **Polls 9–19** — `62` walks the bar 61.5 → 62.5 in 0.1 pp steps, then clips. The key thing to check: the bar **does not jump backward** at either transition, and Troubleshoot shows both numbers the whole time |
| `weekly-reset-blackout` ⏭ | **the weekly 7d blackout, reconstructed** ([ADR-0107](../adr/0107-weekly-reset-reconstructed-from-the-last-known-one.md)) — watch it as a **sequence**, stepping with the **Refresh now** button. The first two polls return a healthy body with a real `seven_day.resets_at` — that seeds the anchor; after that every poll returns what the server actually sends for 4–6 hours after each weekly reset: `seven_day: null` plus a `weekly_all` record **with no date of its own**, meaning both sources of the reset vanish at once. The key thing to check: **the 7-day countdown stops moving** from poll 2 onward — the date holds and the marker creeps, as it should |
| `weekly-reset-unknown` | **a cold start** ([ADR-0107](../adr/0107-weekly-reset-reconstructed-from-the-last-known-one.md)): the same blackout body on every poll, but **there is no anchor** — a fresh install that has not spent a single token yet. **Remove the stored anchor first**, otherwise the app reconstructs from it and you will see ordinary bars: `defaults delete TokenPace lastSevenDayReset` (the `swift run` domain). The key thing to check: the menu bar shows the "no data" symbol (**not** ⚠️: that is reserved for "the data contradicts itself", and there is no contradiction here), and the popup **shows no limit at all** — only "Weekly reset time unknown" and a line telling you how to fix it. No countdown anywhere: the whole point is that nothing gets invented |
| `idle` | "no active 5h session" (#100): the 5h bar reads "ready to start" (**green** — there is no blue pill, [ADR-0105](../adr/0105-color-advice-governs-pacing-bars-only.md)), no phantom reset, and the time falls back to the 7d reset ("4d"). **With the default "Hide the top 5h bar" = `Until it needs attention`** ([ADR-0086](../adr/0086-tri-state-calm-bar-hiding.md) → [ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md)), an idle 5h counts as calm and **gets hidden** → only the **7d bar** remains, centered; the green "ready to start" pill is visible only in `Never` mode (key `menuBar.hideTop5hBar`, values `untilItNeedsAttention`\|`never`). **The shape is identical in both styles** ([ADR-0078](../adr/0078-idle-drawn-as-zero-in-both-styles.md)): a gray track plus a minimum pill at zero; **Progress** adds the time marker at zero on top (it covers the pill), **Pressure** leaves the pill alone. A solid full-width fill must not appear in either style. When muted, idle in the menu bar must be neither dimmer nor brighter than the calm bars beside it (the same `calmWhite` at the same alpha). **`ColorAdvice` check** ([#343](https://github.com/artem-from-ua/cc-timer/issues/343)): Settings → Appearance › Menu bar → "Colors tell me" — under **How it's going** the pill is **green**, under both muting modes it is **white**. Under **Pressure** the pill is white **always**, and the "Colors tell me" row itself is disabled and shows `Slow down` |
| `idle-blocked` | **blocked** idle (#158): idle 5h plus an exhausted 7d (100 %) with no credits → `isBlocked`. **The red pause glyph is always on the left** (#199/#227, ADR-0063) — it can no longer be turned off. There are **no bars at all** here ([ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md)): the menu bar = **pause + countdown**. The "Pause icon hides bars" toggle no longer exists — the hiding is unconditional, so there is nothing left to switch. The gray idle bar survives only in the popup. The credits icon (€) sits **between** the pause and the bars (#227). The popup always shows the full picture: status "waiting for limit reset", and the 7d reset carries a **red badge** (a pill). Compare with `idle`: there you get a **green** "ready to start", which turns **white** (`calmWhite`) under both muting `Colors tell me` modes (and unconditionally under Pressure). Here the **gray** pill is muted in no mode and no style — gray carries "there is nowhere to work", not calm ([ADR-0038](../adr/0038-idle-blocked-status.md)) |
| `active-blocked` | **active** blocked (#177): a live 5h session (48 %) with an exhausted 7d (100 %, `weekly_all` critical) and no credits → the weekly cap blocks despite the 5h quota (`isBlocked`). **The red pause glyph is always on the left** (#199/#227, ADR-0063). There are **no bars** ([ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md)): pause + countdown, and there is no toggle for it anymore. The credits icon (€) sits **between** the pause and the bars (#227). The popup always shows the full picture: the 7d reset gets a **red badge** reading "Effective blocker" |
| `optimistic-reset` ⏱ | the reset boundary (#36): 5h resets in ~20 s — the bar jumps 60 % → 0 % with no ⏰ plus a forced refresh. **Real clock** (⏱): the timer has to tick live, so this stub is not detached from time |
| `color-cycle` ⏱ | **smooth color transitions** (ADR-0070) — **real clock** (⏱: the color sweep drives its own 5-second timer). The 5h bar and the service dot walk the entire pacing palette: blue → green → yellow → orange → red and back, 5 s per zone (a 0.8 s transition plus a pause). **The 5h geometry is frozen** — the strip is pinned at half the track and the time marker parks at its end, so **only the color** moves; 7d / per-model / credits keep their real geometry as a motionless reference alongside. Check that: (1) the color **blends** rather than jumping, both in the menu bar **and** in the dropdown (the dropdown also exercises `.common` run-loop mode under NSMenu tracking); (2) switching "Colors tell me" / Style mid-sweep animates too — check **both** Style rows separately (the menu-bar one and the dropdown one, #329). While you are there: switching to **Pressure** disables the "Colors tell me" row (the label and segments gray out, the highlight moves to `Slow down`), and at that same instant the entire calm side turns **white** — the blue/green/yellow stages of the sweep must not be colored under Pressure for any value of the setting. The service dot walks **its own** scale (yellow → orange → red → blue → gray), and **not one** step goes dim under any setting ([ADR-0111](../adr/0111-degraded-dot-is-yellow-on-every-surface.md), [ADR-0105 §1](../adr/0105-color-advice-governs-pacing-bars-only.md)); this doubles as the frame for the `yellow→orange` transition — it has to read as a blend, not a jump; (3) Progress keeps its slider (it does not collapse into Pressure); (4) between transitions the timer is idle — sitting still must not heat up the CPU. **Not** for checking the pacing thresholds themselves: the `utilization` values here are synthetic |
| `reset-grace` ⏱ | the grace period at the reset boundary (ADR-0041, ADR-0045) — **real clock** (⏱: the "utilization rose recently" freshness window is measured in real time): an active 5h window (polls 0–1) → an **empty** post-reset body (polls 2–3: `five_hour.resets_at:null`, with no `session` limit — the decoder on its own would produce `sessionIdle`) → active again (polls 4+). In the "hole" the 5h line must show a calm **0 % "on pace" with a rolled-forward countdown** (`Nh at …`), and the menu bar must **not blink** — **never "resetting…" and never a full-width green bar** (ADR-0045). The grace period only arms while Claude Code is active (`claudeActive` — a journal written in the last 5 min, ADR-0118) — otherwise an honest idle "ready to start" shows immediately. Compare with `idle`: there the idle is **real** and is supposed to show |
| `broken-reset` | a broken `resets_at` (#167, ADR-0043 → [ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md)): an **exhausted** 5h (100 %) with an **unparsable but non-empty** `resets_at` (`"not-a-date"`, NOT `null` — `null` or empty would give an honest `sessionIdle` rather than an error) → the menu bar draws **a lone ⚠️** (`MenuBarMode.exhaustedUnknownReset`): no bars, no countdown — and **no pause or currency sign beside it**, even though the window is ostensibly at 100 %. Contradictory data gets a single signal. If you see a red bar, a pill, a pause, or a fake `<1m`, that is a regression. 7d is calm with a valid reset (not the source of the error) |
| `calm-degraded` | calm bars plus a **`degraded`** service dot. This is the frame about **three surfaces converging** ([ADR-0111](../adr/0111-degraded-dot-is-yellow-on-every-surface.md)): the menu bar, the popup, and the Legend page all draw this state in the **same yellow**. Check exactly that: open the popup over the bar and compare the two dots in a single capture — they must be **identical**; any difference is a regression. Cycle "Colors tell me" through all three values and switch Style — **none** of them may shift that yellow: this is the check that [ADR-0105 §1](../adr/0105-color-advice-governs-pacing-bars-only.md) still stands (the tone changed, not who decides it). A white dot must not appear in **any** state. The louder states are unchanged on both surfaces (check them on `incident-*`: `partialOutage` orange, `majorOutage` red, `underMaintenance` blue, `unknown` gray). The screenshot **must be of the real menu bar**, and **separately on the light theme** — the question there is not "is it visible" but whether the yellow reads as an alarm next to the system icons |
| `all-green` | calm bars plus **all services operational** (green): `worstProblem == nil`, so the popup has **no status lines at all** — neither without ⌥ nor under it. Since #279, ⌥ switches the **dimension** (services → incidents) rather than "show more", so green lines no longer expand; with no incidents, the section under ⌥ is simply absent. This is the frame for checking that "nothing appears for nothing" (the remaining stubs are all-operational too — except `error`, `stale-error`, `calm-degraded`, and `incident-*`) |
| `github-green` | **The state the header dot exists for** (#454, [ADR-0121](../adr/0121-github-as-a-status-only-provider.md)): GitHub monitored and every component `operational`. The provider is on by default; if you have turned it off, switch it back on for this frame (Settings → Providers → GitHub → `Development services`). The GitHub plate shows a **green dot before the word `GitHub`** and **no rows at all**. Check exactly four things: (1) the dot is a **glowing** `GlowDotView`, identical in diameter and halo to the dots on Claude's service rows; (2) it sits on the **same vertical line** as those dots (capture both plates in one screenshot with a degraded Claude frame if you need the comparison); (3) hold **⌥** — the plate shows **nothing new**: no `No ongoing incidents` row, only the `· updated …` tail appearing beside `GitHub`; (4) the **menu bar has no dot** — green never leaves the popup header |
| `github-degraded` | GitHub with **Actions degraded**, Claude untouched. The moment the row appears, the **header dot is gone and `GitHub` sits flush left** — no reserved indent behind an invisible mark. A yellow dot next to the header here is a regression, and so is a title still indented as if a dot were there. One row (`Actions`, yellow, with its age) and **only** one — the other four components are operational and draw nothing. The menu-bar dot follows worst-of-all across both providers, so it is **yellow**. Under **⌥** the row is replaced by GitHub's own incident, and the subscribe control is visible **at rest as well as under ⌥**. Claude's plate must be **absent** |
| `github-outage` | GitHub with **Git operations down** (`major_outage`) and **API requests degraded** — the worst-of-5 frame. Two rows, and the menu-bar dot **red**. No header dot, again. This is also the frame for the component **display names**: the rows read `Git`, `API`, `Issues`, `Pull requests`, `Actions` — bare, exactly as Claude's read `API`, `Code`, `Web/Desktop`. `API` appears on **both** providers' plates — that's correct, the header above each row is what attributes it. Check the row's status word links to **`githubstatus.com`**, not to `status.claude.com` |
| `github-claude-down` | **The cross-provider frame**, where the interesting bugs live. **Both** sides carry trouble: Claude Code is `major_outage` with an identified incident, GitHub's Actions is degraded with its own. Check: (1) **each plate renders only its own incidents** — under ⌥ the Claude incident appears under `Claude` and the GitHub one under `GitHub`, never the same row twice and never one under the other's header (an incident row does not name its services, [ADR-0071](../adr/0071-incident-subscriptions.md) §3, so the header is the only attribution there is); (2) **a subscribe control on each plate**, since each has an incident of its own — clicking either toggles the **same** subscription, so the other must flip with it; (3) **neither** plate shows a header dot, both being non-operational; (4) the two plates are visibly **separate glass** — proof the second `CardBackdropView` exists rather than GitHub's rows having been appended to Claude's card |
| `codex-green` | **The calm Codex plate** (#503, [ADR-0125](../adr/0125-codex-as-a-status-provider.md)): every component `operational`, so the plate is a **green dot before the word `Codex`** and nothing else — the state that would otherwise be an empty plate. This is also the frame for the **brand colour**: `Codex` is drawn in `#5871C0`, and the only acceptable check is **Digital Color Meter in sRGB on the live dropdown, in both themes** — no screenshot is a source of colour. Unlike GitHub, Codex has **one** brand role for both surfaces, so the wordmark must be the same value on light and dark; a wordmark that goes unreadable on the dark material means `codexBrandInk` is now needed |
| `codex-degraded` | Codex with **`Codex Web` degraded**, the other providers untouched. One row (`Web`, yellow) and **only** one; the header dot is gone and `Codex` sits flush left. The five rows read bare — `API`, `CLI`, `VS Code`, `Web`, `ChatGPT Desktop` — with `API` appearing on Claude's and GitHub's plates too, which is correct: the header attributes it. Check the row's status word links to **`status.openai.com`** |
| `codex-cli-outage` | **The frame that proves the endpoint choice.** `CLI` is down. That component sits at `position` 29 of `components.json` and is **absent from `summary.json` entirely**, so a `CLI` row appearing at all is the evidence that the poll reads the right feed — if it silently reverts to the summary this row disappears and everything else still looks fine. The menu-bar dot is **red** (worst-of-all). No `Login` row exists in any Codex frame, in either state: the feed lists it twice under two ids and TokenPace watches neither |
| `codex-incident` | An incident touching a monitored component, with `CLI` degraded so the plate also has a row. Hold **⌥**: the row is replaced by the incident. The one thing to check here that no other provider shows — the incident's **stage word is plain text, not a link**. The proxy feed carries no `shortlink`, so there is nothing to link to; a linked stage word here would mean a URL was invented. The subscribe control appears **at rest as well as under ⌥**, as on every plate with an incident of its own |
| `codex-incidents-unavailable` | **The degradation frame**, and the only way to see a partial failure: the components request returns 200 while the incident request returns 500. The dots and the `CLI` row keep rendering — they come from the other endpoint — and under **⌥** the plate has **no incident rows at all**, even though something is visibly wrong. That is correct behaviour, not a bug: watch for `codex incidents source=unavailable` in a live stream (`--level debug`) to confirm which path ran. This is the state a user would report as "the dots are there but nothing explains them" |
| `all-three-providers` | **Plate order and spacing**, each provider in a different state. Read the popup top to bottom: **Claude, then Codex, then GitHub** — `displayName` order with Claude pinned first, since it owns the bars. Check: (1) that order exactly, which is `ProviderID.displayOrder` and not the enum's case order (`claude, github, codex`) — the two deliberately differ, so a popup reading Claude/GitHub/Codex means an ordering site was missed; (2) the **gap between each pair of plates is equal**; (3) the three are visibly **separate glass**, three `CardBackdropView`s rather than one card with subheadings; (4) the same three names in the same order down **Settings → Providers**, whose rows are generated from the same list |
| `codex-quota-green` | **The Codex plate with bars** ([ADR-0127](../adr/0127-codex-quota-from-the-app-server.md)): a 7-day bar under the wordmark. The header reads a bare **`Codex`** at rest and **`Codex ･ Plus`** only while **⌥** is held — the plan rides the ⌥ layer exactly as Claude's does, so a resting screenshot with no plan word is correct rather than a missing label. The thing to check is what is **not** there — **no 5-hour row**. Codex reports one window; a second would have to be invented, along with its reset. Also: the reset line is **plain**, never a red badge, on any Codex row — the blocking badge answers "which reset unblocks Claude work" and is picked from Claude's rows alone |
| `codex-quota-orange` | The Codex week ahead of pace. With Claude's own `7-day` row on screen at the same time, this is the frame for the **tween-key collision**: the two rows share a title, and if the colour of one slides when the other changes, `TweenKey.bar` lost its `provider` |
| `codex-quota-exhausted` | The Codex week at 100 %. Confirm the **red blocking badge does not appear** — not on this row, and not moved onto one of Claude's rows above. Codex rows live in their own array precisely so they cannot renumber the indices that badge is keyed to |
| `codex-two-windows` | **Two Codex windows at once** — the only way to exercise the N>1 path, since the live server sends `secondary: null`. Both bars sit on the Codex plate, and Claude's rows above are unchanged in count and order |
| `codex-not-signed-in` | `codex` installed but signed out: the plate keeps its status half and shows **no bars**. No warning banner appears in the popup — that banner is Claude's, and a Codex failure surfacing there would read as a problem with the bars above. The reason lives in **Troubleshoot → Codex quota** |
| `codex-cli-missing` | No `codex` on this Mac. **Troubleshoot → Codex quota** lists the candidate paths that were tried rather than a bare "not found" — the app never consults `$PATH`, so naming what it looked at is the only way the user can tell why |
| `codex-cli-old` | A `codex` predating `account/rateLimits/read`. Exercises the two-part detection: `-32600` **and** the method name in the message. `-32600` alone is also what a malformed request returns, so a one-part check would report our own bug as the user's out-of-date install |
| `just-unblocked` | the "Back to work!" edge (#160): the first poll is blocked (7d=100 %, no credits), then workable (7d=40 %) → the notification fires once. This is the **regression** scenario. See its own section below |
| `subscription-reset-on-credits` | the "Back to work!" edge **with credits active** (#161, [ADR-0113](../adr/0113-back-to-work-tracks-the-subscription-quota.md)): the first poll has 7d=100 % **with credits enabled** — work does not stop (`canWork` = `true`), but the subscription is exhausted — then 7d=40 % → the banner fires. This is the **main** check of the change. See its own section below |
| `credits-onset` | the "Now using Extra usage credits" edge: the first poll is **not** on credits (7d=40 %, credits enabled but the base limit not exhausted → `isOnCredits=false`), then 7d=100 % with the same enabled `spend`/`extra_usage` → work spills over onto paid credit → the notification fires once (€10.77 / €15.00). See its own section below |
| `incident-active` | One active incident, Code + API `degraded`. Without ⌥ you get two service lines with ages (`2h7m · degraded`) and the subscribe line. Hold **⌥ Option** — the service lines are **replaced** by the incident line: the description wraps across several lines, and `2h7m · identified` sits on the right of the last description line; the stage word links to **that specific** incident |
| `incident-green` | An incident that is formally **open** (`monitoring`) while every monitored component is already `operational` — a measured 66-minute gap. **Nothing** may render: no service lines, no incident line under ⌥, no subscribe button. The most valuable of the four — "nothing is shown" breaks without anyone noticing |
| `incident-two` | Two simultaneous incidents over the same degraded components (the real shape from 2026-08-05 14:00). Under ⌥ you get two lines, each with its own dot, age, and link, and **one** subscribe line: you subscribe to the episode, not to the ticket |
| `incident-wrapped` | Three incidents chosen **for the way their titles wrap** (#351) — all three chip placements in a single capture. Under ⌥: (1) the first ends its last line early → `2h7m · identified` **shares** that line with it; (2) the second wraps onto two lines and pushes `13m · investigating` onto a **third**; (3) the third fits on **one** line, but there is still no room for the chip → `6m · investigating` stands **alone on the second line**, leaving a wide gap after the title. Every chip must sit **on the right** |
| `incident-spacing` | Two degraded services and two **short, single-line** incidents — the frame for judging **vertical rhythm** (#351). Toggle ⌥ back and forth: two lines swap for two lines of the same height, so the gaps must not change. All four must match — incident↔incident, incident↔subscribe, service↔service, service↔subscribe |
| `incident-recovery` ⏱ | A quiet recovery: the first two polls carry a degraded incident with an update, then the components turn green **with no new update at all** (the `mgp99sn4ynd4` case). The lines must disappear on their own; an update listener would have stayed silent for 43 minutes. See its own section below |
| `pressure-sweep` | **The Pressure scale** ([ADR-0076](../adr/0076-pressure-scale-for-marker-less-bar.md), [ADR-0101](../adr/0101-pressure-is-the-gauge-ahead-half.md), #307). 5h: `t≈93 %`, `u=97 %` → **below** the minimum pill on the window scale, ≈ **57 %** on the remainder scale. 7d: `t=30 %`, `u=38 %` → **11 %**, inside the yellow band (0–16 %) and just above the minimum pill (8.1 %) — the **tightest** pair in the app; check whether the yellow still reads as a short strip rather than a dot. Check that: (1) switching **both** Style rows to **Progress** shows the pacing bars with marker in place and `subdivisions − 1` ticks; (2) under **Pressure** the 5h strip is five times wider than the 7d one, and there are no ticks in the popup at all — only the zero line, labeled `0` under ⌥; (3) switching **Menu bar** between **Pressure** and **Balance** must not move the 7d strip by a single pixel; (4) set **Menu bar → Pressure** and **Dropdown → Progress** — that is where a stored `mixed` migrates ([ADR-0080](../adr/0080-per-surface-bar-style.md)) |
| `balance-sweep` | **The Balance scale** ([ADR-0079](../adr/0079-centred-zero-gauge-scale.md), #326). One line per side of center. 5h is deep behind (`t = 90 %, u = 70 %`): `r = −2` clamps to `−1` and **the left half is full** — the state every other style draws as a minimum pill; Pressure collapses it to zero outright. 7d carries the same moderate lead as in `pressure-sweep` (`t = 30 %, u = 38 %`) → a short strip **to the right** of center (`+11.4 %`, the same number the Pressure bar draws — switching styles does not move it). Check that: (1) the center line is present in **every** state, idle included, and only its tips stick out from under the track — it must not read as a Progress marker; (2) switching Pressure ↔ Balance does **not** change what the 7d line says; (3) on Balance the 5h line is the widest thing on screen, on Pressure the narrowest; (4) under a muting "Colors tell me" the direction is the only remaining cue. Compare against **Pressure**: the calm side there is white **unconditionally**, which is why the row is disabled only under Pressure ([ADR-0105](../adr/0105-color-advice-governs-pacing-bars-only.md)); (5) both surfaces — in the popup there is a single tick, in the middle. Balance is the **default** on both surfaces (the Work harder! preset); check that Balance leaves the preset on **Work harder!** rather than dropping it to `Custom` |

### The money credits icon (#144)

The currency icon (`coloncurrencysign` ¤ / `eurosign` €, and so on) sits in the **leading** position:
in the bar modes (`.expanded`/`.iconOnlyReset`) it leads; only in the diagnostic `.error` mode does it
stay trailing (to the left of the service dot). All three frames pin 7d at 100 % and differ in their
`spend` block. Since credits cover the exhausted window (`subscriptionExhaustedWhileCovered`, not
`isBlocked`), there is **no** pause glyph here ([ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md)):
**there are no bars either**, and the widget = the currency sign + a countdown to the subscription
quota coming back.

| Stub | Credits state | Icon color |
|---|---|---|
| `credits-active` | enabled, limit €15.00, spent €10.77 (~72 %) | usage-vs-time pacing (green when not ahead, amber/orange when ahead) |
| `credits-limit-reached` | `spend_limit_reached` (a €5.00 limit below €10.77) | **red** (forced usage = 1) |
| `credits-no-limit` | enabled, limit "unlimited" (`limit: null`) | **neutral** (foreground, no pacing) |
| `credits-zero-spent` | "€0 of €15 ⟷ `<reset line>`" — both halves drop their zeros (spend: `amountMinor == 0`; cap: a whole number). Under **⌥** it becomes "spent €0.00 of €15.00", and the reset **stays**: in a 320 pt column (#396) the pair takes 276 pt. The cap stays on the line even at zero — without it the line would read as unlimited. The bar is at zero. There is **no badge at all** (ADR-0108) |
| `credits-max-header` | **The widest first line** (#396), and the one that sets the popup's width: `Extra usage ･ progress ⟷ [$] well ahead of pace` = 307 pt against a 320 pt column. What to look at is that the two halves **do not touch** — a visible gap must remain between the badge and the status. The word `progress` (italic, after the `･`) appears only under **⌥**. The token limits here are deliberately **healthy** (7d at 42 %), otherwise the state "credits enabled but not in use" is unreachable |
| `credits-max-detail` | **The widest second line**: a four-digit cap, spent down to the cent, so both halves carry thousands separators — `spent $5,000.00 of $5,000.00`. Together with the longest reset phrasing that comes to 376 pt, so the fit gate **drops the right half entirely** (rather than truncating it into an ellipsis). The heading above it reads `limit reached` in **plain text, with no badge**: the cap exists, so the red belongs to the reset badge below, not to the heading (one filled red per line) |
| `credits-no-limit-spent` | **The only state where the red sits in the heading**: `limit: null` + `spend_limit_reached: true`. There is no reset (with no cap there is nothing to reset), so no carrier for the red exists below — and the `out of credits` badge settles into the heading. Compare with `credits-limit-reached`, which does have a cap: there the heading is plain text and the red capsule is on the reset |
| `all-exhausted-credits-block` | **Everything is exhausted — 5h, 7d, and the €15 cap at 100 %** — but the token windows reset **later** than the month does (7d in 40 days). By the last-line-of-defense rule (`BlockingReset.select`), the credits reset is then the first way back, so the **red reset badge sits only on the Extra usage line**. Both token lines say `limit reached`, but their resets are in ordinary dim text |
| `all-exhausted-token-blocks` | **The same three limits are exhausted**, but the 7-day window resets **last** (in 24 days, past the end of the month). The red badge moves onto the **7-day** line, and the credits reset becomes ordinary. Run both stubs back to back to see the rule itself rather than a coincidence |
| `credits-month-end` | A check of the **tightest spot** on the monthly ruler (ADR-0092): the clock is at 90 % of the month, so the time marker gets as close as it ever does to the right-hand `Jan 31` label. What to look at is that the marker and the label **do not touch** and that the label stays readable despite the marker's glow. This doubles as the main check of the decision itself: switch Settings → Appearance › Dropdown → Style to **Pressure** and to **Balance**; the token bars become marker-less strips while this one stays Progress with its marker and labels — the question is whether it reads as *a different instrument* rather than as a glitch |

> Check that the amounts carry the **€** currency (not `$`): the formatter takes the symbol from the
> currency code (EUR→€). The section's bar is the same `PopupBarView` as the token bars, but with
> **its own scale and ruler** ([ADR-0092](../adr/0092-extra-usage-own-ruler.md)): always **Progress**
> regardless of the dropdown's Style, and **without** ticks. There are no month-edge labels (`Jan 1` …
> `Jan 31`, [ADR-0108](../adr/0108-extra-usage-one-anatomy-and-per-bar-style-caption.md)). Under ⌥ the
> scale is named by the **style word** in the heading — `Extra usage ･ progress`.

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
the leftmost option leaves the least on screen.

| Mode | Behavior |
|---|---|
| `When it needs attention` (the `.chill`/`.workHarder` default for **per-model**; **not offered** for Extra usage) | visible when at least one of its lines is **orange or red** (`.ahead`/`.exhausted`) — **or** while ⌥ is held |
| `Once used` (the `.chill`/`.workHarder` default for **Extra usage**) | visible when it contains anything non-zero: a per-model line with `utilization > 0`, or money spent — **or** while ⌥ is held |
| `Always` | the group is always visible |
| ~~`With ⌥ Option`~~ | **Removed from both rows** (#374) and **deleted from the enum** (#381). The `.optionOnly` case no longer exists; the old raw value resolves to `onceUsed` through `PopupSectionVisibility.legacyRawValues` — see the recipe below |

The first gates the per-model/per-service lines (`Opus`/`Sonnet` from the legacy fields plus
`weekly_scoped` as `Fable`/`Mythos`), the second gates the **Extra usage** section. Blue `far behind`
is **not** alarming (`.farBehind` is calmer than green), so it does not expand the group.

> `When it needs attention` here and `Until it needs attention` on the "Hide the top 5h bar" row are
> **one threshold** viewed from two sides ([ADR-0104 §7](../adr/0104-appearance-named-for-behaviour-on-three-layers.md)).
> The predicates differ, though: here it is `.ahead`/`.exhausted`, there it is `BarView.isCalm`, which
> counts a blue `farBehind` as calm. The divergence shows on `far-behind`: a blue 5h does **not** expand
> the group here, but it also does **not** stop being hidden there.

**The two predicates measure different things.** `Once used` reads the **value**, `When it needs
attention` reads pacing's **verdict** about that value: 2 % at the start of the week is both "used" and
"needs attention" at once, while €10.80 spent against an **unlimited** cap is "used" but **never**
"needs attention" (no cap → no bar → no severity) — which is why the credits row does not offer
`When it needs attention` at all.

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
- **⌥ remains the escape hatch:** in **any** mode, holding ⌥ expands the group.
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

**The old `nonCalm` / `aboveZero` / `optionOnly` values have no migration marker keys of their own** —
the value is carried through `PopupSectionVisibility.legacyRawValues`
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

An explicit `true` → `always`, an explicit `false` → `whenItNeedsAttention`, and a missing key → the preset default
(`whenItNeedsAttention`). Check all of this in the dev domain (`swift run` writes to `TokenPace`, the
signed dev build to `com.artem-n.tokenpace.dev`), **not** in the real domain with your own settings,
and do **not** run `defaults delete` on the domain — that wipes the real settings.

### The "Claude Code" header in the dropdown: update time + service list (#227)

Two behaviors in the popup's header, both tied to ⌥ Option (`PopupViewController.optionHeld`,
`rebuild()`):

- **The update time ("updated 2m ago" / "updated just now")** sits **on the left, right after the
  "Claude [plan]" brand** on the same line (the right edge of that line belongs to the awaiting-input
  indicator alone, and stays empty when there is none). It is shown **whenever the data is stale**
  — that is, when its age exceeds `PopupViewController.staleAgeThreshold` (2× the base polling rate
  `PollingEngine.baseInterval` = 360 s / 6 min); below that threshold it appears **only while ⌥ Option
  is held**. The check: open the dropdown shortly after a poll (< 6 min) — no time is shown
  until you hold ⌥; leave the dropdown open for > 6 min (or kill the network with the `stale-error`
  stub) — the time appears on its own without ⌥.
- **The service list** is shown when there is a problem (`serviceStatus.worstProblem != nil`, e.g. the
  `error` stub), when some component **turned green in the last 15 min** (#279 — so that something just
  fixed does not vanish instantly, leaving a popup indistinguishable from "nothing ever broke"), **or**
  while **⌥ Option** is held and there is something to show in the incident dimension.

  **⌥ switches the dimension, not the level of detail** (ADR-0071 §2): incident lines are
  shown instead of service lines. Healthy green lines do not expand under ⌥, and if there are no
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
> A dozen layout-level fixes were tried and rejected — the list is in
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
  `stale-error`, `calm-degraded`, `incident-*`, and the `github-*` frames. The remaining frames (pacing,
  credits, idle, color-cycle, and so on) return an all-operational status, so that an unrelated service
  dot does not add noise to a frame that is checking something else entirely.

  **The same discipline applies to GitHub's canned body** (#454): every scenario that is not a `github-*`
  one answers the GitHub endpoint all-operational, so no dot leaks into the sixty-odd existing frames.
  That body carries the **real** twelve-component list captured from `githubstatus.com` — the five
  monitored plus seven ignored, including the non-service row literally named
  `Visit www.githubstatus.com for more information`. Carrying the junk is deliberate: it is what
  demonstrates that matching by exact component name needs no filter, so do not "fix" its presence.

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
7d at 100% **with credits enabled** (work does not stop — `canWork` is `true` here), then 7d at 40%. The
banner **must** appear. On `just-unblocked` (without credits) this stays a **regression** frame rather
than a demonstrative one.

The mirror check (the banner must **not** appear): a reset of the credits themselves while 7d is still at 100% — on
`credits-onset` after the credits come off the ceiling.

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

> Under [ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md) the countdown does not
> exist next to the bars at all. The frames below cover the **color and the hiding** of the
> bars. **A check that runs through the whole table: in none of these frames may
> there be a number next to the bars.** If there is one, it is a regression.

Fixed severity, 5h × 7d:

| Stub | 5h | 7d | Note |
|---|---|---|---|
| `5h-orange` | orange | green | by default (`Until it needs attention`, [ADR-0086](../adr/0086-tri-state-calm-bar-hiding.md) → [ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md)) 5h is **orange → not hidden**, 7d stays calm → **both bars, NO number**. The key case that no mode hides a loud bar |
| `both-orange` | orange | orange | both ahead by ~26 pt; **two bars with no number** |
| `both-red` | red | red | both exhausted → this is already a **barless** state: ⏸ + `4d`, the **later** of the two resets (`BlockingReset.forBlocked`, "the last line of defense"). There are no bars at all ([ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md)) |
| `red-orange` | red | orange | 5h is exhausted but 7d is not yet → there is no block, and the frame keeps its bars: **red 5h + orange 7d, no number** |
| `calm5-orange7` | calm | orange (days away) | **The key frame for the `Until it needs attention` mode** ([ADR-0086](../adr/0086-tri-state-calm-bar-hiding.md)): the calm 5h hides, **the orange 7d is left alone**, and there is **no number** next to it — this is the very "a distant orange 7d loses its number" named as the price in [ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md). Under `Never` — two bars, also with no number |
| `calm-both` | green | green | both calm and **green** (a small margin: 5h ~10 pt < 0.20, 7d ~9 pt < 0.143 — under the fixed behind threshold, so NOT blue). The best stub for going through both "Hide the top 5h bar" modes ([ADR-0086](../adr/0086-tri-state-calm-bar-hiding.md) → [ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md)): `Until it needs attention` (the default) → **a lone centered green 7d**; `Never` → two bars. They **never** both disappear together — that is an invariant, not a coincidence. No reset text in either. It is also the handiest frame for "Colors tell me": under `How it's going` both bars are green, under both muting modes they are white, and under **Pressure** they are white unconditionally and the row itself is not on the page ([ADR-0105](../adr/0105-color-advice-governs-pacing-bars-only.md)) |
| `near-reset` | orange (override) | green | ADR-0044: 5h is only ~2 pt ahead (usage 98 vs elapsed ~96%), but the reset is **12 min** away → the override turns the bar **orange** (without the override it would be yellow/calm). A check of the dynamic threshold + the 20-min override. The countdown does **not** appear here — work is running on the subscription ([ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md)); only the color changes |
| `mid-band-reset` | orange | green | [#284](https://github.com/artem-from-ua/tokenpace/issues/284)/[ADR-0074](../adr/0074-one-reset-format-on-both-surfaces.md): the 5h reset is **4 h 41 min** away — the 90 min – 24 h band, which reads `5h`. The only stub for this band. The number is visible **only in the popup** (`5h at …`), not in the bar — check the popup line itself |
| `far-behind` | blue | blue | ADR-0061/0081: both base bars are deep behind (5h margin ~0.55, 7d ~0.61, past the 0.40/0.286 threshold) **and the week itself is calm**, so the weekly gate is open → **blue**. A check of the blue zone + `ColorAdvice`: Settings → Appearance › Menu bar → "Colors tell me" — under **Slow down or speed up** blue stays colored, under **Slow down** it is muted to white, under **How it's going** everything is colored. Under **Pressure** blue is white at any value, and the row itself is not on the page ([ADR-0105](../adr/0105-color-advice-governs-pacing-bars-only.md)) — so the three modes have to be checked on Balance or Progress. The per-model/credits lines (in the popup) always stay green |
| `weekly-gate` | green | green | [ADR-0081](../adr/0081-weekly-capacity-gate-for-blue.md): 5h is deep behind (u = 5%, t = 60%) — but 7d is **exhausted**, so the weekly gate is closed and 5h must be **green**, not blue. In the popup the 5h line says "on pace", not "far behind pace". The pair to `far-behind`: the frames differ only in the state of the week |
| `idle-week-hot` | green (idle pill) | green (idle pill) | The week is ahead of pace (70% at t ≈ 29%) but **not** exhausted → green. There is no blue pill anywhere, so **in the menu bar this frame is indistinguishable from `idle`** — both draw a green "ready to start". Do not waste time looking for a difference there: use the frame to check the **converse** — that the state of the week has **no effect** on idle (against `idle` the pill and the word must be identical, and against `idle-blocked` they must differ: gray, "waiting for limit reset"). The weekly gate does its real work on **active** bars — that is `far-behind` against `weekly-gate`, not this pair. In the popup the frame stays useful as a check that a 7d line at 70% with t ≈ 29% does not read as blocked |
| `near-zero` | green (pill) | green (pill) | Near-zero fill on **fresh** windows (5h 0%, 7d 4%, Fable/Mythos ~1–4%, almost zero elapsed) → a colored gap a hair thick. A check of the **min-strip pill geometry**: the colored part must be drawn as a rounded "pill" **inside** the track (both ends round), not a thin sliver poking out past the rounded edge. Both in the menu bar and in the popup; the interval labels and the time marker must line up with the scale compressed by `BS` |
| `edge-extremes` | pill at the very start | red (full width) | Both edges of the scale at once: 5h at 0% and 7d at 100% on **fresh** windows. A check that **the strip's ends are grafted onto the ends of the track**: 7d must fill the track **edge to edge** — no gray tail either to the left or to the right of the fill; 5h shows a pill flush against the left end. Measure in pixels (the fill and the track must end at the same x), because a 2 pt tail is easy to miss by eye. Both in the menu bar and in the popup |

> When adding a new feature with a state of its own — **add a stub and update this table** (as was done for #103, #94, ADR-0044, ADR-0061, ADR-0062).
>
> **Blue is for the base 5h/7d only.** The blue zone (`.farBehind`, ADR-0061) appears when the margin
> `time − usage` exceeds the behind threshold (2h/2d = 0.40/0.286), more than 20 min of the window has
> elapsed, **and** the bar is entitled to blue (`blueAllowed`). Three cases are not entitled
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
  **Work harder!** is the default preset (fresh install / Reset), and it sets **Balance on both
  surfaces** — which is exactly why a fresh install shows Balance.
  Each preset gives both surfaces **one** style, and the three presets cover the three styles exactly once each:
  Chill → Pressure, Work harder! → Balance, Control freak → Progress. Check that clicking a preset
  moves **both** Style rows in sync.
- **The config copy button** (the `doc.on.doc` icon at the **right edge of the "Change
  appearance preset" header row**, #257): a click puts pretty-printed JSON on the clipboard with the 7 Appearance keys + `preset` +
  `appVersion`; for ~1.2 s the glyph turns into a `checkmark`, then turns back (tooltip on hover: "Copy
  appearance settings to clipboard"). **Watch the layout while the glyph is swapped**: nothing
  may twitch — the box is fixed in both dimensions, and implicit animation is disabled.
  The copy button in the Troubleshoot window must give the same feedback — the constants are shared in `CopyFeedback`.
  Paste it into an editor and check **two things at once**
  ([ADR-0104 §3](../adr/0104-appearance-named-for-behaviour-on-three-layers.md)):
  1. **the JSON is nested** — two groups, `"menuBar"` and `"dropdown"`, not flat top-level keys.
     The surface is visible without knowing the code;
  2. **the order inside a group matches the order of the controls on the page, top to bottom**
     (`menuBar`: `style` → `colorsTell` → `hideTop5hBar` → `showServiceStatusDot`; `dropdown`:
     `style` → `showPerModelLimits` → `showExtraUsage`), not alphabetical; check it against the panel side by side.

  A quick recipe (paste what you copied into `/tmp/appearance.json`):

  ```sh
  # key order as in the dump, with the group names — it must read top to bottom like the panel
  grep -nE '^\s*"' /tmp/appearance.json
  ```

  There is **no** `barStyle` key in the dump (it is legacy-only, read-only for old configs), nor
  any flat name (`calmColorMode`, `calmBarHiding`, `modelLimitsVisibility`, `extraUsageVisibility`).

  The `customAppearanceValues` slot is **gone**
  ([ADR-0112](../adr/0112-appearance-presets-preview-apply-commits.md)): the config is not rewritten behind
  the user's back, so there is nothing to stash. The key is swept away at launch — check exactly that as a separate
  step: on an old build do a manual setup (so that it gets written), verify
  `defaults read TokenPace customAppearanceValues`, update the build — the key is gone, and **the seven live keys
  are unchanged**.

  The `"preset"` field describes the **saved** config: the raw preset (`chill`/`workHarder`/`controlFreak`)
  that it happens to equal, or the literal `"custom"` when it equals none of them (a string, not `null`,
  so that the field does not vanish from the dump). Change any toggle by hand → `"preset" : "custom"`. The button
  saves nothing — the config does not change after a click; **and during a preview it copies the saved
  config, not what is on screen**, so clicking `Chill` does not change the `"preset"` field.
- **Style — TWO separate rows** ([ADR-0080](../adr/0080-per-surface-bar-style.md), #329): the first
  in the **Menu bar** section, the second in **Dropdown**, both `Pressure | Balance | Progress`. The row is called
  **"Style"** (not "Bar style") and on **both** surfaces it is the same control — a picker with
  preview images (three tiles with captions, an accent-colored outline around the selected one, as in
  System Settings → Appearance); the order and the captions are shared (`AppearanceBarStyle.segments`),
  so they cannot drift apart.
  **Style sits in its own `Section`** on both pages — with a separator below it, and the rows underneath
  (colors / visibility) live in their own card.
  The styles: "Pressure" — a strip from the left edge with no marker, of length `pressureLength` =
  `max(0, balanceOffset)` = `clamp(r, 0, 1)`, where `r = (u − t)/(1 − t)` (zero on the bar = exactly on plan,
  16% = the start of orange, [ADR-0101](../adr/0101-pressure-is-the-gauge-ahead-half.md));
  "Progress" — a gap + a time marker on the window's scale; "Balance"
  ([ADR-0079](../adr/0079-centred-zero-gauge-scale.md), #326) — a strip from the **center**,
  `clamp(r/k, −1, +1)`: to the right when ahead, to the left when behind, plus a center rule in
  every state (in the menu bar, 1 pt under the track; in the popup, the zero rule drawn **through** the bar at 0.5).
  Check:
  1. **Independence** — switch the menu bar row, and the dropdown **must not budge**, and vice versa
     (click the icon to see the popup);
  2. **a mixed pair → `Custom`** in the preset control (no preset gives the surfaces different styles);
  3. **the hints are not duplicated**: under the menu bar row there are no hints at all — the preview shows the style
     right there ([ADR-0093](../adr/0093-bar-style-picked-by-picture.md)); under the dropdown row — a single line,
     "*Extra usage* bar always draws in *Progress* style." It sits **under the word "Style"**, in the left
     column of the row (a shared `VStack` with the heading), not under the tiles across the full width of the panel;
  4. **three** tiles in the row: check that the control is not
     clipped in the **narrowest** Settings window. In **each** picker also check: the "Style" label is
     aligned to the **top** edge of the row (not centered); the click registers **on the first try** when
     the Settings window is not active; selecting a tile **does not change the row's dimensions** (the outline is drawn
     inward, the caption has a fixed width — otherwise the row twitches); the tiles are not scaled —
     the widget in them must be the same size as in the real menu bar / dropdown;
  5. **the credits bar does not move** ([ADR-0092](../adr/0092-extra-usage-own-ruler.md)): switch the
     dropdown to Pressure and Balance on a stub with credits (`credits-active` / `credits-month-end`) —
     the token bars turn into markerless strips, while "Extra usage" stays Progress with its marker and
     month-edge captions (not a bug — see the hint in item 3);
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
  Saved values: a legacy `barStyle` key unfolds at launch into two —
  `mixed` → menu bar `pressure` + dropdown `progress`, and every other raw value into itself on both
  surfaces. Anyone who did not have the key gets the **Balance/Balance** default.
- **Colors tell me** (`Slow down | Slow down or speed up | How it's going`,
  [ADR-0104](../adr/0104-appearance-named-for-behaviour-on-three-layers.md)). The segments run **quieter
  to the left**: `Slow down` leaves only orange colored, `Slow down or speed up` adds distant blue to it,
  `How it's going` mutes nothing. Orange/red are **always** colored
  ([ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md)). All three segments are always
  enabled ([ADR-0081](../adr/0081-weekly-capacity-gate-for-blue.md)).
  **The scope is the pacing bars only** ([ADR-0105](../adr/0105-color-advice-governs-pacing-bars-only.md)):
  cycle through all three values and check what does **not** react — the service dot (`calm-degraded`:
  [ADR-0111](../adr/0111-degraded-dot-is-yellow-on-every-surface.md) makes `degraded` yellow unconditionally),
  the currency glyph (`credits-active`, `credits-no-limit`) and the idle pill in
  the "green or blue" part (`idle`, `idle-week-hot`). The only things that must react are the 5h/7d bars — and the
  pill itself, in the "colored or white" part.
  **The row is disabled under Pressure** — a separate scenario below.
- **Hide the top 5h bar** (`Until it needs attention | Never`,
  [ADR-0104](../adr/0104-appearance-named-for-behaviour-on-three-layers.md),
  [ADR-0086](../adr/0086-tri-state-calm-bar-hiding.md),
  [ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md)). The hint under the row is **a single phrase** —
  "Either way, once a limit is actually reached both bars give way to the countdown to it": it describes
  what the row does **not** control. Check on `both-red` that the promise is true — there are no bars there at all.
- **Show service status dot** — its own **card** (#381), not in the same block as the three rows above:
  those read `PacingModel`, this one reads `ProviderMonitoring`. There is a hint: "Appears next to the bars
  when a monitored service reports an outage" — the only thing on the page that names the connection to
  Providers. Check that there is a separator between the cards, and that the second card has **no** heading
  (a single row does not need one).
- **The popup's ruler splits in two, and there is no toggle for it**
  ([ADR-0098](../adr/0098-ruler-split-identify-always-explain-on-option.md)) — no "Show ticks on
  bars" option, no `showTicks` key, none in
  [`AppearanceConfigExport`](../../Sources/TokenPaceKit/AppearanceConfigExport.swift) either. Check in the popup, holding
  and releasing ⌥:
  - **always visible — the zero rule**, drawn **through** the bar (it is drawn **under** the track, so only
    its ends are visible) at the zero of every markerless scale: in **Balance** that is the center (0.5,
    [ADR-0079](../adr/0079-centred-zero-gauge-scale.md)), in **Pressure** — the start (0). The color's role is
    the same `centreTick` as in the menu bar rule ([ADR-0096](../adr/0096-zero-tick-on-pressure.md)),
    the height is scaled for the popup's taller bar (12 pt on a 6 pt bar against 10 on a 5 pt one), and the width is 5/7 of the zero
    pill's width. In **Progress** there is no zero rule at all: the position there is carried by the time marker;
  - **only under ⌥** — the scale's ticks: under **Progress**, fractions of the window (`subdivisions − 1`: 4 for 5h, 6 for
    7d). There are no `0` or month-edge captions
    ([ADR-0108](../adr/0108-extra-usage-one-anatomy-and-per-bar-style-caption.md)). Release ⌥ — the ticks
    disappear, and the zero rule alone remains;
  - there is no tick at 20% ("exactly on plan") in Pressure;
  - **the menu bar** has its own zero rule
    ([#371](https://github.com/artem-from-ua/cc-timer/pull/371)/[#372](https://github.com/artem-from-ua/cc-timer/pull/372)),
    but neither a 20-percent tick nor a `0` caption — ⌥ does not reach that surface.
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
back smoothly, together with the muting (`easeInOut`, 0.2 s), rather than jumping.

The key **negative** check: switch `Hide the top 5h bar` between segments — its own control
**must not** go anywhere. The animation is bound specifically to `menuBarStyle`.

And a check that the hiding itself is honest, **on the live bar**: under Pressure the calm side must be **white**
at any saved value. The sharpest frame is `far-behind` with `Slow down or speed up` saved.

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
Legend page. The question is whether the yellow is too loud on a light bar:

- take a screenshot of **the top strip of the real screen** (not of a window — [the rule about the menu material and
  vibrancy](#testing-menu-bar-widget-colors-swatch-mode--color-picker)). The question to ask of the shot is not "is it visible", but whether the dot reads as an
  **alarm** next to the system icons: it says "take a look", not "here is what broke";
- **three surfaces — the same yellow.** The popup over the bar in **one** shot, and the Legend page
  (`TOKENPACE_OPEN_SETTINGS=1 TOKENPACE_SETTINGS_SECTION=2.0`). Any difference is a regression;
- cycle "Colors tell me" through all three values and switch Style — **none** of them may shift
  the yellow on any of the surfaces ([ADR-0105 §1](../adr/0105-color-advice-governs-pacing-bars-only.md)
  still stands: the dot does not read settings);
- **a white dot must not appear in any state** — the `calmWhite` branch in `statusDotTarget` is
  gone. `swift test` will **not** catch this: the function is `private` in the app target, and the test
  target links only `TokenPaceKit`, so a live check is the only net here;
- the louder states stay colored on both surfaces: `partialOutage` is orange, `majorOutage` is
  red, `underMaintenance` is blue, `unknown` is gray (the `incident-*` frames);
- repeat on the **dark** theme — check the contrast of the yellow against the dark bar;
- on `color-cycle` catch the frame where a yellow **pacing gap** and a yellow **dot** sit side by side —
  they are told apart by shape and position, not by tone
  ([ADR-0111](../adr/0111-degraded-dot-is-yellow-on-every-surface.md), "Consequences").

### Stronger glow on the zero pill in the popup under Pressure (#381)

`TOKENPACE_STUB=far-behind swift run`, Settings → Appearance › **Dropdown** →
Style = **Pressure**, then click the icon and look at the popup.

Under Pressure the calm side is drawn as zero, so the strip degenerates into a **minimum pill** — and
the ambient glow, sized for a full strip (radius 21 pt, alpha 0.35), reads on it as a pale
smudge. For this case the pill gets a **triple** pass — radii **40 / 22 / 10 pt**, alpha
**1.0** each, from wide to tight.

`withGlow` sets the **shadow's alpha**, and `strength` is clamped at 1, so extra brightness can only
come from the **number** of passes compositing over each other.

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
  rendering.

## Scenarios without a stub

### The dropdown's ⌥ gate, its caption and the pinned action items (#475, #521)

No stub: the behavior depends on the modifier and two defaults keys, not on the data. Any scenario
works — `TOKENPACE_STUB=screenshot` gives a stable frame to compare margins against.

**Two independent switches** sit in Settings → Appearance › Dropdown: "Show the ⌥ Option hint"
and "Always show action items" (default-on,
[ADR-0127](../adr/0126-settings-and-quit-stay-visible-by-default.md)). Neither disables the other —
all four combinations are reachable, and "both on" is a state worth looking at on its own.

Start with the switch **on** (the default):

1. **⌥ up, caption on** — the shipping default. The menu is the popup, the caption
   `hold ⌥ Option for more` right-aligned under the status column, then `Settings…`, a separator and
   `Quit TokenPace`. Quit reads **plainly**: its build tag is still ⌥-only. **No `Troubleshoot…` and
   no `Development tools…`** — those stay behind ⌥ whatever this switch says.
2. **⌥ held.** The caption goes, `Troubleshoot…` (and `Development tools…` with `devToolsEnabled`)
   appear, and Quit grows its tag. `Settings…` and `Quit` do **not** move or flicker — they were
   already there.
3. **⌥ up, caption off.** Same as state 1 without the caption line. Watch the **gap between the card
   and `Settings…`**: it should look like every other menu item gap. This is where an over-generous
   bottom margin shows up — the constant that applies when nothing follows the card must not apply
   here ([ADR-0117](../adr/0117-dropdown-actions-behind-option.md)).

Then turn the switch **off** — this restores ADR-0117's behavior exactly, and states 4–6 are the
regression check for it:

4. **⌥ up, caption on.** The menu is the popup plus the caption. **No action items at all** — no
   `Settings…`, no `Quit`, no separator above where `Quit` would be. A stray separator is the
   failure this state is most likely to show.
5. **⌥ held.** The caption disappears and the full column appears in one step.
6. **⌥ up, caption off.** The menu is the widget alone — the only state that reaches the lone-plate
   margin. Check the **bottom margin against the sides**: they should read as equal. They are *not*
   equal as constants: `NSMenu` pads below the hosted view, so the code carries 8.5 to render the
   sides' 14. Judge the rendered gap, not the number.

7. **The live preview** (Settings → Appearance › Dropdown, the window beside the panes). It must
   show **no caption in any ⌥ state** — it has no menu items to offer — while ⌥ still reveals the
   on-demand content it mirrors. Its own card margins must be unchanged by every state above,
   including the switch: the preview has no action items to pin.

**Then run the states again with the update line showing** — add
`TOKENPACE_UPDATE_STATE=available` (or `failed`). That line is visible in *both* ⌥ states, which makes
it a neighbour under the card, and it is the case the first pass missed:

- the card keeps its **trimmed** margin in every one of these states — the even one belongs to a
  plate with nothing under it at all;
- the separator above the update line follows the **action items**, not ⌥: with the switch on it is
  there in both ⌥ states, because `Settings…` is above it; with the switch off it appears only under
  ⌥, and with ⌥ up there must be **no separator** between the card and the update line;
- **with the switch off and the menu closed**, let an update check run before opening the menu. That
  is the path through `refreshUpdateMenuItem` rather than the ⌥ swap, and it is the one that regresses
  if the two disagree about what "items above" means;
- with the caption on, it sits between the card and what follows, and the whole must read as one
  column rather than as stacked blocks.

Measuring rather than eyeballing is worth it for the margins: capture the menu, then compare the
plate's gap to the popup edge on all four sides in pixels (remember a 2× capture halves to points).

Both switches are read on **every menu open**, so toggling either in Settings takes effect on the next
open with no restart — verify that directly, since a stale read would look identical to a working one
until the app is relaunched. Toggling while the menu is *open* changes nothing until it is reopened,
which is expected.

"Always show action items" is read **once more at menu-build time**, so the built state matches what
the first open will show. Check it on a **cold launch**: with the switch on, `Settings…` must be in
the first drawn frame rather than appearing a beat later, and with it off the menu must open as the
widget alone. A one-frame flicker either way means the build-time read was skipped.

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

No system notifications: everything lives in one
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
the "Last archived …" status. Both states get the triangle — the difference is in the text
("free up space" versus "will resume when you plug in"), not in the icon. The only rows drawn without a
triangle in this project are hints that **describe** what a control does.

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

### Codex quota, live (`TOKENPACE_STUB=real`)

The collector runs `codex app-server` on this Mac, so it only exists on the live path — under any
stub the source is a canned one and **no process is spawned at all** (which is what lets the seven
stubs above run on a machine that has never installed `codex`).

```sh
TOKENPACE_JOURNAL_FILE=/tmp/tp-test.jsonl TOKENPACE_STUB=real swift run & echo $! > /tmp/tp-dev.pid
```

`TOKENPACE_STUB=real` is not optional here: a `swift run` with no stub resolves to the frozen
screenshot frame, the collector is never built, and the plate simply has no bars — which looks
exactly like a broken feature.

What to check:

- The **7-day bar renders and there is no 5-hour row**.
- The header reads a bare **`Codex`** at rest and **`Codex ･ Plus`** while **⌥** is held, and it
  flips both ways with the modifier rather than waiting for the next poll. The plate below must not
  visibly reflow as the header grows — Claude's header has no special width handling and neither
  does this one, so any jump is a real finding.
- **Process hygiene, by observation only — never `kill` by name.** `pgrep -fl "codex app-server"`
  shows at most **one** child, and **none between reads**: the process is started for a read and gone
  before it returns, so a slow sampler will legitimately see zero. Validate a sampler against a child
  you started yourself before trusting a zero from it — an unvalidated negative is the
  "quiet answer read as a pass" trap.
- **Privacy.** A full poll cycle under `/usr/bin/log stream --level debug` and a `grep` of the temp
  journal must show **no email, no `codexHome`, no raw response**. The journal carries no quota record
  at all ([ADR-0127](../adr/0127-codex-quota-from-the-app-server.md) §D11) — `usage` and `status`
  lines only.
- **Troubleshoot → Codex quota** names the binary, the version, the age and latency of the last
  successful read, and the last error.

**Live** (no stub needed): unplug the power and wait until the sync becomes due (24 h from
`lastArchiveSync`, or reset the marker) → the logs show `archive: deferred reason=on-battery`, the "Last
archived" date does not move, and "Archive now" meanwhile **does** work (it bypasses the battery gate deliberately).

Checking the space gate live requires a genuinely full volume — practically unreachable, hence the stub;
the arithmetic itself is covered by units (`ArchiveSpacePlanTests`).

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
Notifications**. `4`, `5` and `6` stay as **holes**: old recipes still carry them, and pointing
them at a different pane would mean a recipe that lies instead of failing (`5`/`6` are now addressed in the dotted
form, since the pages moved one level down).

**The dotted syntax means child pages** ([#341](https://github.com/artem-from-ua/tokenpace/issues/341),
[ADR-0084](../adr/0084-settings-drill-in-child-pages.md)): `<section>.<child index>`, where the index
counts the pages **in display order**, not by raw value. An unknown section or child is now **written
to the log** (`settings hook: unknown …`) instead of being ignored silently.

> ⚠️ **A child is addressed in the dotted form, never by its raw value.** `SettingsChildPage` has raw values
> of its own (50+), and they are **not** the hook's indexes: `=53` parses as *section* 53, which does not exist. The hook writes
> `settings hook: unknown section 53 — ignored` and opens the window wherever it was left last time —
> a recipe that does nothing will look like it works if you already happened to be on the page you wanted.
> **Check the log**, not just what is on screen: nothing in `settings hook` = the value was accepted.
>
> Display order ≠ raw order. The `Legend` row is drawn **above** the presets, and both surfaces sit
> below it, so `2.0` is Legend even though its raw value (53) is the largest of the three. The hook reads
> `SettingsChildPage.reachablePages(of:)`, which sorts by the row's position on the page.

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
(560) and stretched out**.

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

1. **Sidebar** — **five** rows: About / General · Providers / **Appearance · Notifications**.
   `Appearance` and `Notifications` sit **in one group, with no separator between
   them**; the separator remains only above, over the `General · Providers` pair. Capsule tints:
   `Appearance` — green, `Notifications` — red, `General` and `Providers` share **one**
   gray ([ADR-0094](../adr/0094-provider-row-brand-badge.md)).
2. **Three navigation rows** — on `Appearance`. **`Legend` sits in its own section ABOVE the presets**
   (blue `map.fill` chip, the same blue as in `About` — both pages only inform), and below the
   presets section come `Menu bar` and `Dropdown`, each
   with a chip (black / white with a hairline) and a **chevron**.
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
     text sits exactly over the line. Renamed a caption? Check this first.
3. **Navigation** — a drill-in puts the page title in the toolbar (`Menu bar`), ‹ returns to
   `Appearance` rather than "through" it; switching a sidebar row from an open child lands on the
   root of the new section.
3a. **Clicking an already-highlighted sidebar row exits the child** (#374,
   [ADR-0100](../adr/0100-dropdown-style-tiles-and-retired-option-segment.md)): go into
   `Appearance › Dropdown` and click `Appearance` — the parent page must open.
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
   right away (seeding). The window's subtitle reads **"try alt view with the ⌥ Option key"**.
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
   **Then close and reopen Settings a few times, and close it once more** — the app must still be in
   the menu bar. The cursor tweak isa-swizzles the split controller, and a close that takes the whole
   app down with it is what a mishandled second swizzle looks like (#492). Reopening is the part that
   matters: the first open cannot show the bug. **On a Touch Bar Mac specifically** — the crash runs
   through `_NSTouchBarFinder`, so a machine without that hardware will pass this step no matter what
   the code does.
8. **Theme.** Flip light↔dark with the preview open: neutrals re-resolve and the colors **snap** rather
   than blend. Measure colors with Digital Color Meter in sRGB, not off a screenshot.

The chrome types (`PreviewChrome`/`ThemedFillView`/`TitlePlaqueView`) from ADR-0107 have a single consumer —
this preview.

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

**The copy button (`doc.on.doc`, at the right of the "Usage API — last response" header)** gives
the same feedback as the copy-config button in Settings → Appearance: for ~1.2 s the glyph becomes a
`checkmark`, then returns (the shared constants are in `CopyFeedback`). Check **both** buttons in
one run: the duration and the glyphs must look identical. Separately, check whether **holding**
the button down makes the image "blink" — the button type is `.momentaryPushIn`, not `.momentaryChange`
(which would restore the glyph on mouse-up and wipe out the checkmark).

### Development tools — the stub selector and the payload log (#187, #279)

A dev-only window with two tools that have nothing to do with each other beyond a shared gate.
Color picking is done the way the next section describes (swatch + color picker).

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
   taken off a screenshot (`NSBitmapImageRep.colorAt(...)` and friends) —
   ([#202](https://github.com/artem-from-ua/tokenpace/issues/202)). The source of truth is **Digital Color
   Meter** (the native color picker) in **sRGB** mode (View → Display in sRGB), or values from there dictated by the
   maintainer; compare TARGET and RENDER **in the same space**. A screenshot is fine for **seeing** the
   problem (layout, "lighter/darker", what is where), but not for exact RGB.
2. **Always on the REAL bar, a screenshot of the TOP STRIP of the full screen — not of a window.** A window
   screenshot (e.g. the dropdown preview in Settings) renders the widget **without menu-bar vibrancy and without the
   wallpaper** → it lies. Transparency effects (the color "breathing" with the background) are visible only on the real
   bar next to the system icons (moon/Wi-Fi/battery). The right way is `screencapture -x` of the whole screen + a crop of the top **~46 px**; compare our element
   and its system neighbor **on the same shot of the real bar**.
3. **Vibrant surfaces draw their own material, not `windowBackgroundColor`.** A real `NSMenu` popup
   sits on the **menu material** (dark ≈ `0x212121`), so a solid `windowBackgroundColor` fill in an
   ordinary window reads noticeably lighter.
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
your reply in the dropdown."). There is no permanent ⚠️ warning here — that the feature rests on a
private Claude Code format stays on the record in
[ADR-0066](../adr/0066-detect-sessions-awaiting-input.md).

The conditional ⚠️ "Stubbed in this development build." in the section **header** stays — it is about the state
of the build, and under a stub it has to be visible.

> **Under any `TOKENPACE_STUB` the watcher does not run at all.** The watcher reads the **live**
> `~/.claude/sessions|jobs`, so under a stub real sessions that happen to be awaiting input at capture
> time would leak into the frame. The gate is the same one the journal
> uses (`currentScenario == .realNetwork`), and it is recomputed when the stub is switched **live** in
> dev-tools. Consequences: under a stub without `TOKENPACE_AWAITING` there is no indicator **even with the
> toggle on**, and Settings (Providers → Sessions and Menu bar) shows ⚠️ "Stubbed in this
> development build.".
>
> **Live mode has to be chosen explicitly (#267)** — `TOKENPACE_STUB=real` or switching to "Real
> network (no stub)" in dev-tools; in both cases the indicator works on a dev build too, and this is
> the standard way to check the raised hand on live sessions. If the app ends up in live mode **not**
> by an explicit choice, the watcher stays down.

The stub **`TOKENPACE_AWAITING=<N>`** synthesizes `N` awaiting sessions, bypassing the watcher (no live
Claude sessions needed), **and** turns the display on (it bypasses the master toggle — under a stub only), so the
feature is visible right away under `swift run` — and it is the only way to see the indicator under a stub. `N=0`
hides the indicator (just as in reality). Additionally:

- **`TOKENPACE_AWAITING_DAYS=d1,d2,…`** — days until deletion for each session (drives the color:
  `<7` → red, `<15` → orange, the rest → neutral). Omitted ones default to 20 (neutral).
- **`TOKENPACE_AWAITING_PROJECTS=a,b,…`** — project names for the sessions (round-robin), for the per-project
  breakdown.
- **`TOKENPACE_AWAITING_NAMES=n1,n2,…`** — session names, **positionally** (not round-robin like
  `_PROJECTS`). An **empty element** (`a,,c`) or an omitted one means a session with no name, i.e. an
  italic `<unnamed>` row. A long name in the list checks tail truncation.
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
  *second* project. This checks sorting by project name, not by urgency.
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
    pixels — the reservation comes from the option, not from the counter.
  - **The slide-out** — the hand appears from below the bottom edge and hides back the same way; in an
    intermediate frame you see the fingertips **clipped**, nothing sticks out past the widget or rides over the
    pause glyph. No fade, no width change.
  - **Option OFF** — no reserved space at all. Check
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
  - **the project header** — the name itself, **nothing** on the right. Hovering the header → a
    tooltip with the count ("3 sessions waiting").
  - **a session row** — the name, indented (the same one Claude Code's agentic view shows), and on the right
    **one** hand, tinted by **that** session's urgency. The name is in dim ink, the header in regular
    ink: the hierarchy reads by color too, not by indentation alone.
  - **an unnamed session** — `<unnamed>` in **italics**. On disk such a session carries a placeholder
    (its own 8-character `jobId`), which must not be shown — `--resume` accepts only a full UUID or a
    session name, not that placeholder.
  - **a long name** is truncated **at the tail** (`…`), the hand stays on the shared right-hand column.
  - Hovering a row → a tooltip with the **full** (untruncated) name and the bucket
    ("<7d/<15d/>15d till deletion").
  - **order**: projects by name, sessions within them fresher on top.
  - **there is no row limit** and no scrolling either — deliberately: under ⌥ the question is "what
    exactly is waiting on me", and "5 of 17" does not answer it.

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
> writes into the **same** `usage-journal-YYYY-MM.jsonl` as in real work — the maintainer's real
> series. The `.realNetwork` gate protects only against stub data; three things slip past it:
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
  the separator after it) is **temporarily commented out** in `App.swift` — the window remains a
  placeholder shell (#242) until the #244 aggregator and the #245 pilot chart land. The item is not in
  the dropdown right now — bringing it back = uncommenting the block.
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
