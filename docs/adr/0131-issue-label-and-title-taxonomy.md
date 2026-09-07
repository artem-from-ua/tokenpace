---
status: draft
date: 2026-09-07
gate: met on 2026-09-07 — the taxonomy is applied to all 210 issues and `gh label list` no longer contains `enhancement`, `ui`, `logic`, `infra`, or `phase-1`. Promotion to accepted is the maintainer's call.
---

# ADR-0131: Issue labels and titles as prefixed axes

## Context

The repository has 210 issues and 16 labels. Nine of those labels are GitHub's built-ins; the seven added by hand — `epic`, `phase-1`, `phase-2`, `logic`, `ui`, `infra`, `product-decision` — grew one at a time, without a scheme. What that produced:

**The labels do not narrow anything.** `phase-1` sits on 109 issues and `enhancement` on 104 — each covers roughly half the corpus, so filtering by either returns a list nobody can read. `ui` covers 78. The three labels that describe most of the backlog are the three that say the least about any single issue.

**Nothing says what an issue is *about*.** There is no way to ask "what is open against the Settings window", "what did we file about the journal", or "what breaks for ChatGPT users" — the questions actually asked while planning work. The information exists only in titles, and only for the ~55% that happen to start with an informal `Settings: …` / `Menu bar: …` prefix.

**Nothing says what is urgent.** With no priority axis, a release-blocking defect and a nice-to-have are indistinguishable in the list. Sorting a backlog means reading it.

