# Writing and updating ADRs

The procedure for every change under `docs/adr/`: adding a record, superseding one, and keeping
[the index](../adr/README.md) in step with both. [adr/README.md](../adr/README.md) is the index and
the status vocabulary; this file is how you get there.

Read it before you touch anything in `docs/adr/` — including a one-line frontmatter edit on someone
else's ADR. Most of what follows was never written down: the numbering, the filename shape, which
frontmatter keys are required, which sections a body carries. It survived as habit, recoverable
only by opening a neighbouring file, and habit had already drifted — [0001](../adr/0001-swift-stack.md)
carries no `supersedes`/`superseded_by` keys at all while
[0119](../adr/0119-status-polling-own-cadence-and-backoff.md) carries both empty, one ADR spelled its
status `proposed` (a value the lifecycle has never had), and the index came to write the same status
eleven different ways.

## Before you start: does this need an ADR?

An ADR records **a decision between two viable approaches**, or a deliberate deviation from a
convention ([conventions.md](../reference/conventions.md#documentation-as-part-of-the-code)). Code
that had only one sensible shape does not need one.

Write it **after the maintainer has seen the feature live**, not before — the order is code →
`swift build`/`swift test` → screenshots → his confirmation → docs/ADR → PR
([CLAUDE.md](../../CLAUDE.md), [agent-workflow.md](agent-workflow.md#docs-and-adrs-are-written-after-the-maintainer-has-seen-the-feature-live)).
An ADR written before confirmation is wasted work twice over: if the behavior changes, the rationale
has to be rewritten along with the code.

## Adding a new ADR

Start from [TEMPLATE.md](../adr/TEMPLATE.md) — copy it, don't retype it from memory.

**1. Take the next free number.** One past the highest in `docs/adr/`. Two branches that each grab
the same next number merge cleanly and are still wrong; that collision, and the renumbering it
forces, is described in
[agent-workflow.md](agent-workflow.md#branches-prs-and-syncing-main).

**2. Name the file `NNNN-kebab-title.md`.** Four digits, then a short kebab-case slug of the title —
`0121-github-as-a-status-only-provider.md`. The slug is not the title; it may drop words the title
needs.

**3. Write the frontmatter.** Two keys are required, two are conditional:

```yaml
---
status: accepted      # required — accepted | draft | rejected | superseded
date: 2026-08-22      # required — ISO, the day the decision was made
supersedes: [0081]    # only when this ADR replaces part or all of another
superseded_by: [0115] # never on a new ADR — added later, by whoever supersedes it
---
```

Omit `supersedes`/`superseded_by` entirely when they don't apply. An empty `supersedes: []` says
nothing that absence doesn't say, and it reads as a key someone forgot to fill in.

**4. Write the H1 as `# ADR-NNNN: <title>`.** Sentence case — capital on the first word and proper
nouns only ([glossary.md](../reference/glossary.md#headings-are-sentence-case)).

**Keep it short and specific: this line is what the index shows.** It is the one part of the ADR a
reader meets before deciding whether to open it, and it is the only thing the Title column may
contain. Aim for the shape the corpus already has — around 70 characters, up to about 110 when the
decision genuinely needs them. State what was decided, not what the area is:
`Status polling gets its own heartbeat and a per-source 429 backoff`, not `Status polling changes`.

**5. Write the body.** Three sections, in this order, in effectively every ADR here:

- `## Context` — the situation and the forces. What made a decision necessary.
- `## Decision` — what was decided. Number the clauses (`### D1`, `### D2`, …) when the decision has
  parts: later ADRs supersede *fragments*, and they need something to point at.
- `## Consequences` — what follows, including the costs. Name the ones you would rather not.

Then, as needed, from the canonical set
([glossary.md](../reference/glossary.md#canonical-section-headings--pinned-before-any-adr-is-translated)):
`Alternatives considered`, `Related`, `Verification`, `References`, `Open questions`. Use those
names — a synonym of your own splits the vocabulary and breaks anchor links written against it.

**6. Add the row to [the index](../adr/README.md).** Title verbatim from the H1, status from the
table below.

## Superseding an ADR

**An accepted ADR is immutable. You never rewrite its body** — not to correct it, not to bring it
up to date. It is a record of what was decided and why, at a date. What replaces it is a *new* ADR;
what the old one gets is a marker pointing forward.

Decide which case you are in:

- **Full** — nothing of the decision survives. The old ADR becomes `status: superseded`.
- **Partial** — one section, one clause, one option's default is replaced, and the rest still
  stands. The old ADR **keeps `status: accepted`**. Marking it `superseded` would tell readers to
  skip a record that is still mostly in force.

In both cases:

**1. Add `superseded_by: [NNNN]` to the old ADR's frontmatter** (append to the list if it's already
there — an ADR can be superseded piecemeal by several).

**2. Add `supersedes: [NNNN]` to the new ADR's frontmatter.**

**3. Add a postscript to the old ADR** — a blockquote immediately after the H1, before
`## Context`. This is where the detail goes: what exactly was replaced, and what still stands. Open
it with one of three phrasings, and link the other ADR inline:

```markdown
> **Superseded by [ADR-0116](0116-english-as-documentation-language.md).** …

> **Partially superseded by [ADR-0106](0106-remove-dev-color-tuner-and-dissolve-colorstore.md).**
> Only the access layer is superseded: … **The decision itself still stands in full**: …

> **Supersedes §3 and §5 of [ADR-0081](0081-weekly-capacity-gate-for-blue.md).** …
```

The first two go on the ADR being superseded; the third goes on the one doing the superseding, when
it is worth stating up front what it replaces. Say what **still stands** as explicitly as what
doesn't — a reader who can't tell which half is live will treat the whole record as dead. Use the
phrase "still stands" for it; the corpus pins that wording
([glossary.md](../reference/glossary.md#pinned-mappings--one-english-word-per-concept)).

**4. Update the index row.** Status and strikethrough per the table below.

## Keeping the index in step

Every operation above ends in the same place — one row of
[docs/adr/README.md](../adr/README.md). What that row says is fully determined by the file:

| Frontmatter | Status column | Struck through |
|---|---|---|
| `status: accepted`, no `superseded_by` | `accepted` | no |
| `status: accepted` + `superseded_by: [NNNN]` | `partially superseded → [NNNN](NNNN-….md)` | no |
| `status: superseded` + `superseded_by: [NNNN]` | `superseded → [NNNN](NNNN-….md)` | **yes** — number and title |
| `status: draft` | `draft` | no |
| `status: rejected` | `rejected` | no |

**Every ADR number in the Status column is a link**, like every other mention of an ADR anywhere in
the repo ([CLAUDE.md](../../CLAUDE.md)). The lineage arrow is the one thing a reader follows out of
this table; a bare number makes them scroll back to find the row it names. Several superseding ADRs
join with commas, each linked separately:

```markdown
| [0020](0020-troubleshoot-window-and-diagnostics-pipeline.md) | The Troubleshoot window and a diagnostics channel through a pure pipeline | partially superseded → [0117](0117-dropdown-actions-behind-option.md), [0119](0119-status-polling-own-cadence-and-backoff.md) |
```

Strikethrough wraps the number and the title, never the status cell — struck text in the status
would make the one column you scan for lineage the hardest to read:

```markdown
| ~~[0002](0002-ukrainian-documentation.md)~~ | ~~Українська як мова документації~~ | superseded → [0116](0116-english-as-documentation-language.md) |
```

**Nothing else goes in a row.** Not a summary of the decision, not the reason for the supersession,
not which sections survived. The Title cell is the H1 and the Status cell is one of the five values
above.

That last rule is the one that failed before, and it failed quietly. Each ADR arrives in its own PR
adding a single line, so the diff reads `1 file changed, 1 insertion(+)` no matter how much prose
that line carries — the last such line was 5268 bytes. Nobody sees the table whole, so nobody sees
it grow: the average row passed 1 kB, the worst reached 5.2 kB, six rows had an unescaped `|` that
broke their column count, and a stray fragment split the markup mid-table. Every word of it
duplicated a postscript that already said the same thing better.

## What not to do

- **Don't rewrite the body of an accepted ADR.** Supersede it with a new one.
- **Don't put supersession detail in the index.** It belongs in the postscript.
- **Don't invent a status.** The five in the table are all there are — `proposed` is not one of
  them.
- **Don't add empty `supersedes: []` / `superseded_by: []`.** Omit the key.
- **Don't write a title that needs the body to make sense.** It is the whole index entry.
- **Don't mention an ADR, ticket, PR or file without linking it**
  ([CLAUDE.md](../../CLAUDE.md)). The exception is `Closes #NNN` in a PR body, where a link breaks
  GitHub's auto-close.

## Checking your work

```sh
python3 scripts/check-doc-links.py     # must print 0 broken
```

It validates every `[NNNN](NNNN-….md)` in the index along with the rest of the corpus, so a
mistyped filename in a new row surfaces here. Also confirm by eye that the table still renders as
one table — a stray `|` inside a title splits the row into extra columns, and the fix is to escape
it as `\|`.
