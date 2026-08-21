# Design: subscribing to status.claude.com incidents

A summary of the product interview (2026-08-05) on showing **incidents** in the popup and subscribing to
their updates via system notifications. The document records the **decisions taken** and the **open
questions**, along with the empirical data those decisions rest on. This is not an implementation plan —
the implementation will be a separate ticket and, most likely, an ADR.

> **Context.** [ADR-0013](../adr/0013-claude-status-line.md) deliberately decided **not to decode
> `incidents[]`** at all: the state of the services is determined exclusively by `components[].status`.
> That decision **still stands for determining state**. This document builds a separate layer on top of it —
> incidents as *context* and as an *object of subscription*, not as a source of state.

## Problem

The popup answers the question "my Claude is being dumb — is it me or Anthropic?" with the state of the
services. But when the answer is "Anthropic", the user is left without the other half: **what exactly is
broken, how long it will last, and when they can get back to work**. A yellow dot next to `Code` does not
explain that it is the models that are broken — and a person reads "degraded" as "it will be slower", when
in fact part of the functionality does not work at all.

## The empirical base

The decisions below rest on **measured** data, not on assumptions about how Statuspage behaves.

Sources: 50 incidents from `GET /api/v2/incidents.json` (2026-07-08 … 2026-08-05) plus two incidents
tracked live from the start through to `resolved` (`f6gkkq6txl7z`, `mgp99sn4ynd4`).

### The gap between real recovery and `resolved`

Statuspage closes an incident **later** than the components return to `operational`:

| metric | value |
|---|---|
| incidents with a detected moment of turning green | 45 of 49 closed |
| median gap, green → `resolved` | 6 min |
| mean | 36 min |
| gap > 10 min | 19 cases |
| gap > 60 min | 5 cases |
| maximum | **480 min** (8 hours) |

The live measurement of `f6gkkq6txl7z`: the components turned green at 13:08:34 UTC, `resolved` was set at
14:14:36 — **66 minutes**. The degradation lasted 363 min.

> **Consequence.** The "you can work again" signal **cannot** be taken from `resolved_at`. That is an
> administrative act by Anthropic, not the fact of recovery.

### Four different ways to arrive at recovery

Two incidents on the same day exhibited four different shapes — no model built on `incident_updates` covers
them all:

| way | example |
|---|---|
| an update with status `monitoring` and the components moving to `operational` | `f6gkkq6txl7z`, 13:08 |
| a **silent** recovery — the components turned green **with no update at all** | `mgp99sn4ynd4` |
| a `resolved` update that **duplicates** an already-present transition | `f6gkkq6txl7z`, 14:14 |
| a `resolved` update with an **empty** transition (`operational` → `operational`) | `mgp99sn4ynd4`, 14:34 |

Historically a fifth one occurs too: the update that turns the components green has status `investigating`
rather than `monitoring` (`bdr3fq2rkchr`).

### Unreliable fields

- **`monitoring_at`** — populated in only 28 of 49 incidents. In `mgp99sn4ynd4` it is `null`.
- **`deliver_notifications`** — inconsistent. In our two incidents it was `true` on all 6 updates,
  including the purely textual one; whereas in the historical `bdr3fq2rkchr` it was `false` on `resolved`
  precisely — the event most valuable to the user. As a noise filter it is **unusable**.
- **`impact`** — correlates weakly with real pain: both incidents on 2026-08-05 were `minor`, even though
  some of the models were down for 6 hours.

### The volume of updates

- Updates per incident: **3.3** on average, 8 at most.
- `f6gkkq6txl7z` produced 4 updates over 429 min, **only one** of which was purely textual.
- So the difference between the "all updates" and "recovery only" modes on real data is roughly
  **one banner per incident**.

### Other observations

- **`components[]` inside an incident** is empty (`[]`) in the general feed of closed incidents
  (`incidents.json`) — but **not** in `summary.json`, which is the only endpoint TokenPace uses: there it is
  populated and, moreover, mirrors the **current** state of the components rather than their state at the
  time of the incident (verified against snapshots: in `03-monitoring-green` an open incident shows all
  components as `operational`, byte for byte identical to the top-level array). So a second request is not
  needed — and this field **cannot** be read as historical evidence of how serious the incident once was.
  *(Corrected following the implementation of #279; the original wording was true only for
  `incidents.json`.)*
