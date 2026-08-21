# TokenPace — product spec

> Status: **Draft** (after the product interview, 2026-06-21)
> Horizon: Phase 1 (menu bar app) — for personal use; the architecture is designed so that Phase 2 can
> add iPhone/Watch via CloudKit, and a public release after that.

## The problem

Claude Code subscription usage is bounded by two rolling limits — a **5-hour** window and a **7-day**
window. The existing statusline plugin shows both with *pacing* (are you ahead of or behind the linear
spending rate relative to the time elapsed?). That information is visible only in the terminal.
`TokenPace` brings it **into a single glance** — first in the macOS menu bar (Phase 1), and later onto
an Apple Watch complication and iPhone home-screen widgets (Phase 2), together with a countdown to the
nearest limit reset.

The product evolves in two steps:
- **Phase 1 — a menu bar app for macOS.** A standalone native app on the same Mac that holds the
  token. The chain is simple: `Keychain → usage API → drawing in the menu bar`. **No CloudKit needed.**
- **Phase 2 — iPhone + Apple Watch.** To take the data beyond the Mac, CloudKit is added as the
  transport; the same Mac agent starts writing usage snapshots, and the devices read them.

## Data source (confirmed)

- Endpoint: `GET https://api.anthropic.com/api/oauth/usage`
- Headers:
  - `Authorization: Bearer <accessToken>`
  - `anthropic-beta: oauth-2025-04-20`
  - `User-Agent: claude-code/<version>` — **mandatory.** Without it the client lands in an
    aggressively rate-limited bucket and gets constant 429s (see the source below). Always send it,
    even for a one-off request — it costs nothing.
  - `Content-Type: application/json`
- Fields used: `five_hour.utilization`, `five_hour.resets_at`,
  `seven_day.utilization`, `seven_day.resets_at`.
