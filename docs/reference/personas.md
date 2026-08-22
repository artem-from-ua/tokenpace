# Target-audience personas and enrichment data

Who TokenPace's potential users are beyond the core persona, what drives them, and which features
built on additional data sources (session jsonl, calendar, git, live sessions) clear the usefulness
bar for each persona. This is the reference for four decisions: filtering feature proposals,
prioritizing the roadmap, wording the positioning, and designing the enrichment features.

> Related: [users-and-goals.md](users-and-goals.md) — the core persona, the bar that a signal
> "has to change a decision", the scarce resources; [SPEC.md](../../SPEC.md) — the product spec;
> [journal-analysis.md](journal-analysis.md) and [usage-api-quirks.md](usage-api-quirks.md) —
> the resolution limits of the data that any enrichment idea has to live with.

> **Evidential status: three hypotheses and one verified persona.** "Arthur" rests on a measured
> journal series **and on clarified first-hand behavior**; "Viktor", "Oskar", and "Igor" are
> reasoned assumptions, and every feature in the catalog needs checking against a real user of the
> matching type before it gets built.

Every persona has a **code name** — a short handle for tickets, discussions, and verdicts
("this is a feature for Oskar"), so that the full archetypal description need not be dragged into
every mention.

## What this document adds to users-and-goals.md

[users-and-goals.md](users-and-goals.md) describes **the core**: a developer whose work comes in
bursts, whom the limit hits mid-task, and the bar for a useful signal — "is there an action the
user would take differently". This document **does not replace that bar — it refines it**: a signal
can pass the test for one persona and fail it for another. The verdict "build it or not" now weighs
*whose* feature this is and how central that persona is.

## The segmentation frame

**The subscription tier (Pro/Max) is not an axis of segmentation but a parameter of intensity.**
Bursty work (a large codebase, parallel agents) hits any quota — the only difference is how often
the blows land. The real axes:

1. **Appetite / quota** — how often the user actually hits the wall: daily, weekly, almost never.
2. **The shape of the day** — fixed, predictable windows of work versus a fragmented schedule with
   obligations in the middle of the day.
3. **Motivation** — squeeze the most out of a small quota · don't waste what's paid for · make the
   deadline, where missing it costs.

| Persona | Archetype | Plan | Appetite/quota | Shape of the day | Motivation |
|---|---|---|---|---|---|
| "Viktor" | evening builder | Pro | hits the wall weekly | fixed evenings/weekends | squeeze the most out |
| "Oskar" | schedule juggler | Pro/Max | moderate but concentrated | fragmented twice over: by obligations and by several clients | catch the "time × quota" overlap |
| "Arthur" | ROI professional | Max | almost never hits the wall | mostly fixed | don't waste what's paid for |
| "Igor" | intensive shipper | Max | hits the wall even on Max | business-like, with deadlines | make the deadline |

## The personas

### "Viktor" — the evening builder (Pro)

**Who this is.** Works a day job; Claude Code is for his own side projects in the evenings and on
weekends. The window of work is short and fixed: 2–3 hours an evening, and that is precisely why
every hour inside it is worth its weight in gold.

**Relationship to the quota.** Inside the evening window he burns hard — the 5-hour window is
noticeable every evening, the weekly Pro window is on the edge. **He will almost never pay for
extra usage** — this is a hobby budget; instead of paying, he adapts his behavior.

**Strategies at the limits** (they combine): schedules the heavy work right after a reset; eases
off in advance on seeing orange (a smaller model, smaller tasks); if he does hit the wall, switches
to manual work until the reset.