**34 of 210 issues carry no label at all** (16%), and the unlabeled set is not junk — it includes [#480](https://github.com/artem-from-ua/tokenpace/issues/480), [#479](https://github.com/artem-from-ua/tokenpace/issues/479), [#455](https://github.com/artem-from-ua/tokenpace/issues/455). Labeling was optional, so it lapsed.

**Both humans and AI agents file issues here**, and agents have no habit to fall back on. Without a written dictionary each session invents its own, which is how `ui`, `logic`, and `infra` came to mean slightly different things depending on who applied them.

One constraint shapes the answer: the repository uses **no milestones at all** (`gh api milestones` returns zero), so the usual advice — move roadmap stages out of labels and into milestones — would mean adopting an unfamiliar mechanism for the sake of taxonomic purity.

## Decision

Seven prefixed axes, colon-separated, 39 labels (35 at the outset; four more were added while applying it, see below). The full dictionaries, colors, and rules live in [issue-labels.md](../issue-labels.md), which is the source of truth; this record holds the reasoning.

| Axis | Mandatory | Cardinality | What it answers |
|---|---|---|---|
| `type:` | yes | exactly one | what kind of work this is |
| `priority:` | yes | exactly one | how soon |
| `area:` | no | zero or more | which part of the product |
| `provider:` | no | zero or more | which provider, when it is provider-specific |
| `phase:` | no | zero or more | which roadmap stage |
| `reason:` | no | zero or more | why it was closed |
| `by:` | no | zero or more | which automation filed it |

Plus: at least one of `area:` or `provider:` on every issue, and a soft limit of five labels — past that an issue is usually doing too much.

**The separator is a colon** because a slash URL-escapes to `%2F` in GitHub filter URLs, making `type/bug` unreadable in the place labels are used most.

**`type:` extends the Conventional Commits seven with two more.** `type:research` and `type:decision` exist because `product-decision` already existed and was doing real work on 6 issues, and because spikes ([#142](https://github.com/artem-from-ua/tokenpace/issues/142)) and explorations ([#60](https://github.com/artem-from-ua/tokenpace/issues/60)) are neither. They are kept separate from each other: research answers *what is true*, a decision answers *which of these do we want*.

**`provider:` is its own axis rather than values inside `area:`.** Provider-specific work lands on every surface at once — a ChatGPT quota bug is simultaneously about polling, the bar, and the journal — so folding providers into `area:` would force a choice between two orthogonal facts. `provider:chatgpt` names the subscription the limit belongs to rather than the client reporting it, deliberately disagreeing with the `Codex*` symbols in the code until [#517](https://github.com/artem-from-ua/tokenpace/issues/517) renames them.

**One color per axis, because the prefix already carries identity.** The exception is `priority:`, a red→orange→lime→grey gradient, where color carries urgency rather than membership; `priority:critical` shares the exact red of `type:bug` so the two loudest signals look alike. No structural axis uses the red-orange range, which would dilute that signal.

**`phase:` stays a label axis** rather than migrating to milestones, given that no milestone exists to migrate into.

**Title rules apply to new issues and existing ones are rewritten** to `<type>(<scope>): <subject>`, with `[Epic]` surviving as a title-only marker.

## Alternatives considered

**A `layer:` axis (`ui` / `logic` / `infra`), rejected.** It was the closest thing the repository already had to a working axis — the three labels are nearly mutually exclusive, with only 13 of 210 issues carrying two. It was rejected for two reasons: `ui` alone covers 78 issues, so it narrows almost nothing, and the axis describes *where the code lives* rather than *what changes for the user* — which is what a reader of the backlog is asking. `area:menu-bar` already says more than `ui` does. The one thing lost is the "pure logic, coverable by tests" filter that `logic` provided.

**Structural axis from directory layout, not possible.** The usual source for a structural axis is the repo's own shape, but `Sources/TokenPaceKit/` holds 90 Swift files flat, with no subdirectories to name. The axis had to come from the issues instead, which is what `area:` is.

**A separate `area:agents` for AI-agent tooling, rejected.** [#154](https://github.com/artem-from-ua/tokenpace/issues/154), [#421](https://github.com/artem-from-ua/tokenpace/issues/421), and [#489](https://github.com/artem-from-ua/tokenpace/issues/489) are about agent instructions rather than the product, and there is a real volume of that work here. It was folded into `area:infra` because the boundary between "agent tooling" and "repo hygiene" is not one a classifier could apply consistently.

**Splitting `area:infra` into `repo` + `build`, rejected.** Docs/ADR bookkeeping and the signing/CI pipeline are genuinely different activities, but one non-product value was preferred over two boundaries to police.

**`provider:multi` for cross-provider work, rejected.** [#507](https://github.com/artem-from-ua/tokenpace/issues/507) folds three poll loops into one driver and belongs to every provider and none. Rather than invent a value meaning "all of them", such issues carry `area:` alone — the at-least-one rule is satisfied without a provider label.

**Keeping GitHub's built-ins, rejected.** `bug`, `enhancement`, and `documentation` would compete with `type:bug`, `type:feature`, and `type:docs`, leaving two labeling systems running at once. All nine are deleted, `good first issue` and `help wanted` included, despite their integration value for outside contributors.

**Darkening `type:*` to separate it from `priority:low`, rejected.** Both render grey, so a `type:feature` + `priority:low` issue shows two identical chips. Grey was kept on both because grey means "this chip is not shouting", and the eye should catch the red priority and green area instead.

**Mapping `enhancement` wholesale to `type:feature`, rejected** in favor of a per-issue split: among its 104 issues there are refactors ([#507](https://github.com/artem-from-ua/tokenpace/issues/507), [#508](https://github.com/artem-from-ua/tokenpace/issues/508)) and chores, and a blanket map would bake that error into 104 issues at once.

## Consequences

**Positive.** The backlog becomes queryable along the axes actually used when planning: what is urgent, what is open against a surface, what breaks for one provider. Mandatory `type:` and `priority:` end the 16% unlabeled rate. AI agents filing issues have a written dictionary instead of a habit, which is what kept `ui`/`logic`/`infra` drifting. The seven `type:` values that match Conventional Commits mean an issue title and its PR title carry the same signal.

**Negative.** Every issue now needs at least three labels, where many needed none — a real cost on quick filings, and the reason `priority:medium` is an explicit default rather than a decision. That default is also the axis's main risk: if everything lands on medium, the axis stops meaning anything. `enhancement` is split per-issue across 104 issues, the most expensive part of the migration. `provider:chatgpt` deliberately disagrees with the `Codex*` symbols until [#517](https://github.com/artem-from-ua/tokenpace/issues/517) lands, which will read as an inconsistency to anyone who has not read this record. The `area:` dictionary is at the upper end of what stays memorable, and its tail is thin: `branding`, `widgets`, `troubleshoot` and `service-status` carry a handful of issues each, small enough that they may not earn their place.

## What applying it to the backlog showed

The taxonomy was applied to all 210 issues on 2026-09-07, and the labels were rewritten together with every title. Four observations are worth more than the predictions above.

**The dictionary was four values short, and the gaps were invisible from the issue titles alone.** Classification surfaced four surfaces with no home: `area:widgets` (the WidgetKit epic is neither the menu bar nor the popup), `area:branding` (the app's name and icon), `area:troubleshoot` (a window that is not Settings and not the `TOKENPACE_DEVTOOLS`-gated tools), and `provider:gemini` (a vendor explored but never supported). Each was added mid-pass. A pre-pass over the corpus mined topics by frequency, which is exactly why it missed them: the WidgetKit epic is one issue, and `branding` is two.

**`priority:medium` did absorb most of the backlog, as feared — but not all of it.** The final split is 150 medium, 36 low, 21 high, 3 critical. The three criticals are real ([#530](https://github.com/artem-from-ua/tokenpace/issues/530) leaks processes, [#509](https://github.com/artem-from-ua/tokenpace/issues/509) deletes the live journal, [#492](https://github.com/artem-from-ua/tokenpace/issues/492) crashes on close), so the top of the scale carries signal. The medium bucket is inflated mostly by closed issues, where priority is retrospective and meaningless; whether it stays honest depends on open issues alone.

**The `journal` versus `insights` boundary needed a rule, and so did three other cases.** The rules added during the pass are in the document: the journal keeps its area even when only a developer sees the record; an umbrella issue does not inherit its children's areas; and a phase's own epic carries only its `phase:*`. That last one is a deliberate exception to the at-least-one rule and applies to exactly one issue, [#3](https://github.com/artem-from-ua/tokenpace/issues/3).

**Automated classification is reliable on the axes and unreliable on the bookkeeping.** Across twelve batches the classifier placed types, priorities and areas well — 9 of 210 issues needed a human decision. Its failures were clerical: it twice left a legacy label in `keep` instead of `remove`, once omitted the mandatory `type:` entirely, and once dropped a label the issue actually carried. All four were caught by validating each batch against the parsed document rather than trusting the classifier's own confidence, which is the practice worth keeping.

Still open: color legibility on real multi-label issues, including whether grey `type:*` beside grey `priority:low` reads as a duplicate chip in the GitHub UI.