- **Updates get edited after the fact**: in `71wxpw067nx2` `created_at` is 07:05 while `updated_at` is
  09:13. An update's identity is its `id`, not its time.
- **A component's state does not belong to an incident.** At 14:00 both active incidents showed the same 4
  components as `degraded`, even though only the second one had caused it.
- **Components flicker**: 13:08 green → 13:51 red again (because of a *different* incident) → green.

## Decisions taken

### 1. The popup: ⌥ switches the dimension

By default the popup stays as it is now — rows of **components** with a problematic status.

**Under ⌥ the list of services is replaced by a list of incidents** (with colored dots as well). Green
service statuses are **no longer** shown under ⌥.

```
(without ⌥)
● Code ..................................... degraded
● API ...................................... degraded

(hold ⌥)
● Degraded performance of multiple models
    identified · 2h                              🔔 ↗
● Degraded performance for Claude Opus 5
    identified · 12m                             🔕 ↗
```

This differs from the existing behavior of ⌥ (which showed *all* components, healthy ones included) — ⌥ now
switches the **dimension** (services ↔ incidents) rather than "show more".

> ⌥ already carries other roles in the popup: the per-project awaiting breakdown (#233) and data age. The
> replacement affects **only** the service status section.

**If there are no active incidents, the section under ⌥ disappears entirely.** The popup does not grow for
nothing.

> **Rendered mockups of this UI:** [four popup states](https://claude.ai/code/artifact/c6697546-aad0-43c5-a1e7-cf2ed5f401eb). The sketch below is from the
> interview; for the final composition (the description moved, the `age · stage` chip on the right in the
> last row, a single subscription row per episode) see the artifact.

### 2. The content of an incident row

The incident's title + age + status. **The affected services are NOT shown** — that is exactly what the
current filter in Monitored Services is, and duplicating it in the row makes no sense.

The status word (`identified`, `monitoring`, …) is a **link to the specific incident** (`shortlink`),
not to the general status page.

> This also solves an existing problem: today the status word in a *component* row leads to
> `status.claude.com` in general, and when several services are affected you get several identical links
> going nowhere. When there is one row per incident, the link leads where it should.

### 3. Components green → the incident is hidden

If the components are already `operational` while the incident is still formally open (our 66-minute case),
**the incident is not shown in the popup at all**.

The rationale: the popup answers "can I work right now". Green components mean "yes"; an open incident does
not contradict that.

### 4. Subscription is opt-in by click, exclusively

**Nothing arrives until the user clicks it themselves.** No default state, no global "notify me about
incidents" toggle.

A subscription is taken out on a specific active incident, or on a batch of simultaneous ones — by clicking
the corresponding icon in the row.

> **A consequence of this decision** (an important one, because it removes a whole layer of complexity): the
> problem of "guessing whether this incident concerns the user" goes away. Gating on `MonitoredServices`,
> the dilemma of "the incident is `major` but the components are green", the question of "the incident grew
> and now affects Claude Code" — all of it existed only so that a machine could decide when to wake someone
> up. When a person asks to be woken, there is nothing to guess.

### 5. The recovery signal comes from `components[].status`

**Not** `resolved_at`, **not** `monitoring_at`, **not** `affected_components` in the updates.

The only source that covers all five observed shapes of recovery is the current state of the components in
`summary.json`. The updates remain the source of the **text** ("what they are saying"), not the trigger.

> TokenPace already polls `summary.json` and reads `components[]` — the detector effectively exists. What is
> missing is the binding of "this component is down because of that incident" and the subscription itself.

### 6. Deduplication by `incident_updates[].id`

Not by the fact of a component transition (the shape is inconsistent, and `resolved` duplicates a transition
already shown) and not by `updated_at` (updates get edited after the fact → a repeat banner with stale
content).

### 7. Notification texts

The text is preceded by a **colored dot** highlighting the status (the same visual language as the popup).

**Recovery:**

```
🟢 Claude is back
Code and API are operational again.
```

**A textual update:**

```
🟡 Degraded performance of multiple models
We are continuing to work on a fix for this issue.
```

> **A technical caveat.** `UNNotificationContent` has no "colored indicator" of its own. The color will have
> to be done either with an emoji circle in the text (🟢🟡🟠🔴) or via a `UNNotificationAttachment` with an
> image. Emoji is simpler and more reliable — check it live before choosing.

### 8. Banner actions

- **Click** → opens the incident's page (`shortlink`).
- **An "Unfollow" button** — unsubscribe straight from the banner, without opening the popup.

### 9. Quiet hours apply

The same quiet hours as for "Back to work!" / "Extra usage credits"
([ADR-0039](../adr/0039-back-to-work-notification.md),
[ADR-0050](../adr/0050-extra-usage-notification.md)). One behavior, no surprises.

### 10. Settings — filters

Filter incidents **by affected services** (the existing Monitored Services) and **by the incident's age**
(hiding the "zombies" that hang around for days — the sample held one at 2,741 min ≈ two days).

### 11. A dev log of payloads in JSONL

A separate JSONL holding the full payloads of status responses, for dev troubleshooting.

- **Written only when significant fields changed** — the fingerprint is the component statuses + the set of
  `incident_updates[].id` + the incident's status. Duplicates are not written.
- **Enabled by a checkbox** in the Development tools window (#279), next to the stub selector; "Reveal log
  file in Finder" lives there too.

## Open questions

Deliberately deferred until there are live observations — measure, do not guess.

| # | Question | Why it is open |
|---|---|---|
| 1 | Behavior with **several simultaneous** incidents: one button for all, each one separately, or "only the ones present at the moment of the click" | Assess whether it is worthwhile in live testing over some period |
| 2 | The final set of **events that get banners** (textual updates / status changes / recovery / deterioration / formal closure) | The same — assess it against a real stream |
| 3 | **How long a subscription lives** after the incident closes; whether it survives a restart | Needs research; that is what the dev JSONL (item 11) is for |
| 4 | Whether a **debounce** is needed before the "recovered" banner, and what it should be | Components flicker (13:08 → 13:51 → green); without a delay the banners will bounce |
| 5 | What to do about **`impact`** and maintenance | We show them for now. Scheduled maintenance is useful **if the window falls within the user's active hours** — that is separate logic (`scheduled_maintenances[]` is not decoded at all right now) |
| 6 | Where exactly the **subscription icon** lives | The incident row is only visible under ⌥ → you can only subscribe while holding ⌥. A deeply hidden interaction; whether it is acceptable will show in practice |

## Test data

Snapshots of real API responses are stored **outside the repository** (they contain only public data, but
are kept locally under the general rule about live payloads):

```
~/.tokenpace-status-payloads/
├── 00-all-clear.{summary,unresolved}.json      # no incidents (157 bytes — the minimal stub)
├── history-50-incidents.json                    # 50 historical incidents
├── f6gkkq6txl7z/
│   ├── 02-identified-2updates.*                 # active, components degraded, a textual update
│   ├── 03-monitoring-green.*                    # active, components GREEN (the 66-min gap)
│   ├── 20260805T140019Z-monitoring.*            # TWO incidents at once
│   └── 20260805T141520Z-resolved.*              # the first left unresolved, the second stayed
└── mgp99sn4ynd4/
    ├── 20260805T142824Z-identified.*            # a SILENT recovery (there is no update)
    └── 20260805T143825Z-resolved.*              # resolved, unresolved is empty
```

Every state comes in all three endpoint variants (`summary.json`, `incidents/unresolved.json`,
`incidents.json`), so any code path can be stubbed.

> The `incidents.json` files weigh ~210 KB. Before using them as fixtures in unit tests they are worth
> trimming to 1–2 incidents.

## References

- [ADR-0013](../adr/0013-claude-status-line.md) — the service status line; the decision not to
  decode incidents
- [ADR-0024](../adr/0024-configurable-logical-services.md) — configurable logical services
- [ADR-0039](../adr/0039-back-to-work-notification.md),
  [ADR-0050](../adr/0050-extra-usage-notification.md) — the existing notifications, quiet hours
- [Incident f6gkkq6txl7z](https://stspg.io/s2ysk4zxbyy3) — the main case behind this document