- **API documentation source:**
  [Claude-Code-Usage-Monitor#202](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor/issues/202)
  — a detailed breakdown of the endpoint, the headers, the response schema, the UA quirk, and caching
  strategies. Reference implementations: [aistat](https://github.com/drogers0/aistat) (Go),
  jens-duttke/usage-monitor-for-claude (Windows tray), LightspeedDMS/claude-usage (Python CLI).
- Authorization token: the Claude Code OAuth credentials from the macOS Keychain
  (`Claude Code-credentials`). Structure: `accessToken`, `refreshToken`, `expiresAt`,
  `scopes`, `subscriptionType`, `rateLimitTier`.

### Token lifecycle (confirmed)

- The lifetime of `accessToken` is **~8 hours** by our own direct measurement of `expiresAt` from the
  Keychain (7.6 h remained at the moment we checked). ⚠️ Source #202 instead claims **~60 min** — a
  discrepancy; we trust our own measurement, but the behavior is worth rechecking (it may depend on
  the token type / the CC version). Either way, the hybrid strategy below is correct for both.
- Token storage (from source #202): the macOS Keychain `Claude Code-credentials`; on Linux/Windows —
  `~/.claude/.credentials.json`; or the `CLAUDE_CODE_OAUTH_TOKEN` variable. All of them contain
  `claudeAiOauth.accessToken`, `.refreshToken`, `.expiresAt` (epoch in milliseconds).
- The rate limit is counted **per access token**, not per account.
- A `refreshToken` is present → the access token can be renewed without logging in again.
- Consequence: any naive "paste the token into the iPhone once" approach breaks when it expires.
  **That is why the token never leaves the Mac.**

### Token strategy: read first, delegate refresh to the CLI

Claude Code refreshes the token in the Keychain itself while it is running, overwriting
`Claude Code-credentials` with a fresh pair. So **while CC is running, the agent only ever needs to
read** an always-fresh token — no refresh required.

The gap: the agent is a 24/7 daemon that has to keep the widget fresh **even when CC is closed** (at
night, for instance). If the token expires while CC is not running, nobody will renew it.

**The strategy (see [ADR-0017](docs/adr/0017-delegated-token-refresh.md)):**
1. Read the token from the Keychain. If it is still valid (`expiresAt` in the future) → use it as is.
   This is the ordinary path; the agent never touches a refresh.
2. **Fallback only:** if the token has expired (CC is not running, nobody renewed it) — the agent
   performs a **delegated refresh**: it spawns `claude --model haiku -p '/usage'` as a subprocess, and
   CC rotates the pair in its own Keychain (`/usage` is a local command that spends no limits; verified
   by the spike in issue #8). The agent re-reads the Keychain and continues within the same polling
   cycle.

The agent **never performs a `refresh_token` grant itself and never writes to the Keychain**: refresh
tokens rotate (confirmed by studying comparable tools), so a self-refresh without a correct write-back
would desynchronize Claude Code's pair and log the CLI out. Delegation removes both the race with CC
over the token and the write-back itself.

## Architectural decision

**No backend of our own.** The Mac is the only component that touches the Anthropic API.

### Phase 1 (menu bar, no CloudKit)

```
Mac agent (token in the Keychain)
  → delegated refresh via the claude CLI (fallback, ~8 h)
  → GET /api/oauth/usage
  → drawing the mini-widget in the menu bar (redraw only when use changes OR the timer resets)
```

Everything is local, on one Mac. No network beyond the Anthropic API itself. No CloudKit, no Apple ID
pairing, no iOS host app.

### Phase 2 (a transport for devices is added)

```
Mac agent (the same one)
  → ... (as in Phase 1)
  → writes a snapshot into the private CloudKit DB  (only when use changed OR the timer reset)
CloudKit (the same Apple ID)
  → iPhone widgets read the snapshot
  → the Apple Watch complication reads the snapshot
```

- **Pairing:** one Apple ID across Mac + iPhone + Watch. The private CloudKit database is automatically
  shared across the user's own devices, so — **zero authorization on the devices**.
  (Cross-Apple-ID sharing via QR/CloudKit sharing — to be considered later.)
- **No token entry on the device.** (The initial idea — pasting the token into the iPhone — was
  rejected.)
- **Writes only on change:** the Mac agent writes a new snapshot into CloudKit only when `utilization`
  changed or `resets_at` rolled over (a 5h or 7d timer reset). This minimizes CloudKit writes, battery,
  and network use on the devices.

## UI

### The mini-widget in the macOS menu bar (Phase 1 — the primary UI)

A custom `NSView` inside an `NSStatusItem` (not a template icon and not plain text), because we need
colors the system must not repaint for Dark/Light.

- **On the left:** two horizontal parallel bars — **5h** on top, **7d** below. The design **follows the
  current statusline exactly** (`build_progress_bar`): each bar has four parts, not one color:
  - a **gray zone** (`dark_gray`) on the left = the share **used** (`u_blocks`);
  - a **dark blue zone** (`dark_blue`) on the right = not yet used / the "future";
  - the **pacing gap** between use and time:
    - if `time_pct > usage_pct` (behind the rate — good) → the gap is **green**
      (`bright_green`);
    - if `usage_pct > time_pct` (ahead of the rate — bad) → the gap is **red**
      (`bright_red`);
    - > **Color evolution (not in the original statusline).** Both sides eventually gained an internal
    >   split. The "ahead" side splits into **yellow** (a soft lead) / **orange** (a strong one, ≥ the
    >   *dynamic* `0.16·(1−time)` threshold) + **red** on exhaustion
    >   ([ADR-0044](docs/adr/0044-dynamic-pacing-threshold.md)). The "behind" side splits into **blue**
    >   (`.farBehind`, deep behind / a large reserve) / **green** (close to the line) by a **fixed**
    >   threshold (base 1h/5h, 1d/7d × 2 → 2h/2d) — only for the base 5h/7d bars, and only while the
    >   **weekly window itself has reserve** (the weekly-capacity gate: blue advises speeding up, and
    >   that advice must not appear on an exhausted or hot week)
    >   ([ADR-0061](docs/adr/0061-far-behind-blue-pacing-zone.md),
    >   [ADR-0081](docs/adr/0081-weekly-capacity-gate-for-blue.md)). The full calm-to-alarm order: blue →
    >   green → yellow → orange → red. This is the pacing blue (`.paceBlue`), distinct from the
    >   "future"/idle-bar blue above.
  - the **current-time indicator** — a separate mark for the `time_pct` position (in the statusline it
    is a `■̿` block with a double overline; in the menu bar it is a thin vertical line on the bar). The
    bar's presentation is configurable (`BarStyle`, [ADR-0062](docs/adr/0062-configurable-bar-presentation.md),
    [ADR-0076](docs/adr/0076-pressure-scale-for-marker-less-bar.md),
    [ADR-0079](docs/adr/0079-centred-zero-gauge-scale.md)) — **three styles**: "Progress" draws that
    marker on the window's scale; "Pressure" draws only a colored strip from the left edge without it,
    measured against the **time remaining** (`max(0, balanceOffset)` = `clamp(r, 0, 1)`,
    `r = (u − t)/(1 − t)` — a zero bar means "exactly on plan",
    [ADR-0101](docs/adr/0101-pressure-is-the-gauge-ahead-half.md));
    "Balance" draws a signed strip from the **center** (`clamp(r, −1, +1)`), to the right when ahead and
    to the left when behind, so the unspent reserve is visible too — Pressure is exactly its right half.
    **The style is chosen separately for the menu bar and for the dropdown**
    ([ADR-0080](docs/adr/0080-per-surface-bar-style.md)): two independent keys, so the surfaces can draw
    different things (e.g. the quieter Pressure in the cramped bar and Progress in the roomy popup —
    exactly the pair that was available before #329 as a separate "Mixed" case, now removed).
    **The exception is the "Extra usage" bar** ([ADR-0092](docs/adr/0092-extra-usage-own-ruler.md)): it
    is always Progress, because its window is a calendar month rather than a limit window, and it
    carries its own ruler labeled with the first and last day of the month instead of ticks.
  - The positioning logic for the indicator and the zones — port it 1:1 from `build_progress_bar`
    (`u_blocks`/`t_blocks`, `ind_pos`).
- **Instead of bars — a countdown to the reset, and only where work is not running on the
  subscription** ([ADR-0091](docs/adr/0091-countdown-only-where-work-is-not-running.md)). The widget has
  exactly two looks: **bars without a number** while work is running on the subscription, and a **glyph
  + a number without bars** when work has stopped (⏸) or costs money (¤). The "bars + a number" pair
  does not exist: `MenuBarMode.expanded` has no field for a countdown, so it is
  **unrepresentable**. The reason is that a number does not say whose it is: next to two bars, "21m"
  has to be guessed at by magnitude. The glyph beside it names the cause unambiguously, so the question
  never arises.
  - The format is **a single-unit duration, rounded to the nearest unit, at any distance**: `<1m`,
    `45m`, `1h`, `5h`, `4d`
    ([#284](https://github.com/artem-from-ua/tokenpace/issues/284),
    [ADR-0074](docs/adr/0074-one-reset-format-on-both-surfaces.md)).
  - It is **the same number** the reset line in the dropdown starts with (`5h` in the bar ↔ `5h at
    20:40` in the popup) — both surfaces take it from `ResetClock.relativeRounded`. But since ADR-0091
    the surfaces **no longer show it at the same time**: in the working state the number exists only in
    the dropdown (the reset line there is never gated by severity), and in the menu bar only in the
    bar-less states.
  - **There is no wall clock (`20:40`) in the menu bar.** The 90-minute threshold once adopted in
    [ADR-0006](docs/adr/0006-reset-time-absolute-vs-relative.md) has been removed: it made the two
    surfaces inconsistent and produced a width jump at the format boundary. The clock stayed **only** in
    the dropdown, as a qualifier (`at 03:00`), where there is room for it.
  - **No active 5h session** (#100, [ADR-0027](docs/adr/0027-session-idle-no-phantom-reset.md)): when
    the 5h window does not exist on the server (no `resets_at`), the synthesized "phantom" 5h time
    (`now+5h`) is **not** shown. Idle on its own remains a state with bars, i.e. **without a number**;
    the countdown appears only if idle is simultaneously **blocked** (the weekly window is exhausted and
    credits do not cover it) — and then it is already a bar-less ⏸ + `4d` state.
  - **An exhausted window with a broken `resets_at`** — a lone **⚠️**, with no pause, no currency, and
    no bars (`MenuBarMode.exhaustedUnknownReset`): the state is known, its end is not, and contradictory
    data gets one signal, not two.
  - How to read what is on screen from the user's side — [docs/reference/menu-bar-signals.md](docs/reference/menu-bar-signals.md).

- **No compact/idle mode.** While work is running on the subscription and the data is valid, the menu
  bar **always** shows the pacing bars — regardless of the `utilization` level. A "compact mode" was
  planned earlier — collapsing to a small `*` icon at low `utilization` — but it has been **removed**:
  the threshold relied only on the spending percentage, not on Claude's actual activity, so the asterisk
  appeared even during active work right after a window reset (both limits < 5%). That was confusing and
  gave no useful information. The bars are **absent** in the bar-less states (work has stopped or costs
  money — ⏸/¤ with a countdown; an exhausted window with a broken date — ⚠️) and in the error state / on
  a cold start (the token expired, the API is unreachable, there has not been a first successful poll
  yet) — the crossed-out antenna is shown then (see below). The decisions —
  [ADR-0015](docs/adr/0015-no-idle-mode.md),
  [ADR-0090](docs/adr/0090-menu-bar-answers-can-we-work.md),
  [ADR-0091](docs/adr/0091-countdown-only-where-work-is-not-running.md).

- **The "no active 5h session" state** (#100, [ADR-0027](docs/adr/0027-session-idle-no-phantom-reset.md)).
  This is **not** the removed idle mode coming back: both bars stay. When the 5h window does not exist
  on the server (the first token spend has not created it yet — `resets_at` is absent), the 5h minibar
  is drawn as **zero** — a gray track with a **green** pill at zero (a neutral "the window has not
  started"; gray when there is nowhere to work — `isBlocked`,
  [ADR-0038](docs/adr/0038-idle-blocked-status.md)); under the Progress style a time marker at zero is
  added on top, and the shape is the same in both styles
  ([ADR-0078](docs/adr/0078-idle-drawn-as-zero-in-both-styles.md)). There is no blue pill: it stood for
  a second claim ("there is something to burn") on the same mark
  ([ADR-0105](docs/adr/0105-color-advice-governs-pacing-bars-only.md), superseding §4 of
  [ADR-0081](docs/adr/0081-weekly-capacity-gate-for-blue.md)). The 7d bar is ordinary, and the time on
  the right shows the 7-day reset (see above). `is_active` is **not** used for the detection
  (unreliable).

Technical notes (Dark/Light, item width, sandbox, distribution) — see the "Technical notes (menu bar)"
section.

#### Dropdown / popup (click on the icon)
- **Details for both limits:** 5h and 7d — `%`, the reset time, the pacing status as text. The base
  lines are always visible; two **optional** groups — the per-model/per-service lines and the "Extra
  usage" section — have configurable visibility (#211, [ADR-0072](docs/adr/0072-dropdown-section-visibility.md),
  [ADR-0104](docs/adr/0104-appearance-named-for-behaviour-on-three-layers.md)). The per-model lines offer
  **three** modes — `When it needs attention` / `Once used` / `Always`; the "Extra usage" section offers
  **two**, **without** `When it needs attention`, because with an unlimited spending cap there is no bar
  and therefore no severity. There is no separate `⌥ Option` segment
  ([ADR-0100](docs/adr/0100-dropdown-style-tiles-and-retired-option-segment.md)): holding ⌥ reveals the
  group in **every** hiding mode, so that segment had no behavior of its own.
  `Once used` shows the group as soon as anything in it is nonzero (usage > 0 % or money spent),
  `When it needs attention` — when the line is orange/red. The order of the segments is **quieter on the
  left**, as everywhere else on the Appearance panel.
- **The 5h line without an active session** (#100, [ADR-0027](docs/adr/0027-session-idle-no-phantom-reset.md)):
  when the 5h window does not exist, the line is more compact — a "5-hour" heading + the status
  **"ready to start"** on the right, the bar draws zero — a gray track with a **green** pill at zero
  (gray when `isBlocked`; there is no blue — [ADR-0105](docs/adr/0105-color-advice-governs-pacing-bars-only.md)),
  under Progress plus a time marker in the same place
  ([ADR-0078](docs/adr/0078-idle-drawn-as-zero-in-both-styles.md); the tick marks stay), and **there is
  no second text line at all** (no "0%", no time).
- **The per-model breakdown:** `seven_day_opus` / `seven_day_sonnet` separately (the data is already in
  the API; the fields may be `null` if the model was not used — must not crash). Newer models (Fable,
  for example) **have no** top-level field — they arrive only as `limits[]` entries with
  `kind: "weekly_scoped"` and `scope.model.display_name`; such lines are rendered generically
  (`<display_name> (7-day)`) and are not duplicated with the legacy fields (verified against the live
  API on 2026-07-06).
- **Always (the service line, even in the normal state):**
  - "Last update: N min/h ago" (the time of the last successful `200`).
  - "Refresh interval: Xs" — the current **dynamic** interval (180 s in the normal state; during backoff
    show the increased interval, e.g. `6 min`).

#### Error states / missing authorization
- **If authorization has been failing for longer than the threshold** → the bars disappear from the menu
  bar **entirely**, and a **crossed-out antenna**
  (`antenna.radiowaves.left.and.right.slash`) takes their place — "we can't reach the API". The
  threshold is counted **in attempts, not in minutes**:
  `UsageHealth.glyphAfter(for:)` = `max(15 min, 3 × pollInterval)` — 15 min during an active session and
  45 min while there is none ([ADR-0091](docs/adr/0091-countdown-only-where-work-is-not-running.md)).
  A flat 15 min would raise the glyph after **one** failed attempt on an inactive machine, because
  `PollingEngine.inactiveInterval` is itself 15 min.
  - **There are exactly two phases, not three.** The intermediate one (the "glyph **next to** the old
    bars") is gone: bars that stale invite a reading they cannot support ("here is where I stand"), and
    the popup already explains the failure in words. Before the threshold — the old bars with no glyph;
    after it — a bare glyph with no bars.
  - **⚠️ (the exclamation mark in a triangle) does not belong to this state.** The triangle stayed
    exclusively for "the data contradicts itself" — an exhausted window with a broken `resets_at`. "I
    can't reach the API" is a routine event, and drawing it with the same glyph as a rare server bug
    would put the two on equal footing.
  - **A 429 does not count as a failure**: that is the server saying "not so fast", and `Retry-After`
    alone would be enough to raise the glyph on a system that works as intended. The backoff and the
    reason in the popup stay.
- **On any non-working authorization** (immediately, without waiting for the threshold) → show a warning
  in the popup with an explanation ("could not fetch usage data; check that you are signed in to Claude
  Code"). Until the threshold, the menu bar itself may still show the last known data with a timestamp.
- The "last update + interval" service line helps the user understand how stale the data is and when the
  next attempt will happen.
- **There are no macOS notifications** — the entire signal is in the menu bar + the popup (a deliberate
  decision).

### The Apple Watch complication (Phase 2)
- Two mini rings: **5h** and **7d** utilization.
- The ring's color encodes **pacing** (ahead / on rate / behind) — ported from the statusline
  (`>90%` use at `<=90%` time → warning, `100%` → critical).
- Under the rings: the **time to the nearest reset** of whichever limit resets first — both relative
  (`3h22m`) and as an absolute time (`hh:mm`).

### iPhone (Phase 2)
- A minimal host app — the container iOS requires for widgets. No full-screen mode, no settings, no UI
  for the agent's status (at the start of Phase 2).
- The home-screen widgets mirror the complication (5h + 7d rings + the pacing color + the nearest reset).
- **The future (backlog, by priority):** (1) a full-screen detail screen with charts/history,
  (2) widget/theme settings + a premium unlock, (3) the status of the link to the Mac agent.

## Pacing logic (ported from the statusline)

Reuse the proven formulas from `statusline.sh` (a 1:1 port):
- `calc_time_pct(resets_at, window_seconds)`: the fraction of the window that has elapsed
  (5h = 18000s, 7d = 604800s).
- `build_progress_bar(u_pct, t_pct)`: the gray / green-or-red / blue zones + the time indicator
  (see the description in the "The mini-widget in the macOS menu bar" section).
- `get_limit_indicator(usage, time)` — the thresholds verbatim:
  - `usage == 100` → critical (the statusline shows `❌`);
  - `usage > 90` **and** `time <= 90` → a warning, "ahead of the rate" (`⚠️`);
  - otherwise → neutral.
- **Bonus:** the server already hands back an alarm level in `limits[].severity` — we can check our own
  formula against the server's signal.

## Agent behavior (sleep, network, time, logging)

- **Sleep/wake and the network — sensible behavior** (via `NSWorkspace.shared.notificationCenter`):
  - the Mac sleeps → pause the polling timer;
  - waking up → an immediate out-of-band poll (the data may have gone stale);
  - loss of network → show the last known data marked stale; polling resumes automatically when
    connectivity is back.
- **Logging — `os.Logger` (unified logging).** No files; visible in Console.app / `log stream`.
  **Never log the token** (mark sensitive fields as `private`, the unified-logging default).
  Do log: request success / error code, backoff firing, Keychain-access events (to diagnose Phase 1's
  main risk), sleep/wake.
- **Reset times are in the device's local time.** The API returns `resets_at` in UTC (`+00:00`); convert
  it to the device's local time zone via Foundation (`Calendar`/`DateFormatter`), which handles DST
  (summer/winter time) automatically. The format: **the menu bar always shows a relative single-unit
  duration** (`45m`, `5h`, `4d`); **the dropdown** adds a local qualifier to it — `hh:mm` in the user's
  locale (12/24-hour) for a reset within the day, otherwise the day of the week
  ([ADR-0074](docs/adr/0074-one-reset-format-on-both-surfaces.md),
  [ADR-0043](docs/adr/0043-unified-reset-line-and-remove-resetnow.md)). Parsing `resets_at` must
  normalize the microseconds.

## Technical notes (menu bar)

- **Dark/Light tinting.** By default macOS repaints template menu bar icons (white/black to match the
  theme). To keep the colored pacing bars from being eaten — draw a **non-template** `NSView` and
  control the contrast for both themes ourselves.
- **Item width.** Two bars + the time ≈ the width of 2–3 ordinary menu bar icons. Acceptable, but watch
  that it does not bloat without reason.
- **A 24/7 daemon.** An app with no Dock icon (`LSUIElement = true`), launching at login
  (`SMAppService`), redrawing the menu bar only when the data changes (energy efficiency).
- **Keychain access is Phase 1's main technical risk.** The token sits in `login.keychain` as a
  generic-password item (`class: genp`, `svce: "Claude Code-credentials"`, `acct: <user>`), created by
  Claude Code. `statusline.sh` reads it through the `security` CLI from a terminal. A native **signed**
  .app that reads someone **else's** item (created by another app) will most likely get the system's
  "TokenPace wants to use confidential information…" dialog on first access. That is manageable (the
  user presses "Always Allow" once), but we need to:
  - build the first run into the UX (explain why the dialog appears);
  - **verify in practice**, early on, whether access is silent after the first permission or whether it
    repeats. This does **not depend on the build system** (SPM or Xcode — same thing).
  - Note: this is a question of the item's ACL, not of the `keychain-access-groups` entitlement (that one
    covers only items created by the app itself).
- **Sandbox.** Outside the App Store the sandbox is not required. Should we ever distribute through the
  App Store, the sandbox + access to another app's Keychain item become problematic — to be checked
  separately (one more argument for keeping the menu bar version out of the App Store).
- **Distribution — not decided yet.** For ourselves and the first users — a local build. Options for the
  future: GitHub Releases (.dmg/.app, requires Apple notarization or Gatekeeper blocks it), a Homebrew
  cask (also requires notarization), the Mac App Store (review + the sandbox risk around accessing CC's
  Keychain). The decision is deferred.

## Refresh cadence

### Phase 1 (menu bar)
The agent polls the usage API on its own timer — there are no WidgetKit constraints here. The base
rhythm is **180 s** (the recommendation from source #202: safe when the correct `User-Agent` is present;
TTL cache 180 s). Redraw the menu bar only when the data changes. The interval is **adaptive** —
computed from three axes with a clear priority (the implementation is `PollingEngine`,
[ADR-0011](docs/adr/0011-polling-engine-adaptive-cadence-and-signal-seams.md)):

1. **Backoff on a 429** (highest priority): exponentially `3 → 6 → 12 → 15 min`, hold at 15 min until
   success. It overrides both axes below — it is the server's instruction.
2. **No running Claude Code sessions → 30 min** (a hard override). Without an active session the limits
   barely move, so polling often makes no sense. Detection is by the exact process name `claude` (the
   CLI, not Claude Desktop).
3. **Adaptation by content** (with an active session, no 429): if two consecutive successful polls return
   the same `utilization` (5h or 7d) → double the interval `3 → 6 → 12 → 15 min`; as soon as the data
   changes → snap back to **3 min** to track the movement closely.

**Every decision to change the interval is logged as its own message with a reason** (only on an actual
change — no spam).
- (A 60 s interval was considered earlier, by analogy with the statusline — rejected in favor of 180 s,
  because the statusline polls only during an active session while our daemon runs 24/7.)

### Phase 2 (widgets/complication)
Bounded by what the WidgetKit timeline actually allows (the system schedules it, and the intervals are
not guaranteed to be exact):
- **Free tier:** ~15 min.
- **Premium tier:** ~5 min (if the platform allows).

> Note: without a backend there is **no APNs push** — updates are driven by WidgetKit timeline reloads,
> which the OS schedules. "5 min" / "15 min" are targets, not hard guarantees.

## Monetization

- **Phase 1 (the menu bar app) is entirely free.** No free/premium boundary in the menu bar app: every
  feature (both limits, the per-model breakdown, the service line) is available to everyone.
- **Monetization starts with Phase 2 (the devices).** The goal is a **one-time IAP** unlocking "Premium"
  (a faster widget refresh cadence + premium formats/themes), achievable **without infrastructure of our
  own**.
- **The Mac agent is closed for now.** The open-source question (and the license) is open; we'll settle
  it later — one of the arguments for opening it is trust in how the token is handled.

## Phases

- **Phase 0 — a technical spike (before any product code).**
  - Verify that the `seven_day` block is present in the usage response with the expected structure —
    safe to do right now with a single read-only `GET` on a live token (it invalidates nothing).
    ✅ **Done.**
  - Verify the **fallback refresh** on a *test* Max account. ✅ **Dropped** (ADR-0017): the self-refresh
    was replaced by a delegated refresh through the `claude` CLI — Claude Code performs the rotation
    itself, so no test account is needed. The `claude --model haiku -p '/usage'` command was verified by
    a spike (issue #8): it refreshes without spending limits.
- **Phase 1 — a menu bar app for macOS** (a personal MVP, no App Store, no monetization, no CloudKit):
  the Mac agent (closed for now) with a mini-widget in the menu bar (two pacing bars + the reset time)
  and a dropdown (details for both limits + the per-model breakdown). Locally:
  `Keychain → usage API → menu bar`.
- **Phase 2 — iPhone + Apple Watch:** add CloudKit as the transport (the same Mac agent writes the
  snapshot), a minimal iOS host app + home-screen widgets + a watchOS complication, all reading from
  CloudKit on a shared Apple ID.
- **Phase 3 — public release + monetization:** App Store review, disclosure of how the token is handled
  (privacy), a one-time premium IAP, optional cross-Apple-ID CloudKit sharing.
- **Phase 4 — polish:** more widget/complication formats, themes, localization.

## Open questions

- ~~Whether `refreshToken` is single-use~~ — **closed** (issue #8): yes, it rotates (confirmed by
  studying comparable tools — CodexBar, hunaczech and others document it explicitly). That is exactly
  why the agent does not refresh on its own but delegates to the CLI (ADR-0017).
- **Open source and the Mac agent's license** — closed for now, we'll settle it later (see
  [ADR-0003](docs/adr/0003-agent-closed-source-for-now.md)).
- How to distribute the Mac agent (GitHub Releases / Homebrew / App Store) — deferred.

## Decisions made

- **The Mac agent's language: Swift.** Native access to CloudKit + the Keychain in the same stack as the
  iOS/watchOS app. Go was rejected: CloudKit from Go requires CloudKit Web Services + a server-to-server
  key, and there is no native access to the Keychain.
- **Documentation language: English** — everything in the repository and on GitHub (see
  [ADR-0116](docs/adr/0116-english-as-documentation-language.md), superseding
  [ADR-0002](docs/adr/0002-ukrainian-documentation.md)).
- **Phase 1 = a menu bar app for macOS, without CloudKit.** iPhone/Watch and CloudKit moved to Phase 2.
  The reason: a menu bar app lives on the same Mac as the token, so it needs no transport at all and
  yields a working product by the shortest path.
- **Menu bar UI:** two horizontal pacing bars (5h on top, 7d below) on the left + the time to the
  nearest reset on the right (a single-unit duration: `45m` / `5h` / `4d`). Dropdown: details for both
  limits + the per-model breakdown.
- **A mandatory `User-Agent: claude-code/<version>`** on every request to the usage API + a 180 s polling
  interval with exponential backoff on a 429. The basis is source #202 (the UA quirk: an unknown UA →
  an aggressive rate limit). Note: our own statusline plugin does not send a UA — worth fixing there too,
  to avoid possible 429s.
- **Minimum version: macOS 15 Sequoia.** Audience reach does not matter for a personal MVP, and a recent
  target removes legacy code and workarounds. Lowering the target (should wider reach be needed for a
  public release) is a trivial change with no architectural impact.
- **Menu bar API: `NSStatusItem` (AppKit) with a custom `NSView`/`NSHostingView`.** We need full control
  over drawing the two colored bars, the idle mode, and the item's width. `MenuBarExtra` (SwiftUI)
  limits customization of the label itself — not suitable for nontrivial graphics.
- **Phase 1 build: Swift Package Manager + a build script.** The logic is testable and git-friendly; the
  build script automates assembling the `.app` bundle (the structure + an `Info.plist` with
  `LSUIElement`), `codesign --options runtime`, and notarization (`notarytool` + `stapler`). In
  **Phase 2** an Xcode project joins for the iOS/watchOS targets (SPM does not cover them). See
  [ADR-0004](docs/adr/0004-build-system.md).

## Dev environment status (verified 2026-06-21)

| Component | Status |
|---|---|
| macOS 15.7.8 Sequoia (arm64) | ✅ matches the target |
| Swift 6.1.2 + SwiftPM | ✅ |
| Command Line Tools 16.4 | ✅ |
| `codesign`, `notarytool`, `stapler` | ✅ (in the CLT) |
| git 2.54 / gh 2.95 | ✅ |
| Full Xcode | ❌ absent (CLT only) |
| Developer ID signing identity | ❌ `0 valid identities` |

**Decisions:**

- **Phase 1 is written and run right now** via `swift build` / `swift run` — full Xcode is not needed
  (this confirms the SPM-first choice from ADR-0004).
- **Full Xcode** to be installed **in Phase 2** (for the iOS/watchOS targets).
- **Build unsigned for now** — an unsigned `.app` for personal use (Gatekeeper: "Open anyway").
  Developer ID + notarization will be added at distribution time. Make the build script's signing
  **optional** (sign only if an identity is available).
- ⚠️ **The Keychain risk and unsigned builds:** the Keychain-access dialog may behave differently for an
  unsigned app than for a signed one. Keep this in mind while verifying Phase 1's main risk — the local
  (unsigned) behavior may not match a future signed release.

## Phase 1 scope (MVP)

- **Settings — the minimum:** a launch-at-login toggle plus a Quit item. Everything else is sensible
  defaults (a 180 s interval, local time, the idle mode). No settings screen.
  - ⚠️ **launch-at-login via `SMAppService.mainApp`** works best with a **signed** app. On an unsigned
    build (our personal MVP) registering the login item may be unreliable — we implement it as a "best
    effort", with full reliability expected after signing. The API is confirmed available in the SDK
    (macOS 13+).
- **Tests — unit tests on the logic (XCTest in SPM):** `PacingModel` (the port of `calc_time_pct`/
  `build_progress_bar`/`get_limit_indicator`), parsing `resets_at` (microseconds + TZ), time formatting
  (`hh:mm`/`1h10m`, locale, DST), the backoff logic. The UI (`NSStatusItem`, drawing, idle) is verified
  by hand. The pure logic is isolated from the network/Keychain for testability.

## Phase 0 spike results (confirmed)

`GET /api/oauth/usage` returns these relevant fields:

- `five_hour.utilization` (float, **percent 0–100**, e.g. `0.0`) + `five_hour.resets_at`
  (ISO-8601 with a time zone + microseconds, e.g. `2026-06-21T05:30:00.619428+00:00`).
- `seven_day.utilization` (e.g. `13.0`) + `seven_day.resets_at` — confirmed, the same structure.
- **Per-model limits:** `seven_day_opus`, `seven_day_sonnet` (the same structure) — an opportunity for a
  premium "per-model" breakdown.
- **`limits[]`**: an array of active limits with `kind`, `group`, `percent`, `severity`
  (`normal`/...), `resets_at`, `is_active`. The server already returns a pacing/severity signal — we can
  check it against our own formula. *Update 2026-07-06:* the entries now also carry `scope`
  (`{model: {id, display_name}, surface}`); `kind: "weekly_scoped"` with `scope.model.display_name` is
  the **only** source of model limits that have no top-level field (Fable, for example).
- `extra_usage`, `spend`: information about extra charges in dollars (currently `is_enabled: false`) — a
  hook for showing paid overage in the future.

A parsing note: normalize the microseconds + the `+00:00` suffix in `resets_at` (the statusline does this
with `sed`).

## Work plan

The sequence (agreed):

1. **Docs** — finish the product spec and the documentation (this file, `docs/`). ← the current stage.
2. **Planning + tickets** — cut Phase 1's work into **medium-sized tickets** (1 ticket ≈ 1 component ≈ 1
   session), open them on GitHub with **dependencies** and a **recommended execution order**.
   - The format: an **Epic issue "Phase 1"** + child issues per component (dependencies via "blocked by
     #N"), all collected into a **GitHub Project (board)** for visual progress.
   - **Ticket language: English** (per
     [ADR-0116](docs/adr/0116-english-as-documentation-language.md)).
3. **Execution** — implement the tickets **one at a time, in separate sessions**, in the defined order.

The Phase 1 components in the **recommended execution order** (they will become the tickets):

1. **SPM scaffold + build script** — the package structure, the `.app` bundle, optional
   signing/notarization.
2. **Logging (`os.Logger`)** — cross-cutting, added **at the beginning** so everything else can be
   diagnosed right away (the Keychain dialogs in particular).
3. **`PacingModel`** — the port of `calc_time_pct`/`build_progress_bar`/`get_limit_indicator` + unit tests.
4. **Time formatting** — `resets_at` → local `hh:mm`/`1h10m` (DST) + unit tests.
5. **`TokenProvider`** — reading the Keychain + the fallback refresh (the main risk — check it early).
6. **`UsageClient`** — requests to the usage API (the mandatory `User-Agent`, backoff). Depends on #5.
7. **`StatusItemView`** — `NSStatusItem` with custom bar drawing + the idle mode. Depends on #3, #4, #6.
8. **Popup** — limit details, the per-model breakdown, the service line. Depends on #7.
9. **Error states** — the crossed-out antenna after the `max(15 min, 3 × pollInterval)` threshold
   ([ADR-0091](docs/adr/0091-countdown-only-where-work-is-not-running.md)), a warning in the popup
   immediately. Depends on #7.
10. **Sleep/wake + network** (`NSWorkspace`). Depends on #6.
11. **launch-at-login** (`SMAppService`, best-effort on unsigned) + Quit. Depends on #1.

The exact dependency graph is in the Phase 1 Epic issue and `docs/architecture.md`.
