# TokenPace documentation

The map of all the project's documentation. Start here if you're looking for where something lives.

The documentation language is English, as are code, identifiers, and commit messages (see
[ADR-0116](adr/0116-english-as-documentation-language.md)). Files not yet migrated are still in
Ukrainian.

## Sources of truth

The four main documents worth starting from:

- [SPEC.md](../SPEC.md) — the product spec: problem, architecture, UI, phases, monetization.
- [architecture.md](architecture.md) — a condensed architectural picture and the data flow.
- [../CLAUDE.md](../CLAUDE.md) — instructions for the AI agent: critical rules and pointers.
- [adr/](adr/) — architecture decision records (immutable; see [adr/README.md](adr/README.md)).

## How to do X (process)

- [building.md](guides/building.md) — building from source (for contributors).
- [releasing.md](guides/releasing.md) — build, notarize, and publish a release; release-notes style.
- [ui-verification.md](guides/ui-verification.md) — live verification of menu-bar / Settings changes
  before a PR: the list of stubs (`TOKENPACE_STUB=…`), scenarios without a stub, features that need
  signing.
- [writing-adrs.md](guides/writing-adrs.md) — creating, superseding and indexing ADRs: numbering,
  frontmatter, the body's sections, the supersession postscript, and what the index row may hold.
- [guides/agent-workflow.md](guides/agent-workflow.md) — operational rules for the AI agent:
  worktrees, branches/PRs, launching the app for UI checks, stopping the app and reading logs, the
  GitHub Project.

## Reference (what it is)

- [conventions.md](reference/conventions.md) — development conventions: language, style, logging, versioning.
- [glossary.md](reference/glossary.md) — the terminology contract: the English word for every concept,
  the Ukrainian one it replaced, and the canonical ADR section headings. Read it before translating
  any document.
- [users-and-goals.md](reference/users-and-goals.md) — who the app is for, which pain it solves, the
  "is this signal useful" test, the scarce resources, what the user already controls.
- [personas.md](reference/personas.md) — the four personas of the target audience ("Viktor", "Oskar",
  "Artur", "Ihor"), the segmentation frame, the catalog of enrichment ideas with verdicts, the
  first-run presets.
- [menu-bar-signals.md](reference/menu-bar-signals.md) — how to read the menu bar **from the user's
  side**: whether there is a number, what the glyph next to it means, how the bars read, and what the
  widget does not say.
- [ui-state-truth.md](reference/ui-state-truth.md) — the source of truth for renders outside the app:
  metrics, the anatomy of the bar, how the color is computed, the table of impossible combinations.
- [bar-status-conditions.md](reference/bar-status-conditions.md) — the exhaustive reference: under
  exactly which conditions each type of bar takes on each status/color, with a link to the line of code.
- [usage-api-quirks.md](reference/usage-api-quirks.md) — measured quirks of the Claude usage API: the
  `utilization` of the token windows arrives **rounded to a whole percent** (a step of 3 min on 5h and
  1 h 40 min on 7d), so fine-grained states on the weekly window are unreachable by construction.
- [log-messages.md](reference/log-messages.md) — the full list of every log message, grouped by file.
- [performance.md](reference/performance.md) — the gates of the five periodic tasks in one table: what
  screen lock, sleep, battery, and a metered network stop; which gates are missing.
- [architecture.md](architecture.md) — architecture (index), split into sub-pages:
  - [reference/architecture/overview.md](reference/architecture/overview.md) — principles, deployment, cadences, SPM.
  - [reference/architecture/data-flow.md](reference/architecture/data-flow.md) — polling, the token, pacing, rendering, flow diagrams.
  - [reference/architecture/update-system.md](reference/architecture/update-system.md) — checking for and auto-installing updates.
  - [reference/architecture/services-and-config.md](reference/architecture/services-and-config.md) — service status, config, Settings, the archiver.

## UI design

- [design/menu-bar-pixel-alignment.md](design/menu-bar-pixel-alignment.md) — pixel alignment in the
  menu bar: why `NSStatusBarButton` sits on a half-point, how that blurs the edges, and why a
  screenshot does not show the problem.

## Decisions (why it is the way it is)

- [adr/](adr/) — the index and the full/partial supersession convention live in
  [adr/README.md](adr/README.md).

---

> **The grouping above is by the reader's intent** (how to do / what it is / why), not by topic. The
> thematic subfolders — `guides/` and `reference/` (with `reference/architecture/`) — are already in
> place; this index is updated together with changes to the docs structure.