**Signals that change his decisions:** the countdown to the reset ("will this task fit into my
evening"), pacing to the end of the evening, the model-switch prompt ([J3](#j3-model-mix-and-the-switch-prompt)),
monthly statistics on hitting the wall ([N0](#n0-wall-hitting-statistics-from-the-existing-journal)) — as an
argument for "is Max worth it to me".

**Positioning:** *get more done in your evening.*

### "Oskar" — the schedule juggler (Pro or Max)

**Who this is.** A freelancer or remote worker with a fragmented day: kids and school, errands and
business to run mid-day. Work happens in 40–120-minute snatches between obligations; the evening is
not guaranteed. The calendar is not decoration but the actual map of his availability.

**The fragmentation is twofold — in time and in context.** This is his defining property: he runs
**several freelance projects in parallel and switches between them constantly**. So the day is cut
twice over — by obligations into slots, and the slots are divided between clients. The consequences
for the product:

- **"Where did the quota go" is not a rhetorical question for him but a working one.** Several
  clients mean that the per-project breakdown ([J2](#j2-quota-distribution-across-projectsclients))
  is material for **a report on the resource spent**, not just a curiosity. It is the same need
  "Igor" has, only smaller in scale.
- **Attribution has to survive the switching.** One 5-hour window of his easily contains work for
  two or three clients; an aggregate "per window" without a breakdown tells him nothing.
- **This is what separates him from "Viktor".** Both are Pro personas short on time, but Viktor has
  one project and a degenerate distribution, whereas here the context is multi-client.

**Relationship to the quota.** The total volume is moderate, but the work is concentrated into
short slots, so the 5-hour window is noticeable. His main shortage is **neither quota nor time
separately but the overlap of the two**: a free slot with the quota spent and a fresh quota during
a meeting are equally useless.

**Strategies at the limits:** schedules the heavy work into windows of free time; gains the most
from knowing in advance whether a reset will coincide with a free slot. When the quota is spent he
has a natural fallback the other personas lack — **switch to a different client** and do the work
that does not need Claude Code.

**Signals that change his decisions:** reset × busyness ([C1](#c1-reset--busyness)), a safe window
for the heavy work ([C2](#c2-a-safe-window-for-the-heavy-work)), pacing against the real schedule
([C3](#c3-pacing-against-the-real-schedule)). **The principal persona for calendar enrichment** —
and second after "Igor" in how much the per-client breakdown is worth.

**Positioning:** *quota and free time on one screen at last.*

### "Arthur" — the ROI professional (Max)

**Who this is.** A developer or solo entrepreneur on Max; the limits rarely bite. The motivation is
"the service is paid for and I don't want to lose money": an unused quota is value lost, and a
badly distributed one is too.

**Relationship to the quota.** Not survival but efficiency: is the subscription working at full
capacity, or is there room left unused at the end of the weekly window?

**The model is fixed — what gets adjusted is the difficulty of the task.** This is the most
important observation about this persona, and it runs against expectation: he works on the
strongest model (Opus high) all the time, switching up only for the very hard, hard-to-formalize
tasks. **He does not switch down at all.** So the prompt "move to a cheaper model" is not an action
for him — his lever is a different one:

| State | Action |
|---|---|
| Orange | Take an easier task or take a break — the model stays put |
| Blue near the end of 7d | Launch something deliberately heavy: kb-grooming, a large refactor |

**Strategies:** choosing the difficulty of the task to fit the current state of the bar, pauses on
orange, deliberate use of the surplus (a blue bar is a call to action for him just as orange is for
the others: "I can burn more freely — and I should, because it's paid for").

**What he does not do** (verified — and it matters, so as not to build things for him that he will
not use): he does not rebalance quota between projects and he does not move classes of task onto a
cheaper model. **This is about actions, not about data:** the retrospective "where did the quota
go" remains valuable to him as understanding — it simply does not imply any redistribution
([§ two bars](#two-bars-signal-and-retrospective-analysis)).

**Signals that change his decisions:** the blue bar as an invitation to a heavy task, watching N
("the weekly limit just got wider" — [users-and-goals § N](users-and-goals.md#the-ratio-between-the-windows-quotas-n--computed-not-hardcoded)),
statistics on the surplus left unused ([N0](#n0-wall-hitting-statistics-from-the-existing-journal)) — as an
argument for "am I overpaying".

**Evidence:** the only persona with a measured journal series **and confirmed first-hand
behavior**.

**Positioning:** *see what you paid for.*

### "Igor" — the intensive shipper (Max, small business)

**Who this is.** A small business or solo agency: a large codebase or several client projects,
parallel sessions, background agents and workflows. Hits the limits **even on Max**, because the
appetite outgrows any quota — three agents can eat a weekly window in an evening.

**The business dimension** (what separates him from private projects):

- **Deadlines that cost something to miss.** A limit before a Friday release is money and
  reputation, not an inconvenience. The only persona genuinely willing to pay for extra usage when
  the deadline is worth more than the surcharge.
- **Quota is a business resource.** How it is distributed between clients and projects has value in
  its own right: it feeds into the cost of the work and into justifying rates.

**Signals that change his decisions:** attribution of a burst ([J1](#j1-attribution-of-a-burst)),
live sessions × burn rate ([L1](#l1-live-sessions--burn-rate)), the per-client breakdown
([J2](#j2-quota-distribution-across-projectsclients)), a forecast of "will it last to the deadline",
the extra usage credits row (already in the product).

**Positioning:** *control when more than one agent is working.*

## Team / Enterprise: the audience beyond the horizon

According to external sources, Team and seat-based Enterprise use the same window mechanics as
Pro/Max (5-hour + weekly; the raising of the 5h limits on 2026-05-06 applied to all four plans),
whereas usage-based Enterprise is metered by consumption without those windows. An organization
administrator can [enable extra usage for individual users and set spending limits](https://www.anthropic.com/news/claude-code-on-team-and-enterprise)
at both the org and the per-user level; on the
[consumption model of Enterprise](https://support.claude.com/en/articles/14782391-claude-enterprise-consumption-guide)
a seat contains no tokens at all — all consumption is billed on top, under those same caps.

That gives rise to a potential fifth persona — **the employee on an issued quota**: the same 5h/7d
windows, but the money cap is monthly and **not his** — his employer controls it. The motivation
"the quota is an issued resource that somebody else controls" combines traits of "Viktor" (squeeze
the most out of something fixed) and "Igor" (deadlines), without the lever of paying more.

**Why this is still a hypothesis rather than a persona** — three unverified premises:

1. Whether `GET /api/oauth/usage` returns the same response format for Team tokens — not verified
   (all of our measurement is Pro/Max).
2. Whether the user can see their own admin-set cap through the API (an analog of `spend.limit`),
   or whether only the admin sees it.
3. Distribution: whether a third-party menu bar app is even possible in a managed (MDM)
   environment.

One confirmed Team user with access to the API response would be enough to raise this into a
full persona.

## Enrichment sources and the privacy frame

**The frame: everything local, opt-in per source.** Each source is enabled by its own switch in
Settings; a disabled one is not read at all. Processing happens on the Mac only; no raw data leaves
the device (in Phase 2 only aggregates go to CloudKit, as they do for the usage snapshot — see
[SPEC.md § Architectural decision](../../SPEC.md#architectural-decision)).

| Source | What it adds to the usage API | Access mechanism |
|---|---|---|
| Claude Code session JSONL (`~/.claude/projects/**/*.jsonl`) | **what** the quota went on: projects, models, volume of work | reading the file system |
| The user's calendar | real availability: meetings, obligations | EventKit, a system permission |
| Git activity in local repos | tying spending to output (commits, branches, PRs) | reading local repos |
| Live Claude Code sessions | who is burning quota **right now**: running/waiting | local process state |

## Two bars: signal and retrospective analysis

**The bar cannot be applied identically to every surface**, and confusing the two cost one wrong
verdict in this document (see [J2](#j2-quota-distribution-across-projectsclients)).

| | **Signal** (menu bar, popup, notification) | **Retrospective analysis** (Insights) |
|---|---|---|
| Who initiates the showing | the app — it interrupts the work | the user — who comes on their own, when they want to |
| What the showing costs | attention nobody asked for | nothing: the screen is already open for this |
| The bar | "is there an action the user would take **differently**" | "does this answer a question the user **asks themselves**" |
| The cost of showing wrongly | noise, which people get used to and stop reacting to | one more block, which people scroll past |

The bar in [users-and-goals.md](users-and-goals.md#what-makes-a-signal-useful) was written for the
**first** column — for the surfaces where showing something costs attention. Carrying it verbatim
over to a retrospective is wrong: **understanding is a result too**, even when no immediate action
follows from it. The classic example is "where did the quota go this week": the user may change
nothing, and the answer was still worth having.

**What this does not cancel.** Retrospective analysis still has to be truthful and must not show
the input in place of the output where a verdict is possible; it simply is not obliged to end in a
"do X" button. And for notifications the bar remains **the highest** — they arrive on their own.

## The catalog of enrichment ideas, with verdicts

Every idea clears the bar of **its own surface** (see the table above). All the ideas below live in
Insights, the popup, or notifications; **not one of them touches the menu bar** — its width is a
scarce resource ([users-and-goals § scarce resources](users-and-goals.md#scarce-resources)).

### J1. Attribution of a burst

"This window was eaten by: a session in repo X, Opus, 3 background agents." The usage API says *how
much* burned; the session jsonl says *who exactly* — and turns "you're burning twice as fast" into a
concrete target.

| Persona | The decision that changes | Verdict |
|---|---|---|
| "Igor" | stop the most expensive agent, narrow the scope | ✅ passes |
| "Arthur" | understand what exactly ate the window (without changing the model) | ❔ as a retrospective, yes; as grounds for changing the model, ✖ |
| "Oskar" | break the window's spending down across the clients he switched between | ✅ as retrospective analysis (in the moment there is only one session, so live attribution is not needed) |
| "Viktor" | — (one session at a time) | ✖ does not pass |

### J2. Quota distribution across projects/clients

The "where did the quota go" breakdown by repository, by project and — where more depth is needed —
by PR, issue, or individual session. **This is retrospective analysis, not a signal**, so the bar
here is a different one (see [§ two bars](#two-bars-signal-and-retrospective-analysis)): it is
enough that the answer addresses a question the user asks themselves.

**Two different kinds of value, easily conflated:**

1. **Understanding** — "where does it all go". Not obliged to end in an action; the answer alone is
   worth a screen in Insights.
2. **Reporting** — the breakdown becomes **a working artifact**: a freelancer accounts to a client
   for the resource spent, a small business builds quota into its costs and its rates. Here an
   external requirement is already baked into the numbers, so what is needed is accuracy of
   attribution, not just the right order of magnitude.

| Persona | What it gives them | Verdict |
|---|---|---|
| "Igor" | a report to the client, quota in the cost base and in the rate justification | ✅ passes — a working artifact |
| "Oskar" | reports to clients; several projects with active switching between them | ✅ passes — a working artifact |
| "Arthur" | the retrospective "where did the quota go" as understanding | ✅ passes as a retrospective, ✖ as grounds for rebalancing |
| "Viktor" | curiosity about his own projects | ❔ one or two projects, the distribution is nearly degenerate |

**On "Arthur":** he feels no need to *rebalance* quota between projects, so only the **action** is
disproved for him; retrospective analysis as understanding remains valuable.

**What follows for the implementation.** The depth of attribution is not one size for all: for
understanding, the project level is enough; for reporting you need PR/issue/session, because that
is the level at which a client recognizes their own work. The second is more expensive and requires
cross-checking with git ([G1](#g1-output-per-unit-of-quota) as the directory of names), so the place
to start is the project level.

### J3. Model mix and the switch prompt

"Orange + 80 % of this window's spending was Opus → switch to Sonnet for the routine work." The
action is concrete and available to anyone: changing the model is the first lever any persona
reaches for on orange. It works in reverse too: "blue + everything on Sonnet → you can afford
Opus."

| Persona | The decision that changes | Verdict |
|---|---|---|
| "Viktor" | switch the model, stretch the evening out | ✅ passes |
| "Oskar" | the same, inside a short slot | ✅ passes |
| "Arthur" | — (already on the strongest model always) | ✖ disproved against real behavior |
| "Igor" | pick the model for the background agents | ✅ passes |

"Arthur" works on the strongest model all the time and does not switch down; the prompt "move to a
cheaper one" does not describe an action he will take, and the reverse side ("you can afford Opus")
is meaningless for him, because he is already there — so this idea does not serve all four
personas.

**What this changes for the design of the prompt.** Switching the model is not a universal lever
but the lever of the personas who are willing to move the model at all. For the rest, the reverse
side has to speak the language of **task difficulty** rather than of model names: "there's room —
time for a heavy task" instead of "there's room — you can use Opus".

The caveat still stands: never show the mix on its own without a verdict — that is the model's
input, not its output
([users-and-goals § the input/output rule](users-and-goals.md#what-makes-a-signal-useful)); only
the prompt is shown, and only when it has something to advise.

### C1. Reset × busyness

"The window resets at 14:00, but you have meetings from 14 to 16 → in practice you'll be working
from 16:00." The countdown to the reset is corrected for real availability rather than astronomical
time.

| Persona | The decision that changes | Verdict |
|---|---|---|
| "Oskar" | start the task now or schedule it after the slot | ✅ passes |
| "Igor" | the same, around business meetings | ✅ passes |
| "Arthur" | depends on how dense the calendar is | ❔ |
| "Viktor" | — (the calendar is empty inside the evening window) | ✖ does not pass |

### C2. A safe window for the heavy work

"The next 3 hours are free + the quota is fresh → now is the best moment for that large refactor."
A proactive prompt about the "time × quota" overlap.

| Persona | The decision that changes | Verdict |
|---|---|---|
| "Oskar" | when to place a burst — his main daily decision | ✅ passes |
| "Arthur" | planning the heavy sessions | ✅ passes |
| "Viktor" | — (his window is known anyway) | ✖ does not pass |
| "Igor" | secondary: bursts are dictated by the deadline, not the window | ❔ |

A notification form is warranted only if the overlap is rare for the particular user; a frequent
overlap should stay silent ([users-and-goals § silence](users-and-goals.md#why-silence-is-a-valid-state)).

### C3. Pacing against the real schedule

The linear pacing norm ([ADR-0005](../adr/0005-pacing-fractions-not-blocks.md)) assumes an even
week. The calendar supplies real availability: if Thursday and Friday are packed with obligations,
"falling behind" on Wednesday is in fact the norm, while "running ahead" on a free Monday is not.

| Persona | The decision that changes | Verdict |
|---|---|---|
| "Oskar" | not to ease off for nothing when the "lag" is explained | ✅ his strongest one |
| the rest | — (an even schedule ≈ the linear norm) | ✖/❔ |

**Caveat:** this changes the core of `PacingModel` — it needs an ADR of its own; the accuracy of the
correction is bounded by the quantization of the 7d window (a step of 1 pp = 1 hour 40 minutes,
[usage-api-quirks.md](usage-api-quirks.md)); explore it last of the calendar ideas — value for a
single persona against the highest complexity in the catalog.

### G1. Output per unit of quota

"This week: 4 PRs for 60 % of the quota" — tying git activity to spending.

| Persona | The decision that changes | Verdict |
|---|---|---|
| "Arthur" | an argument for upgrading or downgrading the plan, in a retrospective | ❔ monthly, no more often |
| the rest | — (no action in the moment) | ✖ does not pass |

**The weakest idea in the catalog**, and that is an honest verdict: productivity does not reduce to
a count of PRs, and the number changes no action in the moment. Git is more valuable **as a
directory for attribution** — the repo and branch names in
[J1](#j1-attribution-of-a-burst)/[J2](#j2-quota-distribution-across-projectsclients) come from
exactly there — than as a metric in its own right.

### L1. Live sessions × burn rate

"The weekly window is burning twice as fast + 3 active sessions right now." Attribution while it is
still possible to intervene — unlike the retrospective [J1](#j1-attribution-of-a-burst).

| Persona | The decision that changes | Verdict |
|---|---|---|
| "Igor" | stop or postpone a background agent now | ✅ his headline feature |
| "Arthur" | spot an agent that is working for nothing | ❔ |
| "Viktor", "Oskar" | — (one session) | ✖ does not pass |

### L2. "Burning, but no sessions"

Spending is happening while local sessions number zero → a forgotten background agent, or another
device. The state is rare and anomalous — which is exactly why it clears the **notification** bar:
it arrives only when something really is wrong, and the action is obvious (go and check).

| Persona | The decision that changes | Verdict |
|---|---|---|
| everyone | find the source of the unaccounted spending | ✅ as a rare notification, silent by default |

### S1. End-of-window surplus as an invitation to a heavy task

This grew out of clarified real behavior rather than an armchair assumption: on seeing a lot of blue
near the end of the 7-day window, the user deliberately launches something heavy — kb-grooming, a
large refactor, a long audit. A surplus you will not manage to spend is value lost, and it is the
end of the window that makes it visible.

It differs from [C2](#c2-a-safe-window-for-the-heavy-work) in its data source and in its question:
C2 asks "**when** am I free", this one asks "**is what I paid for about to go to waste**". No
calendar is needed here at all.

| Persona | The decision that changes | Verdict |
|---|---|---|
| "Arthur" | launch a heavy task before the surplus expires | ✅ confirmed against real behavior |
| "Viktor" | the same, if the weekly window closes with room left | ❔ on Pro the surplus is rarer |
| "Oskar" | depends on whether there is a free slot — which is C2 already | ❔ |
| "Igor" | — (there is usually no surplus at the end of the window) | ✖ does not pass |

**The condition for silence:** the signal makes sense only in the last quarter of the window and
only when the surplus is substantial. A blue bar at the start of the week means nothing — there are
still several days ahead in which everything can change. Word it in the language of the task
("there's room for a big task") rather than the language of the model — see the lesson from
[J3](#j3-model-mix-and-the-switch-prompt).

### N0. Wall-hitting statistics (from the existing journal)

No new access required — the journal already holds this: "this month the 5h window was exhausted N
times, for M hours of waiting in total" / "K % of the weekly surplus went unused".

| Persona | The decision that changes | Verdict |
|---|---|---|
| "Viktor" | is Max worth it to me — a money decision with numbers behind it | ✅ passes |
| "Arthur" | am I overpaying — the mirror image of that decision | ✅ passes |
| "Igor" | what the limit costs me against extra usage | ✅ passes |
| "Oskar" | the same as "Viktor" | ✅ passes |

The cadence of showing it is a monthly retrospective in Insights, not a permanent element; the
journal is processed strictly by the rules of [journal-analysis.md](journal-analysis.md).

## The summary matrix: source × persona

The strongest idea of each pair; an empty cell means no idea from that source clears the bar for
that persona.

The **signal** ideas and the **retrospective analysis** ideas are marked separately, because they
clear different bars ([§ two bars](#two-bars-signal-and-retrospective-analysis)).

| | "Viktor" | "Oskar" | "Arthur" | "Igor" |
|---|---|---|---|---|
| **JSONL — retrospective** | (J2 ❔) | **J1, J2** — reports to clients | **J1, J2** — understanding | **J1, J2** — reports and cost base |
| **JSONL — signal** | J3 | J3 | ✖ (does not change models) | J3 |
| **Calendar** | — | C1, C2, C3 | C2 | C1 |
| **Git** | — | a directory for J2 | (G1 ❔) | a directory for J1/J2 |
| **Live sessions** | — | — | (L1 ❔) | L1 |
| **Journal (existing)** | N0, (S1 ❔) | N0 | **S1**, N0, N | N0 |

Reading down the columns gives the priority of sources for each persona; reading across the rows
gives which persona each source serves.

**JSONL is useful to all four — but by different sides of itself.** As retrospective analysis it
answers "where did the quota go", and that is valuable even when no action follows from the answer;
for those who work for clients, the same breakdown becomes **a working artifact of reporting**. As a
source of signals it works only for the personas willing to move the model — and "Arthur" showed
that such willingness is not universal.

**Three personas out of four need the per-client breakdown** — "Oskar", "Arthur", and "Igor", albeit
at different depths: from "understand where it goes" to "put it on the client's invoice". J2 rests
on **the need to know** rather than on a willingness to change behavior, which is why it is more
robust than [J3](#j3-model-mix-and-the-switch-prompt).

**The cheapest source remains the underrated one.** The existing journal (S1, N0, watching N) needs
no new access whatsoever and gives the most to precisely the persona backed by real data. The
calendar is a one-persona feature ("Oskar"), and its priority equals that persona's priority on the
roadmap.

## First-run presets

The practical output of the personas in onboarding: instead of leaving a new user to work through
the settings alone, the first run asks a single question — "how do you work?" — and applies a
**preset**: a coherent combination of settings that **already exist** (see
[users-and-goals § what the user already controls](users-and-goals.md#what-the-user-already-controls))
plus future notification defaults. A preset only sets the starting values — every switch stays
available afterwards; this is not a separate settings surface.

| Setting | "Viktor" | "Oskar" | "Arthur" | "Igor" |
|---|---|---|---|---|
| Hide the top 5h bar | Never — the 5h window is what matters in the evening | Until it needs attention | Until it needs attention | Never — bursts every day |
| Menu bar style | Pressure — urgency in the width | Balance — both the surplus and the overshoot are visible | Balance — the left half shows the unused surplus | Pressure |
| Dropdown style | Pressure | Balance | **Balance** — the same signed-from-center reading as in the bar | Pressure |
| Colors tell me | Slow down | Slow down or speed up | Slow down or speed up — blue is a call to action for him | Slow down |
| Popup sections (per-model, credits) | Once used | When it needs attention | **When it needs attention** | Always — the credits are critical |
| Notifications (future) | "the window will run out before the evening ends" | the "reset × free slot" overlap ([C2](#c2-a-safe-window-for-the-heavy-work)) | the end-of-window surplus ([S1](#s1-end-of-window-surplus-as-an-invitation-to-a-heavy-task)), the monthly retrospective ([N0](#n0-wall-hitting-statistics-from-the-existing-journal)) | [L2](#l2-burning-but-no-sessions) + "it won't last to the deadline" |

These are **hypotheses for validation**, not a specification: the values in the cells have to be
checked against real users of each type, and only then should the onboarding screen itself be
designed (a separate ticket and, most likely, an ADR — not least about whether to ask "how do you
work?" outright or to infer the persona from the first weeks of the journal).

**"Arthur"'s column is a snapshot of real settings, not a hypothesis:** the dropdown is **Balance**
and the sections are **When it needs attention** — he wants the same way of reading on both surfaces
and silence until there is something to react to, per the
[rule about silence](users-and-goals.md#why-silence-is-a-valid-state).

## Positioning: one message per persona

| Persona | Message |
|---|---|
| "Viktor" | Get more done in your evening |
| "Oskar" | Quota and free time on one screen at last |
| "Arthur" | See what you paid for |
| "Igor" | Control when more than one agent is working |
