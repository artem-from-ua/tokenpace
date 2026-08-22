---
status: superseded
date: 2026-06-23
superseded_by: [0024, 0071, 0119]
---

# ADR-0013: Claude services status line in the popup (status.claude.com)

> **Superseded in scope by** [ADR-0024](0024-configurable-logical-services.md): "exactly two
> fixed components, `Claude Code` + `Claude API`" was replaced by configurable logical services
> (issue #89). The rest of the decisions below (state source = `component.status` only, incidents
> not decoded, cadence floors, pure core / thin shell) **still stands** and is reused by ADR-0024.
>
> **§2 was additionally revisited by** [ADR-0071](0071-incident-subscriptions.md) (draft):
> `incidents[]` is **now decoded** — but only as *context* and a *subscription object*. The core of
> §2 **still stands**: the source of a service's state remains exclusively `components[].status`;
> no incident field (`status`, `impact`, `resolved_at`) affects the state.
>
> **§7 was revisited by** [ADR-0119](0119-status-polling-own-cadence-and-backoff.md) (#455). The
> *requirement* it recorded — a separate, polite cadence, never a copy of the usage cadence, never
> sharing the usage 429 backoff — **still stands and is now literally true**. What no longer holds is
> the *mechanism*: the status loop no longer rides the usage tick. It runs on its own
> `LivePollScheduler`, `usageInterval` became an optional input that may only slow polling down, and
> the loop holds a `PollingBackoff` of its own — one per status source — fed by a new
> `StatusFetchError.rateLimited(retryAfter:)`. Where §7 says the status poll has no timer, read
> ADR-0119 §D4.

## Context

Issue #31 adds a service-status line to the popup, sourced from
[status.claude.com](https://status.claude.com). The goal is to answer the user's question "my
Claude Code is lagging — is that me (limit/network) or Anthropic?": the popup already shows
everything about usage, and the other half — the state of the services themselves — was missing.

The source is Statuspage.io's JSON endpoint,
`https://status.claude.com/api/v2/summary.json`, which returns `status` (overall `indicator`/
`description`), `components[]` (`name` + `status`: `operational` / `degraded_performance` /
`partial_outage` / `major_outage` / `under_maintenance`), `incidents[]` (`name`, `status`,
`impact`, `components[]`), and `scheduled_maintenances[]`.

This is the same class of module-boundary decision as in
[ADR-0008](0008-usageclient-pure-backoff-and-transport-seam.md),
[ADR-0010](0010-usage-health-and-error-states.md),
[ADR-0011](0011-polling-engine-adaptive-cadence-and-signal-seams.md): where parsing/mapping lives,
how to make it testable without a live network, and how to layer a **second** data source without
coupling it to usage polling.

1. **Which components are relevant to the console Claude Code.** The ticket asked for this to be
   researched. `Claude Code` is the CLI product's infrastructure (login, updater, model routing);
   `Claude API (api.anthropic.com)` is the inference backend every CLI request goes to (`5xx`/
   `429`/`529` errors in the CLI mean degradation of that component specifically,
   [docs](https://code.claude.com/docs/en/errors)). The rest (`claude.ai`, `Claude Console`,
   `Claude Cowork`, `Claude for Government`) is not directly relevant to the console CLI.
2. **State signal vs. incidents.** Verified manually: a component and an incident can disagree —
   both of our components can be `operational` while an active `major` incident lists them in
   `components[]` (a real case: the suspension of access to Mythos 5 / Fable 5). We need to decide
   which one is the source of truth for the line.
3. **Cadence.** This is a **different** source than the usage API. The ticket explicitly required
   "a separate, **polite** interval — not to be confused with the usage cadence." Status.claude.com
   is a third-party service.

## Decision

1. **Scope — two components: `Claude Code` + `Claude API (api.anthropic.com)`.** Either can go
   down independently (broken login/routing with a working API, or vice versa), so both are
   relevant to answering "is this Anthropic." They're pulled by **exact name** from `components[]`;
   a missing component (Anthropic renamed or removed it) becomes `unknown`, not a silent
   `operational`.

2. **State source — EXCLUSIVELY `component.status` for these two components. Incidents / overall /
   scheduled_maintenances are NOT decoded at all.** This is deliberate and has three benefits:
   (a) it matches the color Statuspage shows next to the component on the page itself; (b) it
   automatically hides "known exceptions" like the Mythos/Fable suspension — a `major` incident
   while the components stay `operational`, so the popup shows `operational` with no special case;
   (c) it keeps `StatusSummary` narrow (a single `components` field), with no code around
   incidents. `Decodable` ignores unmodeled keys for free.

3. **Appearance — always two independent lines, one per component, with a colored dot indicator.**
   No aggregation into an "overall," no collapsing: `● Claude Code: operational` / `● Claude API:
   operational`. The dot's color equals that specific component's status
   (`green/yellow/orange/red/blue/gray`). The `status → dot + word` mapping lives in the view
   (`PopupViewController`, the localization point, ADR-0009); `CCTimerKit` carries only the
   semantic `ServiceStatus`.

4. **The status word is a clickable link to `https://status.claude.com`, but ONLY when the state is
   not `operational`.** On an operational line, the word is plain secondary text with no link
   (there's nothing to look at on the status page); on any degradation/maintenance/unknown, the
   word becomes a link to the static home page (not an incident shortlink — we don't parse
   incidents). A click opens the browser. Since `NSTextField`'s `.link` handling is unreliable
   inside an `NSMenu`-hosted view, the click is handled explicitly (`StatusLineLabel.mouseDown`
   over the word's range, plus a hand cursor only when a link is present).

5. **Cold start → no lines shown; our fetch failing → both `unknown` (gray dot).** Until the first
   successful response arrives, the status lines are not shown (`serviceStatus == nil`). If our
   request to the status page fails (network/decode), the shell substitutes `StatusHealth.unknown`
   — an honest "we don't know," not a false `operational`. The UI for "the service is unknown" and
   "we failed to find out" is the same, so the type carries no separate failure field.

6. **Pure core in `CCTimerKit` + thin glue — mirroring `UsageClient`/`UsageHealth`.**
   `StatusSummary` (Decodable), `ServiceStatus`/`StatusHealth` (semantic mapping, no localized
   strings), `StatusClient` (`buildRequest`/`decode`/`fetch`, reusing the `UsageTransport` seam,
   the mandatory `User-Agent: claude-code/<version>`). The HTTP request and the timer live in the
   shell. Tests substitute a stub transport and a `summary.json` fixture (with an incident inside —
   to prove extra keys are ignored).

7. **Cadence is tied to the usage tick with a politeness floor, rather than its own timer.** The
   status interval equals `max(floor, current usage interval)` (`StatusCadence.interval`). On every
   `PollOutput`, the shell asks `StatusCadence.isDue(...)` and fetches only when it's due. So status
   **follows** usage when usage slows down (idle/inactivity → 30 min, both quiet down together),
   but **never** more often than `floor`, even when usage is polling every 60 s or in 429 backoff —
   that's the "politeness" toward a third-party service. Status has **no** backoff of its own for
   429s and does **not** affect usage cadence: `StatusFetchError` is caught in the shell and never
   escalates usage polling.
   **Two floors:** `floor = 5 min` when everything is operational; `problemFloor = 60 s` (our
   general `minInterval`) as soon as any component is **not** operational — during an incident the
   page is worth watching closely (escalation/recovery happen on a minute-scale), so the floor
   drops to catch a change quickly. `isDue(... hasProblem:)` receives this flag from the last known
   state.

8. **The colored indicator in the menu bar — the widget's leftmost element, shown only on a
   problem.** `StatusHealth.worstProblem` returns the more severe of the two components' states
   (severity order: operational < maintenance < unknown < degraded < partial < major) or `nil` when
   both are operational. `MenuBarLayout` carries this as `serviceProblem: ServiceStatus?`
   (orthogonal to `mode`); `StatusItemView` draws a small colored dot to the left of the
   strips/glyph, shifting the rest right. `nil` (everything OK / cold start) → no dot. The color is
   fixed sRGB (a non-template image): yellow/orange/red/blue/gray. `unknown` also shows a dot
   (gray) — honestly signaling "we don't know" rather than hiding the state.

## Consequences

- `CCTimerKit` stays free of AppKit/Network: `StatusSummary`/`ServiceStatus`/`StatusHealth`/
  `StatusCadence`/`StatusClient` operate only on semantics and `Foundation`; the platform side
  (`URLSession`, timing) lives in `cc-timer`. Mapping and cadence are covered by unit tests
  (`StatusHealthTests`, `StatusClientTests`, `StatusCadenceTests`); the status line and its link
  are verified end-to-end via `CC_TIMER_STUB=1` (the stub returns a degraded API plus an incident —
  showing a yellow dot and proving the incident is ignored).
- The two data sources are orthogonal: usage polling (ADR-0011) and status polling share the
  `SignalHub` rhythm (status piggybacks on the usage tick), but have separate states, separate
  error handling, and independent cadence floors. A failure in one does not affect the other.
- If Phase 2 needs to show incidents, history, or status in the menu bar (not just the popup) —
  that is a new decision → a new section here or a separate ADR. The current scope is deliberately
  minimal: per-component `status` only.

## Related

- [ADR-0008](0008-usageclient-pure-backoff-and-transport-seam.md) — `UsageClient`/`UsageTransport`; `StatusClient` mirrors its structure and reuses the transport seam.
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — pure core / thin shell, localization in the view; the status line follows the same split.
- [ADR-0010](0010-usage-health-and-error-states.md) — `UsageHealth`/`FailureReason`; `StatusHealth` is its analog for the status domain.
- [ADR-0011](0011-polling-engine-adaptive-cadence-and-signal-seams.md) — usage polling, from which status takes its heartbeat and current interval.
