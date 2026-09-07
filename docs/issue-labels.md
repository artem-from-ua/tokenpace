# Issue taxonomy

TokenPace is a macOS menu bar widget showing Claude Code and ChatGPT subscription limit usage. This document is the source of truth for how its GitHub issues are labeled and titled: the axes, the dictionaries, and the rules for the cases where two values look equally right. When this document and the live GitHub labels disagree, this document wins.

## Axes

| Axis | Prefix | Mandatory | Cardinality | Color | Applies to |
|---|---|---|---|---|---|
| type | `type:` | yes | exactly one | `#cccccc` | all |
| priority | `priority:` | yes | exactly one | gradient | all |
| area | `area:` | no | zero or more | `#52a373` | all |
| provider | `provider:` | no | zero or more | `#0052cc` | all |
| phase | `phase:` | no | zero or more | `#8250df` | all |
| reason | `reason:` | no | zero or more | `#cccccc` | closed only |
| by | `by:` | no | zero or more | `#cccccc` | all |

**Scope:** issues only. PRs are not labeled.

The prefix separator is a colon rather than a slash: a slash URL-escapes to `%2F` in GitHub filter URLs, so `type/bug` becomes unreadable in the very place labels are used most.

## Cross-axis rules

- at-least-one: area, provider
- soft-limit: 5

Every issue carries `type:*` and `priority:*`, plus at least one `area:*` or `provider:*`. Beyond five labels an issue is usually doing too much and is a candidate to split.

## Values

### `type:*`

| Label | Description | Color |
|---|---|---|
| `type:bug` | Something is broken or behaves incorrectly against documented expectations. | `#b60205` |
| `type:feature` | A new user-visible capability. | |
| `type:perf` | Speed or memory improvement, with or without visible behavior change. | |
| `type:docs` | Changes only to README, SPEC, docs/, ADRs, or in-code comments. | |
| `type:refactor` | Internal restructuring with no user-visible change and no perf claim. | |
| `type:test` | Adding, fixing, or restructuring tests. | |
| `type:chore` | Tooling, build, dependencies, repo hygiene, CI. | |
| `type:research` | A spike or exploration that ends in a finding rather than a shipped change. | |
| `type:decision` | Several viable options exist and the trade-off needs weighing before anything is built. | |

`type:research` and `type:decision` are distinct: research answers *what is true*, a decision answers *which of these do we want*. An issue that must first find out and then choose is `type:research` until the finding lands.

### `priority:*`

| Label | Description | Color |
|---|---|---|
| `priority:critical` | Broken for users right now, or about to be. Fix before anything else. | `#b60205` |
| `priority:high` | Should land in the next release cycle. | `#e8814a` |
| `priority:medium` | Default for most work. Use this if unsure. | `#bfd62c` |
| `priority:low` | Nice to have. | `#cccccc` |

`priority:critical` shares the exact red of `type:bug` so the two loudest signals look alike. `priority:medium` is the default: an unset priority is worse than an approximate one.

### `area:*`

<!-- source: manual -->

| Label | Description | Color |
|---|---|---|
| `area:menu-bar` | The always-visible `NSStatusItem`: bars, glyphs, dot, width, reset label. | |
| `area:settings` | The Settings window and its panes, the toolbar, the sidebar. | |
| `area:infra` | What the app's users never see: docs, ADRs, CI, build, release and agent tooling, repo hygiene. | |
| `area:popup` | The dropdown window and its content — visible only after a click. | |
| `area:journal` | The usage journal as storage: JSONL writing, migrations, backups, archival, record shape. | |
| `area:notifications` | System notifications and the awaiting-input detection that feeds them. | |
| `area:dev-tools` | The `TOKENPACE_DEVTOOLS`-gated window, never shipped to end users. | |
| `area:troubleshoot` | The Troubleshoot window: the raw payload, token timing, intervals, and manual refresh. | |
| `area:updates` | In-app update checking and installation, as the user experiences it. | |
| `area:auth` | Token acquisition and storage: Keychain, OAuth, the logged-out and expired states. | |
| `area:branding` | The product's identity: the app name, its icon, and the visual identity around it. | |
| `area:extra-usage` | Money credits: spend, extra usage, their bars and formatting. | |
| `area:insights` | Any metric derived from journal history, whichever surface displays it. | |
| `area:polling` | Fetch cadence, backoff, rate limiting, request validation. | |
| `area:widgets` | Surfaces outside the menu bar: WidgetKit widgets, the lock screen, and the iOS and watchOS faces. | |
| `area:service-status` | Provider service health: incidents, outages, and their history. | |

### `provider:*`

| Label | Description | Color |
|---|---|---|
| `provider:claude` | Claude Code and its usage API. | |
| `provider:chatgpt` | The ChatGPT subscription limit, read through the Codex app-server. | |
| `provider:github` | GitHub releases and GitHub service-status monitoring. | |
| `provider:gemini` | Google Gemini, explored as a possible source of usage limits. | |

