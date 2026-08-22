---
status: accepted
date: 2026-08-22
supersedes: []
superseded_by: []
---

# ADR-0121: GitHub as a status-only provider — one group, two plates, and a dot that only appears while calm

> Narrows §6 of [ADR-0024](0024-configurable-logical-services.md) — "status lines appear only on a
> real problem" and "no aggregation in the popup" — for **section headers only**; §1's logical-service
> model is generalised, not replaced. Extends [ADR-0094](0094-provider-row-brand-badge.md) §4 with the
> rule that follows from a *second* provider existing. Consumes the per-source seams built by
> [ADR-0119](0119-status-polling-own-cadence-and-backoff.md) and the journal's provider tag from
> [#456](https://github.com/artem-from-ua/tokenpace/issues/456). The menu bar's "silence means fine" rule
> ([ADR-0013](0013-claude-status-line.md) §8) is **untouched**.

## Context

TokenPace answers one question when something breaks: *is it me, or is it them?* Until now it could
only answer it for Claude. A `git push` that hangs, a `gh pr create` that 500s, a PR page that will
not load — same class of interruption, same workflow, no answer.

GitHub runs the same Statuspage v2 schema Anthropic does, so `StatusSummary` decodes both without a
second decoder, and `ServiceStatus` / `ResolvedComponent` / `ServiceCheck` carry no Claude-specific
semantics. What was Claude-specific: the component-name constants, the `ServiceID` enum, the config
types, the popup's single hard-coded section, and — the real machinery — the poll cadence, which
[ADR-0119](0119-status-polling-own-cadence-and-backoff.md) built out separately for exactly this
reason.

**GitHub has no usage half, and none is planned.** GitHub publishes no subscription limit that
TokenPace's bars model. That asymmetry is not a gap to be closed later; it is what makes this
provider a different *shape* from Claude, and every decision below follows from it.

**The provider is off by default** — the one monitoring flag in the app that is opt-in rather than
opt-out. Not everyone using TokenPace works against GitHub, and a provider that appears on upgrade
and starts polling a third party, or puts a new dot in someone's menu bar, has made a behaviour
change on the user's behalf rather than offered them a feature.

## Decision

### D1. One logical service, `Development services`, not five switches

Five components under a single toggle, aggregated worst-of-5: `Git Operations`, `API Requests`,
`Issues`, `Pull Requests`, `Actions`.

Claude has two-or-three services because its components answer genuinely different questions — the
API behind an agent, the CLI, the web app; a user can plausibly care about one and not the others.
GitHub's five do not split that way. They answer **one** question — "is my development workflow
working" — and the paths into them are entangled: `gh pr create` is `API Requests`, the PR page it
prints a link to is `Pull Requests`, the CI it kicks off is `Actions`, and the `git push` that
preceded all of it is `Git Operations`. Splitting them into switches would ask the user to classify
an outage **before** knowing what broke, which is the one moment they cannot.

Per-component switches would also be a promise the popup does not keep: the rows already name which
component is down. The group answers "is it them", the rows answer "which part" — one toggle, five
rows, no configuration in between.

`Copilot`, `Copilot AI Model Providers`, `Packages`, `Pages` and `Codespaces` are **not** monitored. A
`Copilot services` group is the plausible next member, which is exactly why `GitHubMonitoring` is a
struct rather than a bare `Bool` — a second group lands as a new key with a default, not as a second
unrelated key beside a loose flag.

The feed also carries a non-service row literally named `Visit www.githubstatus.com for more
information` (`operational`, always). Matching is by **exact** component name, so it is never selected
and needs no filter. The stub carries it deliberately, so the next reader does not "fix" its absence.

### D2. The header dot appears **only** while the provider is calm

`PopupViewController.headerDot(for:)` returns a dot for `operational` and for nothing else. Not for
`degraded`, not for an outage, and — deliberately — not for `unknown`.

**Why a header dot exists at all.** GitHub is status-only. In the calm state its plate would be the
word `GitHub` followed by nothing: no bars, no rows (they are hidden while healthy), no age. That is
indistinguishable from a plate that failed to load, and it fails the "is there an action the user
would take differently" test in [users-and-goals.md](../reference/users-and-goals.md) — the user
cannot tell *watched and healthy* from *not working*. Claude never had this problem because the bars
above its section keep the popup populated whatever the status says.

**Why only while calm.** The first implementation drew the dot in every state, and that was the
weaker version. The moment anything is wrong, the rows appear — each with its own dot, each **naming
the service it belongs to**. A header dot above them restates, less precisely, what the rows already
say: it is a worst-of-5 sitting on top of the five values it was computed from. So the rule inverts:
the dot exists to answer the state where the rows are hidden, and it goes away the moment they are
not.

**`unknown` is not an exception.** A failed poll greys the components and *puts rows on screen*, so
the same reasoning applies and the header stays bare. Nor is "before the first poll": `nil` aggregate
yields no dot, because "we have not looked yet" is a different statement from "we looked and could
not tell", and a grey dot would claim the latter.

**Consequence: no dot, no reserved column.** With no dot the title sits flush left rather than behind
a hidden indent. The service rows *do* reserve that column — their names line up under one another
whatever each row's dot is doing — but a header is not one of a set, it is the thing the set hangs
from, so an empty indent under it reads as a missing mark rather than as alignment. With the dot
limited to the calm state, that reserved gap would also have been the common case. When the dot *is*
present it uses the rows' own gap and nudge, so every dot in the popup lands on one vertical line.

**The dot is a real `GlowDotView`, not a text attachment.** The first version was an attachment inside
the header's attributed string — flat, no glow — sitting above a column of glowing dots, and it read
as a different kind of mark. It now wraps the title stack in a `.centerY` row instead of joining the
`.firstBaseline` one, because a fixed-size view in a baseline-aligned stack lands on the text
baseline rather than the optical centre.

### D3. Why this is a scoped departure from ADR-0024 §6, and a narrow one

ADR-0024 §6 says two things this touches:

- **"Status lines appear only on a real problem."** That forbids a line that is *permanently visible
  while healthy*, which is a claim about clutter: a row that says "fine" every time you open the
  popup teaches you to stop reading it. What is visible here is a single dot that exists **only**
  while healthy and vanishes the moment there is anything to read — the inverse of the shape the rule
  guards against. And it exists because a status-only provider has nothing else on its plate to show
  it is being watched; Claude's section, which has bars above it, still hides itself completely on a
  calm state and this record does not change that.

- **"One line per component, no aggregation in the popup."** A worst-of-5 header dot *is* aggregation.
  The rule's purpose is that the popup must not hide *which* component is broken behind a summary —
  and it does not: the moment a component is non-operational, its own row appears, and the aggregate
  dot disappears. Aggregation is visible **only** in the state where there is nothing to aggregate,
  because every constituent is `operational`.

The departure narrowed during implementation rather than widened, which is the reason it is recorded
as a scoped exception and not as a supersession. It applies to popup **section headers** and to
nothing else.

### D4. Green joins the dot's vocabulary in exactly one position

[bar-status-conditions.md](../reference/bar-status-conditions.md) documents the dot scale as
`gray → yellow → orange → red` — no green, because the menu-bar dot vanishes on a calm state and
green never had anywhere to be drawn.

The colour is **`ColorRole.green`**, and it is not new. `PopupViewController.dotColor(_:)` has mapped
`.operational` to it since #341, when the services-only mode gave the popup an "All services · fine"
row under ⌥; the Legend page has listed `operational` among its six service states since
[ADR-0110](0110-legend-is-a-static-page-rendered-by-the-live-code.md) — that page names the whole
`ServiceStatus` vocabulary, not only the states the menu bar draws. So:

- **The Legend needs no change.** Green is already there, already sourced from the same
  `ColorRole.green` through the same `dotColor` arithmetic, and the Legend page is rendered by the
  live code precisely so it cannot drift. What this record adds is a *surface* on which that colour is
  drawn, not a value.
- **`bar-status-conditions.md` does need one**, because that document describes the scale as it is
  drawn, and the scale as drawn now reaches green in one position: a popup provider-header dot on a
  calm provider. Updated in the same commit as this ADR.

The menu-bar scale is unchanged. Silence there is still a complete answer to "can I work", and this
record does not touch it.

### D5. Two plates, not two sections on one plate

The first attempt appended GitHub's section to the shared stack, inside Claude's `CardBackdropView`.
Two providers on one piece of glass read as **one subject with a subheading**, and the component names
cannot correct that impression because they never say whose they are — `Actions` and `Issues` are as
plausibly Claude's as GitHub's.

The plate is what says "one provider". GitHub gets its own `CardBackdropView` with its own stack,
between Claude's plate and the ⌥ caption, so the native action items that appear under ⌥ stay below
both: the reading order is providers first, then what you can *do*. When the provider is off the plate
collapses to zero height and the popup ends at Claude's card exactly as it did before this feature
existed.

The same argument settles three follow-on questions:

- **Each plate renders only its own incidents.** An incident row deliberately does not name the
  services it affects ([ADR-0071](0071-incident-subscriptions.md) §3), so the header above it is the
  only attribution there is — concatenating the lists put a GitHub incident under the `Claude` header,
  visible on screen as the same row twice.
- **The subscribe control sits beside its cause**, on whichever plate has an incident of its own —
  both plates when both do. Either toggles the same, **app-wide** subscription: following an episode
  means "tell me when the current trouble is over", and that question does not split by whose status
  page it came from. Two controls for one state is the accepted cost of putting the control where the
  reason is; a single row on Claude's plate would sit under a provider that is fine and read as an
  offer to follow its silence. A UI refinement can revisit the duplication; the attribution cannot
  wait.
- **A calm plate under ⌥ shows nothing.** Claude's plate answers "No ongoing incidents" in that spot,
  but only because its section is on screen *because* something is wrong — there a blank dimension
  would read as a glitch. This plate is on screen whenever the provider is monitored, so a calm
  provider under ⌥ has nothing to report, and the header's green dot has already answered it.

Under ⌥ the GitHub header carries the same `· updated …` tail Claude's does — word for word, same
separator, same duration format, because it answers the same question about a different provider. The
number is **GitHub's own** poll age, which is the whole reason it is a separate field: the two poll on
independent cadences, so one age standing for both would be a quiet lie.

### D6. One glyph for every provider badge — `cloud.fill` on the brand colour

[ADR-0094](0094-provider-row-brand-badge.md) §4 puts it as "colour belongs to the brand, shape belongs
to the system". With one provider that was a rule about avoiding a logo. With two it becomes a rule
about what the *shape* means: every row in the Providers list is the same kind of thing — a service
TokenPace watches over the network — so the shape is the **category**, and only the colour is the
identity.

A per-provider glyph would make shape carry identity too, duplicating the job colour already does, and
would leave a reader deciding whether a branch and a cloud differ in *kind* or only in *vendor*. It is
also the seam where a logo eventually gets proposed ("a branch is nearly the Octocat…"); a shared
category glyph closes that door by construction.

**Two roles for GitHub's black, on measurement grounds.** `ColorRole.githubBrand` is pure `#000000`
for the Settings badge, where ADR-0094 §7's derived gradient lifts the far end to `#606060` — the
ADR's own arithmetic, not a fallback. The popup's header mark cannot use it: black ink on the
dropdown's dark material is unreadable. So `ColorRole.githubBrandInk` carries the identity there and
resolves per appearance (`#1F2328` on light, `#E6EDF3` on dark). Both are fixed sRGB literals for the
reason `claudeBrand` is: a semantic colour would invert with the appearance and destroy the only thing
a brand mark says. The values are a measurement question and were checked with Digital Color Meter in
sRGB, not by eye.

### D7. Its own everything: loop, backoff, health slot, incident list

ADR-0119 built the per-source shape; this is the second source that occupies it. GitHub gets its own
`LivePollScheduler` on its own `SignalHub.Subscriber` key, its own `PollingBackoff`, its own
last-success marker and its own in-flight task. Nothing is shared, which is the point: a `429` from
`githubstatus.com` holds only this source, an unreachable GitHub greys only its own rows, and a Claude
incident cannot drag this poll to the 60-second problem floor against a third party's page — hence
`StatusHealth.worstProblem(of:)` beside the flattened `worstProblem`, per-provider, feeding the cadence
per source.

`usageInterval` is always `nil` here: this provider has no usage poll to settle with, which is the case
ADR-0119 made the parameter optional for. `User-Agent` is `TokenPace/<version>`, never
`claude-code/<version>` — that string is correct for Anthropic's page and misleading anywhere else.

**The loop polls once before its first wait.** `waitForNextPoll` sleeps the whole interval up front, so
a loop that waits first would leave the plate empty for the five-minute politeness floor after every
launch — a monitored provider showing nothing, which is exactly the state D2's dot exists to rule out.
Claude never had this problem because its status also rides the usage tick; this source has no second
heartbeat to cover for it.

**The two healths merge at render time**, not into one stored value. They arrive on independent
cadences, so a stored merge would be rewritten by whichever poll landed last and the loser's checks
would flicker out until its own next poll. `merging(_:)` *replaces* a provider's checks rather than
accumulating them, which keeps it idempotent and keeps display order fixed (Claude first) regardless of
who polled last.

**`isMonitoringAnything` now spans providers.** `ProviderMonitoring`'s property of that name answers
only for Claude — it is `claudeApiLocked` under another name. Reading it as the app-wide answer was
correct while Claude was the only provider and becomes a lie the moment a second one can be enabled
alone: the popup would draw its "Monitoring is off" dead end over a live GitHub plate, and the menu bar
would show the nothing-monitored glyph during a GitHub outage.

### D8. Settings: `Providers › GitHub`, half of Claude's page

A second row on `ProvidersPane` drilling into `ProvidersGitHubPane` — the axis of growth that page was
shaped for in [#341](https://github.com/artem-from-ua/tokenpace/issues/341)
([ADR-0084](0084-settings-drill-in-child-pages.md)).

The page carries **only** a `Monitored services` section with the single `Development services`
toggle. No `Token limits usage` section, because there is no usage half. No provider-level master
switch either: on Claude's page such a switch would have to mean either "collect usage" or "watch
services" and whichever it meant the other would be the surprise; here the question does not arise
because with a single service the service switch **is** the provider switch, and a second control above
it would be the same state written twice.

`GitHubMonitoring` persists under its **own** `PersistedConfig` key, never inside the `monitoredServices`
blob — the rule that key already states, and more so here: a different provider folded into Claude's
blob would inherit Claude's invalidation as well as its downgrade hazard. Two keys survive a downgrade;
one blob does not.

### D9. Notifications and the journal ride the existing mechanisms

GitHub incidents flow through the **existing** episode-subscription and banner machinery with **no
toggle of their own**: enabling the provider makes its incidents behave like every other monitored
service's. That is what the concatenated incident list is for — it has exactly one legitimate reader
(the subscription and the notifications it drives, where the provider does not change what the banner
says), and the popup is deliberately not it.

Incidents are filtered against **each provider's own** monitored names, never a crossed set: a generic
name like `Issues` exists on both pages and would otherwise match across providers.

Journal records carry the provider tag from
[#456](https://github.com/artem-from-ua/tokenpace/issues/456); this record only writes GitHub polls
with it already set. `ProviderID`'s raw values are stable
snake-case strings for that reason — they outlive any build, like `ServiceStatus`'s journal spelling.

## Consequences

- The popup can now be **two plates tall** with the bars off entirely (services-only mode plus GitHub),
  which is a taller resting state than the popup has ever had. Measured and accepted; the plate
  collapses to zero when the provider is off, so the default install is byte-for-byte unchanged.
- **Two subscribe controls can be on screen at once**, both driving one state. Recorded as an accepted
  cost in D5, and the first thing to revisit if it reads as a bug rather than as attribution.
- `worstProblem` (flattened, for the menu bar) and `worstProblem(of:)` (per-provider, for the cadence
  and the header) now both exist, and picking the wrong one is a silent bug in either direction. The
  doc comments on both name their single correct consumer.
- **Two short poll loops rather than one parameterised one.** `pollGitHubIfDue` is a near-twin of
  `pollStatusIfDue` and deliberately not folded into it: the two differ in every input that matters —
  endpoint, User-Agent, config type, backoff, success marker, health slot — so a shared implementation
  would be a parameter list as long as the body, threading a provider through every line. Two loops
  that each read straight through is the cheaper shape until a third provider proves otherwise.
- A **third** provider is now a mechanical addition on the kit side (a `ProviderID` case, a component
  list, a config struct) but **not** in the popup, which hard-codes two plates. That is the honest
  boundary of this record: it makes "a second provider" work rather than "N providers".

## Rejected

- **Per-component switches for GitHub's five.** Asks the user to classify an outage before knowing what
  broke (D1); the rows already answer "which part".
- **A header dot in every state.** The version this ADR started from. It restates the rows below it
  less precisely, and it is the version that genuinely conflicts with ADR-0024 §6 rather than scoping
  around it (D2).
- **A grey `unknown` dot to hold the column before the first poll.** It claims we looked and could not
  tell, which is a different statement from "not yet" — the same honesty `ServiceStatus.unknown` exists
  to protect.
- **One plate with two sections.** Reads as one subject with a subheading, and the component names
  cannot correct it (D5).
- **A single subscribe row on Claude's plate.** Sits under a provider that is fine and reads as an offer
  to follow its silence (D5).
- **A per-provider badge glyph.** Makes shape carry identity, duplicating colour's job, and opens the
  door to a logo (D6).
- **Hiding a calm GitHub plate entirely**, as Claude's section hides itself. It makes an enabled
  provider identical on screen to a disabled one, which is the exact question the feature exists to
  answer.
- **A GitHub usage/rate-limit half** (`gh api rate_limit`, a second bar, a `Token limits usage`
  section). Recorded so nobody later completes the symmetry: GitHub has no subscription limit that the
  bars model, and inventing one would draw a quantity that does not exist. Also no GitHub
  authentication — the status endpoint is public, and TokenPace reads no token, no repo, no user data
  for this feature.
