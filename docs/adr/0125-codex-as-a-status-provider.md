---
status: accepted
date: 2026-08-24
---

# ADR-0125: Codex as a status provider — statuses from the component feed, incidents from the page's own backend, and an age that is never invented

> Consumes the per-source poll seams from [ADR-0119](0119-status-polling-own-cadence-and-backoff.md)
> and follows the provider shape [ADR-0121](0121-github-as-a-status-only-provider.md) established:
> a plate of its own, a page of its own, a loop of its own. Extends
> [ADR-0094](0094-provider-row-brand-badge.md) §4 with a third brand colour under the same shared
> glyph, and writes its polls with the journal's provider tag from
> [ADR-0120](0120-status-records-carry-their-provider.md).

## Context

Codex is the third provider TokenPace watches and the first with **both** halves — a public status
page and a subscription quota. This record covers the status half only; the quota is a separate
ticket with a separate collector.

Everything below rests on captured live bodies rather than on the documentation, because the
documented endpoints turn out not to answer the questions the popup asks. Four measurements decided
the design:

| Endpoint | Components | Has `CLI`? | Incidents | `affected_components` |
|---|---|---|---|---|
| `/api/v2/summary.json` | 25 | **no** | key absent | — |
| `/api/v2/components.json` | **34** | yes | — | — |
| `/api/v2/incidents.json` | — | — | 25 | **`null` on every one** |
| `/api/v2/incidents/unresolved.json` | — | — | **404** | — |
| `/proxy/status.openai.com/incidents` | — | — | **93** | **populated in 86** |

GitHub was a mechanical addition on the kit side because it runs the same Statuspage v2 schema
Anthropic does. Codex runs that schema too — and it is the *contents* under the schema, not the
schema, that make it a different problem.

**A third provider is also the point at which "which one is first" stops being obvious.** With two,
display order was a pair of `if`s and one `allCases.firstIndex`. Reading order out of the case
declaration list works only while the two lists happen to agree, and the case list is not free to
change: `ProviderID`'s raw values are journal-stable strings, so the enum is archive identity.

## Decision

### D1. Statuses come from `components.json`, never from `summary.json`

`summary.json` is **structurally** truncated, not transiently short: its components run `position`
0–24 contiguously, and `CLI` — one of the five services this provider exists to report on — sits at
29. No retry, no later capture, and no schema change on our side makes it appear there. Measured at
25 components against 34.

That is the whole argument, and it is worth stating because `summary.json` is the endpoint every
other provider here uses and the one a later reader will reach for. `StatusSummary` decodes
`components.json` unchanged — `init(from:)` hardens both arrays to `[]` and `Decodable` drops the
keys it does not know — so the cost of the different endpoint is one URL, not a second decoder.

### D2. Incidents come from the page's own frontend backend, and the price is degradation

`/api/v2/incidents.json` reports `affected_components: null` on **every** incident it carries (25 of
25, measured). It therefore cannot answer "is this incident mine", which is the only question the
popup asks of an incident: `IncidentVisibility` drops an incident whose components do not intersect
the monitored set, and an incident that names no components cannot pass a filter it carries no data
for. `unresolved.json` 404s.

`/proxy/status.openai.com/incidents` is the only source that says which components an incident
touched. Verified against a live capture: 93 incidents in one request, 86 with a populated
`affected_components`, **every** `component_id` resolving against `components.json` (zero unknown),
and the filtering exact — 21 incidents touch a Codex component, "Elevated Codex API authentication
errors" resolves to `Codex API` alone, and an incident about `Sora` never reaches the Codex plate.
It answers 200 without a cookie and without a browser User-Agent; a plain `TokenPace/<version>` gets
the same bytes, so nothing here impersonates a browser.

**It is undocumented, and the cost is named rather than waved away.** It may change shape or
disappear without notice. So:

- **A failure degrades, it does not propagate.** The statuses come from a *different request*, so an
  unparseable or unreachable incident feed costs the Codex incident rows and nothing else — the dots
  and the service rows keep rendering. A shape change takes the same path as an outage: the decoder
  throws `StatusFetchError.decode` and the poll continues.
- **Success is never silent about which path it took.** `codex incidents source=proxy` /
  `source=unavailable` is logged on every change, so a capture distinguishes a degraded run from a
  quiet day with no incidents.
