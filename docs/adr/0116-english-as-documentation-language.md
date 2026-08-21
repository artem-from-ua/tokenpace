---
status: accepted
date: 2026-08-21
supersedes: [0002]
superseded_by: []
---

# ADR-0116: English as the documentation language

> Supersedes [ADR-0002](0002-ukrainian-documentation.md) in full. The body of 0002 stays in
> Ukrainian — see [Consequences](#consequences) below for why.

## Context

[ADR-0002](0002-ukrainian-documentation.md) made Ukrainian the language of all project
documentation. That was a deliberate project-level override of the maintainer's global default
("repository artifacts in English"), taken on a direct instruction for this project, and it was the
right call at the time: the repository was a one-person effort whose only reader was its author.

Two things have changed since.

**The domain vocabulary is already English.** Every term this project actually reasons with —
`pacing`, `reset`, `calm`, `awaiting`, `journal`, `tick`, `snapshot`, `badge`, `five_hour`,
`resets_at` — is English and untranslatable by ADR-0002's own rule. What Ukrainian actually covers
is the connective prose *between* those terms. A survey of the corpus (see the migration epic)
found 146 Markdown files, 25,351 lines, ~139k words of Ukrainian wrapped around an English
vocabulary, and only **25 lines** of Cyrillic in Swift at all. The result is documentation that
reads as a code-switching layer rather than as text in one language: `Мова тікетів`, `pacing-смужки`,
`seam'и`, `backoff-ескалація`. That mixture is a leftover of how the project grew, not a decision
anyone made.

**The audience is no longer certainly one person.** The Mac agent is private today
([ADR-0003](0003-agent-closed-source-for-now.md)) and the open-source question is explicitly still
open. Ukrainian documentation is a hard prerequisite to answer "no" — it is a wall for every
contributor who does not read Ukrainian, and it makes the docs unusable as a public artifact
without first paying the migration cost. Paying it now, while the corpus is 146 files, is cheaper
than paying it later; and it costs nothing if the answer turns out to be "stay private".

Nothing about the original reasoning was wrong. The premise it rested on is what expired.

## Decision

**English is the language of everything in the repository and on GitHub.**

That means: `README`, `SPEC.md`, `docs/` (guides, reference, design, ADRs), `CLAUDE.md` and every
other agent-instruction file, skills, code, identifiers, comments, commit messages, PR titles and
bodies, issue titles and bodies, comments, release notes, and label descriptions.

**Ukrainian remains only where the artifact is not part of the repository:**

- agent conversation with the maintainer;
- plan files (`~/.claude/plans/*.md`);
- private `memory/` under `~/.claude/projects/`.

None of these are committed, published, or read by anyone other than the maintainer, and all three
are things the maintainer reads as a *reader* rather than as a repository artifact. This is exactly
the split the global rule already draws; this ADR stops carving an exception out of it for this
project.

Identifiers keep their original form, as before: API fields (`five_hour`, `resets_at`,
`client_id`), UI strings, and file names are quoted verbatim and are never translated.

## Consequences

- **The global default applies again.** ADR-0002 existed to override it; with 0002 superseded,
  `~/.claude/CLAUDE.md`'s "repository artifacts in English" rule governs this project like any
  other, and the project's own files stop needing to restate the exception.

- **ADR-0002's body is NOT translated.** By this repository's own convention an `accepted` ADR is
  immutable — it is a record of a decision that was made, in the form it was made. Superseding it
  changes its status, not its history. Concretely, only three things change: its frontmatter
  (`status: superseded`, `superseded_by: [0116]`), a one-line postscript at the top of its body
  pointing here, and the strikethrough of its number and title in
  [the index](README.md). **The Ukrainian body stays exactly as written, and so does its
  Ukrainian title in the index row** — the strikethrough already marks it historical. Translating
  it would be a well-intentioned corruption of the record; this paragraph exists so that no later
  session does it "helpfully".

  The same reasoning does *not* protect the other 114 ADRs: they are still live decisions being
  read as current documentation, and they are translated with the rest of the corpus.

- **The migration is large but bounded, and it is not this ADR's job.** This ADR only changes the
  rule. The corpus is migrated by the packages of the epic that owns this work, one PR at a time,
  each with its own verification. What this ADR buys is that from the moment it merges, every one
  of those packages is *compliance* rather than preference — and every new document written in the
  meantime is written in English, so the backlog stops growing.

- **Mid-migration the repository is bilingual, and that is expected.** Between this ADR and the
  final sweep, English and Ukrainian documents coexist and link to each other. A link from an
  untranslated Ukrainian file into a translated English one is not a defect to be fixed locally by
  translating the linking sentence; each package translates its own files and only forward-fixes
  the anchor fragments it breaks.

- **Ukrainian in the agent's own instruction files goes too.** `CLAUDE.md`, skills, and hook
  reason-strings are repository artifacts and are read by agents, not only by the maintainer.
  A hook that embeds a Ukrainian section title (as `.claude/hooks/release-notes-guard.sh` did)
  breaks the moment that title is translated — the more general lesson being that a hook should
  cite a section by what it *is*, not by its literal name.

- **The maintainer keeps reading Ukrainian where it matters to them.** Conversation, plans, and
  progress updates are unaffected. This changes what the project *writes down*, not how it is
  discussed.

## Alternatives considered

- **Keep Ukrainian; revisit only if the repository is opened.** Rejected: the decision to open the
  repository would then be gated on a ~139k-word migration, which makes it strictly less likely to
  be taken on its merits. It also lets the corpus keep growing at the rate the project writes docs,
  so the cost rises monotonically while the benefit stays zero.

- **English for new documents only; leave the existing corpus Ukrainian.** Rejected: this is the
  worst of both. The repository becomes permanently bilingual with no rule a reader can rely on,
  cross-references switch language mid-sentence, and "which language does this file use?" becomes a
  question with no answer other than "check its git history". A language rule that only applies
  going forward is a style preference, not a convention.

- **English docs with Ukrainian translations kept alongside.** Rejected: two copies of 139k words
  that no tooling keeps in sync will diverge, and the divergence is silent — the Ukrainian copy
  becomes subtly wrong documentation that still reads as authoritative. There is exactly one reader
  of the Ukrainian copy, and he reads English.
