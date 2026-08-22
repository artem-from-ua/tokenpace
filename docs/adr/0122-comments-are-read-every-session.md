---
status: accepted
date: 2026-08-22
supersedes: []
superseded_by: []
---

# ADR-0122: Comments are priced per read, and ADR citations are footnotes

> Lineage: [ADR-0116](0116-english-as-documentation-language.md) fixed the *language* of the
> corpus; this record fixes its *volume* and the rules for pointing from code into `docs/adr/`.
> [#489](https://github.com/artem-from-ua/tokenpace/issues/489) is the cleanup it authorizes.

## Context

Comments in this repository are unusually thorough, and that was the right instinct while the
architecture moved every week: a paragraph explaining why a constant is 14 and not 10 has repaid
itself many times over.

What changed is who reads them, and how often. Every session — the maintainer's, an agent's — loads
these files into a context window, and pays for every byte on every read. Measured across
`Sources/`:

| | Tokens |
|---|---|
| Comments | **~312 000** |
| Code | ~172 000 |

**47% of lines are comments, and they occupy 64% of the bytes.** Opening
`PopupViewController.swift` spends ~67 000 tokens, of which ~45 000 are prose. `PacingModel.swift`
is 82% comment: 8 963 tokens of prose against 1 930 of code. That cost recurs forever, and it is
paid by whoever is trying to answer a question the prose usually does not address.

The prose is not padded — it is *dense*, and much of it documents a past. `PacingModel`'s
`elapsedFraction` carries 19 lines of comment over 5 lines of code; three of those lines state the
boundary rules the function implements, and the rest describe how it was ported from
`statusline.sh`, naming that file's line numbers. **`statusline.sh` exists neither in the repository
nor anywhere in its git history** — it was an external prototype. 70 such references survive across
23 files, all pointing at nothing.

A second question came up alongside: whether comments should cite ADRs at all, given that ADRs get
superseded and nothing warns the citing comment. The numbers looked alarming — of 76 distinct ADRs
cited from code, only **28** are current in full; 74 references point at fully superseded records
and 381 at partially superseded ones.

They are less alarming on inspection. Sampling 16 such sites: **14 are still accurate**, one is
inert, one misleads. Two structural reasons: comments cite an ADR's *architectural core* (the
pure/shell split, the independence of two data sources) rather than the narrow clauses that later
get reversed, and supersession preserves exactly that core — every postscript in this corpus is
written as "X still stands." And the postscripts sit at the very top of the file, section-addressed,
so a reader arriving from a stale citation meets the correction before the body.

The one that misleads is real: `MenuBarLayout.swift` describes eliding the 7-day bar "when the user
picked it" — a three-way choice [ADR-0090](0090-menu-bar-answers-can-we-work.md) removed. A reader
who trusts the comment without following the link believes an option exists that does not.

## Decision

### 1. A comment is priced per read, so length is a cost, not a virtue

Write the shortest comment that answers what the next editor must know. Where a paragraph and a
sentence carry the same information, the sentence is correct. This is not a style preference: prose
in a source file is re-read on every session that opens it, and the reader is usually looking for
something else.

### 2. A comment describes the current behavior — only that

Not what the code used to do, not what a constant was before, not which issue changed it. When a
sentence starts with *used to* / *previously* / *was removed*, rewrite it in the present tense: if a
fact survives, keep the fact and drop the history; if nothing survives, delete the sentence.

**Deleting beats rewriting.** A pass over 37 sites that rephrased history into the present tense
while preserving length changed total volume by ~0.05%. The genre improved and the cost did not.
The win comes from paragraphs removed, not sentences reworded.

### 3. Origin stories are deleted outright

Where the code came from — a bash prototype, an earlier module, another project — tells a reader
nothing they can act on. `statusline.sh` line numbers cannot be followed; a port's fidelity cannot
be checked against a file that does not exist. The boundary rules such a comment states are kept;
the provenance around them goes.

### 4. An ADR citation is a footnote, never the explanation

**State the reason in terms the code can be checked against, then cite.** "A 9 pt dot and a 15 pt
glyph put their centres 3 pt apart" is verifiable at the call site and stays true however the ADR
corpus evolves; "centred on the dot's axis (ADR-0094)" tells the reader nothing until they leave.

With the reason carried locally, a stale citation costs a detour rather than a misunderstanding —
which is what the sampling found in practice. Citations are therefore **allowed in both the file
header and the body**, with no ceremony about which: 101 files cite ADRs today, 30 in the header
only, 26 in the body only, 45 in both, and forcing one shape would rewrite 71 files to save nothing.

What is *not* allowed is a comment whose meaning depends on the link.

### 5. No mechanism polices citation rot

A checker could report "this file cites ADR-0086, superseded by 0090" — the frontmatter is
machine-readable and the references grep cleanly. It is deliberately not built. Acting on such a
report means reading both ADRs to decide whether the cited clause is one of the superseded ones,
which for partial supersession is a judgment call, 381 times over. A gate that turns a silent
backlog into a loud one, without reducing it, is a gate that gets bypassed.

Rule 4 is the mitigation: a comment that carries its own reason degrades gracefully. Individually
misleading comments — the `MenuBarLayout.swift` case — are fixed as they are found.

### 6. `docs/adr/` is exempt

History is the product in an ADR. A record states what was decided at a date, and a supersession
postscript is the intended home for exactly the content rules 2 and 3 remove from code. ADRs are
also read on demand rather than dragged in alongside a file someone opened for another reason.

## Consequences

- **The recurring cost falls.** Every token removed from a comment is removed from every future read
  of that file.
- **Some reconstruction gets harder.** A reader who wants to know *why* a decision was made, and
  finds no ADR covering it, is left with `git log`. That is the trade: rules 2 and 3 assume the
  reasoning either matters enough to be an ADR or does not matter enough to be re-read forever.
- **The bar for writing an ADR rises slightly**, since it is now the only durable home for
  rationale that will not fit in a short comment.
- **Citation rot continues**, unmeasured and unpoliced, at roughly one misleading comment per
  sixteen stale citations. Rule 4 caps the damage at a wasted click.
- **Judgment is required per site.** None of this is greppable: `no longer` frequently describes
  current state, and a note that stops a false assumption ("there is no such state") is doing live
  work even though it names an absence.

## Verification

- `swift build` after each file: comment-only edits cannot change behavior, and a build proves it.
- The diff filtered to non-comment lines must be empty.
- Measure the win rather than the effort: comment tokens per file before and after. Counting edited
  sites is what produced the 0.05% pass.