- **Its own decoder, not a widened `StatusIncident`.** The shapes differ in nearly every key that
  matters: `published_at` for `created_at`, `to_status` for `status`, a rich-text `message` object
  where Statuspage has a plain `body`, `affected_components[].component_id` where Statuspage nests a
  component array, and two arrays with no Statuspage analogue. One type over both would leave every
  field optional and every reader guessing which feed it came from.
- **A vocabulary of its own.** This page says `full_outage` where Statuspage says `major_outage`
  (measured: `full_outage` appears in the feed and `major_outage` never does). `ServiceStatus`'s
  shared mapper would bucket it to `.unknown` — visibly *milder* than an outage, on exactly the
  incidents that matter most — so the proxy's word is mapped before the shared seam sees it.
- **Its own, slower request.** Roughly half a megabyte per poll, and its body is never journalled.

### D3. `components[].updated_at` is not read, and the age comes from three ranked sources

On this page `updated_at` is **identical on all 34 components** — one distinct value against 19
distinct `created_at`, measured. It tracks the page's last edit, not a status change. Passing it
through would render an age measured from an unrelated event: a two-hour outage would read as
"46d", and `isRecentlyRecovered` — which is what puts a just-fixed component back on screen — would
never fire.

So the key is not read at all, and the age comes from, in order:

1. **`component_impacts[].start_at`** from the incident feed, per component, counting **open**
   impacts only. A closed impact describes a state the component has already left, so dating the
   current state from it would be wrong. This is a server timestamp, so it survives a relaunch and a
   fresh install — the same property that made Claude's `updated_at` the right source there.
2. **Reconstruction from the journal**, when the incident feed has no open impact. The source is
   already written: every `status` line carries `t`, its `provider`, and `svc` — the whole feed with
   names and raw statuses. Walking back from the newest line while a component reads the same status
   gives the first poll that saw it.
3. **Nothing.** The row shows no age.

The reconstruction's limits belong in the record, because a number that looks precise invites
trust it has not earned: **resolution is the poll cadence** (five minutes at the politeness floor,
never better); **a fresh install has no history** and yields no age rather than an age of zero,
which would claim the component had just changed; and **depth is the journal's retention** — a
status held longer than the record is deliberately *not* dated to the record's oldest line, which
would report the retention window's edge as a change that never happened. The age is honest or
absent, never fabricated.

### D4. Five logical services, one per component — and `Login` is excluded

`Codex API`, `CLI`, `VS Code extension`, `Codex Web`, `Codex in ChatGPT Desktop`, each its own
switch and its own row.

This is the opposite of the call [ADR-0121](0121-github-as-a-status-only-provider.md) §D1 made for
GitHub, and for a reason that inverts cleanly. GitHub's five answer **one** question through
entangled paths — `gh pr create` is `API Requests`, the page it prints is `Pull Requests`, the CI it
starts is `Actions` — so splitting them would ask the user to classify an outage before knowing what
broke. Codex's five are genuinely different **surfaces**: someone running `codex` in a terminal and
someone in Codex Web hit different failures, and "CLI red, Web green" is an action — switch to the
web one — rather than noise. Exact `component_id` attribution makes the finer split free in code, so
nothing is paid for the granularity.

**`Login` is monitored by neither, and cannot be.** The feed lists it **twice**, under two different
ids at positions 3 and 27. Matching is by name (the single identity axis ADR-0013 §1 chose), so an
exact-name match resolves to whichever copy the array happens to list first — an arbitrary answer
that would look authoritative. Said out loud on the Settings page too, so its absence reads as a
decision rather than an oversight.

### D5. Display order becomes explicit, and every ordering site routes through it

`ProviderID.displayOrder` — Claude first, then the rest sorted by `displayName` — with
`displayIndex` as the comparison key. The merge sorts by it, the popup builds its satellite plates
from it, and the Settings Providers list is **generated** from it rather than hand-listed.

**Not `allCases`.** That order is the case-declaration order, and the case list is archive identity:
the raw values are journal-stable snake-case strings, so a case appended later must not be able to
reorder the screen. Today the two orders genuinely differ (`claude, github, codex` declared;
`Claude, Codex, GitHub` drawn), which is what makes the separation load-bearing rather than
decorative.