`provider:chatgpt` names the subscription the limit actually belongs to, not the client that reports it. The code still says `Codex` — `CodexQuota`, `CodexAppServer` — and [#517](https://github.com/artem-from-ua/tokenpace/issues/517) tracks the rename. Until it lands, the label and the symbols disagree on purpose.

### `phase:*`

| Label | Description | Color |
|---|---|---|
| `phase:1` | The macOS menu bar app. | |
| `phase:2` | iOS, watchOS, WidgetKit, Mac App Store distribution. | |

Kept as a label axis rather than migrated to milestones: the repository uses no milestones at all, so migrating would mean adopting an unfamiliar mechanism for taxonomic tidiness alone.

### `reason:*`

| Label | Description | Color |
|---|---|---|
| `reason:duplicate` | Closing reason: already tracked in another issue. | |
| `reason:invalid` | Closing reason: out of scope, a misunderstanding, not a real issue. | |
| `reason:wontfix` | Closing reason: acknowledged but explicitly decided not to fix. | |

### `by:*`

| Label | Description | Color |
|---|---|---|
| `by:kb-grooming` | Filed by the kb-grooming documentation automation. | |

## Disambiguation rules

- **`area:menu-bar` vs `area:popup`** — the always-visible status item is `menu-bar`; content that appears only after a click is `popup`. An issue changing both takes the surface where the primary fix lands, which the title usually names first.
- **`area:journal` vs `area:insights`** — `journal` is storage: writing, migrating, backing up, the record shape. `insights` is any metric computed from that history — burn rate, baselines, headroom in sessions — no matter which surface shows it. So [#241](https://github.com/artem-from-ua/tokenpace/issues/241) and [#539](https://github.com/artem-from-ua/tokenpace/issues/539) are `area:insights` although they read journal data and render in the bar.
- **The journal keeps `area:journal` even when only a developer sees it** — recording, migrating, and the diagnostics that make a record readable are all `area:journal`, whether the file is the user's or a dev-build one. `area:infra` is for the repository and its tooling, not for the app's own data.
- **`area:settings` vs `area:dev-tools`** — `dev-tools` is strictly the `TOKENPACE_DEVTOOLS`-gated window. Anything a real user can configure is `settings`, however developer-flavored it looks.
- **`area:updates` vs `area:infra`** — if the user never sees it (GitHub Actions, release runbook, notarization tooling) it is `infra`. The in-app update check and installer are `updates`.
- **When to attach `provider:*`** — only when the issue is about one specific provider. Architectural work that unifies behavior across providers carries `area:*` alone: [#507](https://github.com/artem-from-ua/tokenpace/issues/507), folding three poll loops into one driver, is `area:polling` with no provider label. A provider-specific defect keeps its provider even when it surfaces elsewhere, because the fix lands in provider-specific code.
- **Documentation that disagrees with the code** — always `type:docs`. The code is the source of truth, so a doc that describes it wrongly is a documentation defect, whichever side ends up being edited.
- **`type:feature` vs `type:refactor`** — `type:feature` only when a user can observe the change. Renames and internal restructuring are `type:refactor`.
- **Catch-all guard** — repo housekeeping goes to `area:infra`, never to the nearest product-facing area. Without this rule, docs and CI issues quietly hollow out whichever product value they land on.
- **A phase's own epic carries only its `phase:*`** — [#3](https://github.com/artem-from-ua/tokenpace/issues/3) is the whole of Phase 1, so no area describes it better than the phase already does. This is the one deliberate exception to the at-least-one rule, and it applies only to an epic that *is* a phase.
- **An umbrella issue does not inherit its children's areas** — a ticket that exists to group others carries only what is common to all of them, usually one `provider:*` or a single `area:*`. The specific areas live on the children, where they can actually be filtered. [#501](https://github.com/artem-from-ua/tokenpace/issues/501) groups [#502](https://github.com/artem-from-ua/tokenpace/issues/502)–[#506](https://github.com/artem-from-ua/tokenpace/issues/506) and carries `provider:chatgpt` alone.
- **Epics** — an epic carries no dedicated label. It is marked by an `[Epic]` prefix in its title and is otherwise classified by its own base type and area.

## Worked examples

| Issue | Labels | Why |
|---|---|---|
| [#532](https://github.com/artem-from-ua/tokenpace/issues/532) `CodexQuota: a malformed windowDurationMins traps instead of decoding as malformed` | `type:bug`, `priority:high`, `provider:chatgpt`, `area:polling` | A defect in ChatGPT-specific decoding, on the fetch path. The provider label stays because the fix lives in Codex-specific code. |
| [#507](https://github.com/artem-from-ua/tokenpace/issues/507) `Refactor: fold the three status poll loops into one driver` | `type:refactor`, `priority:medium`, `area:polling` | Unifies behavior across all providers, so no `provider:*` — the at-least-one rule is satisfied by `area:`. |
| [#539](https://github.com/artem-from-ua/tokenpace/issues/539) `7-day blue: say how many sessions of headroom there are before green` | `type:feature`, `priority:medium`, `area:insights`, `area:menu-bar` | A metric derived from journal history, so `insights`; the second area records where it is displayed. |
| [#437](https://github.com/artem-from-ua/tokenpace/issues/437) `Choose a new app name (to replace TokenPace)` | `type:decision`, `priority:medium`, `area:infra` | Several viable options, none of them discoverable by research — someone has to choose. |
| [#154](https://github.com/artem-from-ua/tokenpace/issues/154) `Worktree agents incorrectly gravitate toward main when renaming a branch` | `type:bug`, `priority:medium`, `area:infra` | Agent tooling, not the product. `area:infra` covers everything the app's users never see. |
| [#409](https://github.com/artem-from-ua/tokenpace/issues/409) `⚠️ means one thing in ADR-0091 and five things in the code` | `type:docs`, `priority:medium`, `area:infra`, `area:menu-bar` | Doc-versus-code divergence is a documentation defect by rule, even though the glyph itself is a menu-bar concern. |

## Title format

**Pattern:** `[CRITICAL ]<type>(<scope>): <subject>`

| Element | Source | Rule |
|---|---|---|
| `<type>` | the `type:*` value without its prefix | `feat`, `fix`, `perf`, `docs`, `refactor`, `test`, `chore`, `research`, `decision` |
| `<scope>` | an `area:*` or `provider:*` value without its prefix | where the effect lands for the user, not where the code lives; one per title |
| `<subject>` | — | what the user gets, not how it is implemented |
| `CRITICAL` | `priority:critical` | optional prefix modifier |

`epic` is a title-only marker: an epic keeps the `[Epic]` prefix and is still classified by its base type.

**Length:** 60–80 characters, soft. Self-containment beats brevity — if trimming a word makes the title ambiguous without reading the labels, keep the word.

**Exempt:** issues carrying a `by:*` label keep whatever title the automation produced.

## Legacy label mapping

Applied on 2026-09-07 across all 210 issues; the old labels were deleted afterwards and none survives on GitHub. The table stays as the record of what became what.

| Old label | Action | New label | Why |
|---|---|---|---|
| `bug` | map | `type:bug` | Direct equivalent. |
| `documentation` | map | `type:docs` | Direct equivalent. |
| `enhancement` | split | — | Feature vs refactor vs chore depends on whether a user can observe the change. 104 issues carry it, and several are internal restructuring. |
| `question` | map | `type:research` | The three issues carrying it are open questions, not defects. |
| `product-decision` | map | `type:decision` | Direct equivalent; the label is what motivated adding `type:decision`. |
| `phase-1` | map | `phase:1` | Same meaning, brought under a prefix. |
| `phase-2` | map | `phase:2` | Same meaning, brought under a prefix. |
| `epic` | delete | | Epics are marked by the `[Epic]` title prefix; the label duplicated it and blocked the base type. |
| `ui` | delete | | A `layer:` axis was considered and rejected: `ui` covered 78 of 210 issues, so it narrowed nothing, and it described where code lives rather than what changes for the user. |
| `logic` | delete | | Same rejected axis. |
| `infra` | delete | | Same rejected axis. Not to be confused with `area:infra`, which means non-product work rather than a code layer. |
| `duplicate` | map | `reason:duplicate` | Built-in, replaced by the prefixed equivalent. |
| `invalid` | map | `reason:invalid` | Built-in, replaced by the prefixed equivalent. |
| `wontfix` | map | `reason:wontfix` | Built-in, replaced by the prefixed equivalent. |
| `good first issue` | delete | | Built-in, unused; removed under the delete-all policy. |
| `help wanted` | delete | | Built-in, unused; removed under the delete-all policy. |

## GitHub built-in labels

Policy: **delete**. Exceptions kept: none.

GitHub silently re-creates built-in labels after some UI operations; the drift check watches for that, which is why the policy is recorded here.

---

<!-- issue-conventions:managed -->
> **Do NOT edit this file by hand.** Run `/issue-conventions-setup` to change the taxonomy and `/issue-conventions-relabel` to apply it to existing issues. Hand edits are honored — this document is the source of truth — but the plugin cannot guarantee that GitHub labels and this file agree until you re-run those commands.

| | |
|---|---|
| Config | `.claude-plugin/issue-conventions.json` |
| Plugin | `issue-conventions` v0.2.4 |
| Last synced with GitHub | 2026-09-07 |
<!-- /issue-conventions:managed -->