Claude is pinned first rather than sorted, and that asymmetry is real: it owns the usage bars, so its
plate is the popup's main stack and every other provider gets a satellite card below it. The rest is
alphabetical because nothing else distinguishes them — a status-only provider has no claim to be
second.

Generating the Settings rows is the part worth naming. A hand-written row is what gets forgotten
when a provider is added, and a missing row is a feature nobody can reach.

### D6. `CodexMonitoring` declares the quota switch before anything reads it

Five service flags, all default **on**, plus `usageEnabled` at default **false** — declared now,
with no collector behind it, so the `Codable` shape does not change twice.

**The asymmetry is the decision, not an oversight.** Watching a status page is an HTTP GET against a
public URL; reading the quota spawns a process on the user's machine. That is a different class of
action and should be asked for. ADR-0121's argument — that a monitor nobody enables reports nothing,
which is the same as not shipping it — is answered differently here rather than ignored: onboarding
([#291](https://github.com/artem-from-ua/tokenpace/issues/291)) detects an installed `codex` with
credentials and offers to turn it on, so the feature is proposed at the moment it is visibly
applicable instead of hiding in Settings.

Its **own** `PersistedConfig` key, never folded into another provider's blob — the rule
`GitHubMonitoring` already states, and more so here: an older build that rewrites that blob knows
nothing of this provider and would erase the user's choice.

**No derived lock.** `ProviderMonitoring.claudeApiLocked` exists because Claude's usage poll talks to
the very component `Claude API` reports on. Codex's quota comes from a local subprocess, not from
`Codex API`, so a lock here would assert a dependency that does not exist.

### D7. One backoff for the pair, and the longer `Retry-After` wins

A `429` is the **page** asking us to slow down, and there is one page behind both URLs. Holding the
components request while hammering the incidents one would honour the letter of the header and not
the request. So both feed one `PollingBackoff`, and when both answer with a hint the longer one is
kept — going back at the shorter interval would return to a page that asked for more.

This is why the incident request is **not** wrapped in `try?`. That would swallow the one failure
the caller must act on; it is caught by hand, and the rate limit is re-surfaced after the successful
components request has already been used.

### D8. `#5871C0` for both surfaces, where GitHub needed two roles

One `ColorRole.codexBrand`, a fixed sRGB literal like the other brand colours — a semantic colour
would invert with the appearance and destroy the only thing a brand mark says.

GitHub needs a second role (`githubBrandInk`) because pure black is unreadable on the dropdown's
dark material. `#5871C0` is mid-luminance, near `claudeBrand`, so it reads on both and no ink
companion is needed. That was a **prediction about a render**, which this project does not accept
from a screenshot: it was checked with **Digital Color Meter in sRGB** on the live dropdown in both
themes. Had it failed contrast, a `.codexBrandInk` would have been added mechanically.

The badge glyph is the shared `cloud.fill` every provider wears
([ADR-0094](0094-provider-row-brand-badge.md) §4, extended by ADR-0121 §D6): the shape is the
category, only the colour is the identity.

### D9. Its own loop, and the render-time merge becomes a fold

A third `LivePollScheduler` on a third `SignalHub.Subscriber` key, with its own hold, its own
last-success marker and its own in-flight task — the shape ADR-0119 built and ADR-0121 first
occupied. It polls once **before** its first wait, for the reason GitHub's does: `waitForNextPoll`
sleeps the whole interval up front, and a status-only provider has no second heartbeat to cover an
empty plate for the five-minute politeness floor after launch.

`renderedStatusHealth` becomes a fold over `merging` rather than a switch over the combinations.
`merging` already replaces a provider's checks and re-sorts by display order, so it is associative
here; the switch would need a case per subset, eight at three providers.

**The third near-identical loop is kept as duplication, deliberately.** A refactor stitched into a
feature is two reviews in one, and the three loops differ in every input that matters. A
`StatusSource` type carrying those inputs is the shape to try, as its own change.

## Consequences

- **The popup can be three plates tall.** Each collapses to zero height when its provider is off, so
  an install that enables nothing new is unchanged.
- **A shipped-on provider adds a plate and, during an OpenAI incident, a menu-bar dot on upgrade** —
  the same behaviour change ADR-0121's postscript recorded for GitHub, and it belongs in the release
  notes for the same reason.
- **Codex incident rows carry no external link.** The proxy feed has no `shortlink`. The row's stage
  word is plain text where Claude's and GitHub's are links — correct, not a bug.
- **The incidents can vanish while the statuses stay.** That is D2 working, and it is visible only in
  the log, so a user reporting "the dots are there but nothing explains them" is describing a
  degraded run rather than a bug.
- **Codex `status` records now exist in the journal** — and they are not merely bookkeeping: the
  fallback age is reconstructed from them, so a Codex row's age exists *because* the poll journals.
  Incident bodies are never written.
- **`StatusComponent` decodes `id`.** Matching stays by name everywhere; the id exists only to
  resolve another feed's ids back into names. A test that compared whole `StatusComponent` values
  had to be narrowed to the fields it was actually about.
- **A fourth provider is now mechanical in the popup and in Settings**, which it was not before: the
  plates and the provider rows are both generated from `displayOrder`. What still needs writing by
  hand is the provider's own poll loop and its config type.

## Alternatives considered

- **`summary.json`, like every other provider.** It cannot carry `CLI`, structurally (D1). Recorded
  so nobody "simplifies" the endpoint back.
- **`/api/v2/incidents.json` as the incident source.** `affected_components` is `null` on every
  incident, so incidents could not be attributed to a service at all (D2).
- **Showing every open provider incident, unfiltered**, as the price of staying on documented
  endpoints. It puts a Sora outage on the Codex plate, and the plate's header is the only attribution
  an incident row has ([ADR-0071](0071-incident-subscriptions.md) §3) — so the row would be read as
  Codex's.
- **Passing `updated_at` through anyway**, since every other provider's age comes from it. It is the
  same value on all 34 components; the age would be measured from an unrelated event and
  `isRecentlyRecovered` would never fire (D3).
- **Measuring the age locally from when we first saw the status.** It resets on relaunch, in the
  middle of outages that run for hours — the same reason Claude's age was taken from the API.
- **One grouped `Codex services` switch**, mirroring GitHub. The surfaces are genuinely different and
  the attribution is exact, so the group would hide a distinction the user acts on (D4).
- **Monitoring `Login`.** It appears twice under two ids; a name match resolves arbitrarily (D4).
- **Ordering providers by `allCases`.** Ties the screen to a case list that is archive identity (D5).
- **`usageEnabled` default-on, for consistency with every other monitoring flag.** It spawns a
  process rather than making a request; onboarding is the answer to discoverability instead (D6).
- **A backoff per URL.** One page, one limiter — a hold on half the pair is not a hold (D7).
- **Widening `StatusIncident` to cover the proxy shape.** Nearly every key differs; the result is a
  type of optionals whose reader must know which feed produced it (D2).
- **A per-provider badge glyph.** Rejected once already in ADR-0121 §D6, and this record does not
  reopen it: shape is the category, colour is the identity.

## Verification

Six stubs, exercised live before this record was written: `codex-green` (the calm plate — the state
that would otherwise be an empty plate), `codex-degraded`, `codex-cli-outage` (deliberately on `CLI`,
the component that proves the endpoint choice), `codex-incident` (an incident with no shortlink, so
the stage word is correctly not a link), `codex-incidents-unavailable` (components 200, incidents
500 — the only way to see the partial failure), and `all-three-providers` (plate order and gaps).

The brand colour was measured with **Digital Color Meter in sRGB** on the live dropdown in both
themes. No screenshot is a source of colour.

## Related

- [ADR-0119](0119-status-polling-own-cadence-and-backoff.md) — the per-source cadence and backoff seams
- [ADR-0121](0121-github-as-a-status-only-provider.md) — the provider shape this follows, and the grouping call this inverts
- [ADR-0120](0120-status-records-carry-their-provider.md) — the journal's provider tag the fallback age reads
- [ADR-0071](0071-incident-subscriptions.md) — the incident filter and the plate-header attribution
- [ADR-0094](0094-provider-row-brand-badge.md) — the shared badge glyph and the brand-colour rule
- [#501](https://github.com/artem-from-ua/tokenpace/issues/501), [#503](https://github.com/artem-from-ua/tokenpace/issues/503)
