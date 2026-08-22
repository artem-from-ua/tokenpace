---
status: draft
date: 2026-08-22
supersedes: []
superseded_by: []
---

# ADR-0122: Comments are priced per read

> Lineage: [ADR-0116](0116-english-as-documentation-language.md) fixed the *language* of the
> corpus; this record fixes its *volume*, the rules for pointing from code into `docs/adr/`, and how
> to trim at scale without losing facts.
> [#489](https://github.com/artem-from-ua/tokenpace/issues/489) is the cleanup it authorizes,
> [#490](https://github.com/artem-from-ua/tokenpace/pull/490) the pass that ran against it.

> **Draft — not yet accepted.** Parts were decided by the maintainer in review, parts were not.
> His: rule 2's scope ("a comment describes the current behavior — only that"), rule 4 in its
> current form (an earlier draft said *link the ADR instead of retelling it*; he rejected it), and
> the issue-number clause. Mine, pending review: the per-read framing, rule 3, the decision in
> rule 5 not to build a checker, and recording any of this as an ADR at all. The pass already ran
> against these rules, so accepting ratifies work that is done; rejecting a rule means revisiting
> that work, not only this file.

## Context

Comments here are unusually thorough, and that was the right instinct while the architecture moved
every week: a paragraph explaining why a constant is 14 and not 10 has repaid itself many times.

What changed is who reads them, and how often. Every session — the maintainer's, an agent's — loads
these files into a context window and pays for every byte, usually while looking for something else.

| | Tokens |
|---|---|
| Comments in `Sources/` | **~312 000** |
| Code in `Sources/` | ~172 000 |

**47% of lines are comments and they occupy 64% of the bytes.** `PopupViewController.swift` spends
~45 000 tokens on prose against ~22 000 on code; `PacingModel.swift` is 82% comment.

The prose is not padded — it is dense, and much of it documents a past. `PacingModel.elapsedFraction`
carried 19 lines of comment over 5 lines of code: three stated the boundary rules, the rest described
a port from `statusline.sh` down to that file's line numbers. **`statusline.sh` is in neither the
repository nor its git history** — an external prototype, unreachable.

A second question arrived with it: should comments cite ADRs at all, when ADRs get superseded and
nothing warns the citing comment? Of 76 ADRs cited from code only **28** are current in full; 74
references point at fully superseded records and 381 at partially superseded ones. Sampling 16 of
them found **14 still accurate** — comments cite an ADR's architectural core, and supersession
preserves exactly that core, while the postscripts sit at the top of the file where an arriving
reader meets them first. One misleads: `MenuBarLayout.swift` described eliding the 7-day bar "when
the user picked it", a three-way choice [ADR-0090](0090-menu-bar-answers-can-we-work.md) removed.

## Decision

### 1. A comment is priced per read, so length is a cost

Write the shortest comment that answers what the next editor must know. Where a paragraph and a
sentence carry the same information, the sentence is correct.

### 2. A comment describes the current behavior — only that

Not what the code used to do, not what a constant was before, not which issue changed it. When a
sentence starts with *used to* / *previously* / *was removed*, rewrite it in the present tense: if a
fact survives, keep the fact and drop the history; if nothing survives, delete the sentence.

**Deleting beats rewording.** A pass over 37 sites that rephrased history into the present while
preserving length moved total volume by 0.05%. The genre improved; the cost did not.

### 3. Origin stories are deleted outright

Where the code came from — a bash prototype, an earlier module, another project — cannot be acted
on. A port's fidelity cannot be checked against a file that does not exist. Keep the boundary rules
such a comment states; drop the provenance around them.

### 4. A citation is a footnote, never the explanation

**State the reason in terms the code can be checked against, then cite.** "A 9 pt dot and a 15 pt
glyph put their centres 3 pt apart" is verifiable at the call site and stays true however the ADR
corpus evolves; "centred on the dot's axis (ADR-0094)" says nothing until the reader leaves, and
says something wrong once that ADR is superseded in part.

With the reason carried locally, a stale citation costs a detour rather than a misunderstanding.
Citations are therefore allowed in both the file header and the body: 101 files cite ADRs today, 30
in the header only, 26 in the body only, 45 in both, and forcing one shape would rewrite 71 files to
save nothing. What is *not* allowed is a comment whose meaning depends on the link.

**Issue numbers clear a lower bar.** `(#167)` after a claim decorates rather than explains, rots the
same way, and `git blame` answers more precisely — it lands on the commit that wrote the line, not a
ticket that covered five other things. Drop them when trimming; keep one where it is the only route
to a discussion the code cannot carry.

### 5. No mechanism polices citation rot

A checker could report "this file cites ADR-0086, superseded by 0090" — the frontmatter is
machine-readable and the references grep cleanly. It is deliberately not built: acting on that
report means reading both ADRs to decide whether the cited clause is one of the superseded ones, a
judgment call 381 times over. A gate that makes a backlog loud without making it smaller gets
bypassed. Rule 4 is the mitigation; individually misleading comments are fixed as they are found.

### 6. Never leave an orphaned token

Before deleting a sentence carrying a **number with a unit**, a **symbol name**, or the word
*measured*/*verified*, grep for that token. If it survives elsewhere, delete freely. If it does not,
keep the sentence or move the token into its replacement.

The failure is not "a fact was lost" but "a fact was lost while the text depending on it stayed",
which reads as correct and is not. After one trim, `agent-workflow.md` still said "the same `Δphase`"
and "phase 3" while `quarter-point` had zero hits left in the repository — in a section about a
0.075 pt effect. A reader cannot tell that a unit is missing; they conclude the fault is theirs.

### 7. Cross-references come in pairs; fix both ends or neither

When a document names a file and that file names the document back, the two are one fact stored
twice, and repairing one end silently breaks the other. `releasing.md` was corrected to point at
`BarStyle.displayName`; `AppearancePanes.swift` went on claiming the titles are grepped out of
itself. Grep for the counterpart before committing the fix.

### 8. Don't state a count you would have to maintain

"18 named roles" above an enum breaks the next time a case is added, and it buys nothing — the enum
is right there, and anyone who needs the number counts it. A trim found that comment saying 18 while
the enum held 20, in both the code and the doc that mirrored it. Write "named roles".

The test is whether the claim can be kept true for free. A measurement nobody can re-derive is worth
its maintenance; a number the reader can see for themselves is not.

### 9. Any path or command written in prose must be executable

`releasing.md` carried a `grep` recipe against `Sources/TokenPace/Settings/UIPanes.swift`, a file
that had not existed for months. Nothing failed until someone tried to cut a release. A path, a
filename, a shell snippet or an env var in documentation is an assertion about the tree, and
assertions rot silently. Run them.

### 10. Audit a large trim by filtering, not by reading

Seventy of the pass's 748 hunks were audited by nine reviewers at high effort: **0 critical losses,
6 minor, 64 clean**. Reviewing all 748 that way costs roughly ten times the edit. It is also
unnecessary — every real loss fell into a small, greppable class.

Cheapest step first:

1. **Free.** Extract the deleted lines; keep only those matching a risk signal — a measurement with
   a unit, a `Type.member` symbol, a negative instruction (*do not* / *never* / *must not*),
   *measured*/*verified*, or a statement that something does not exist. On this pass: 616 lines out
   of 5 755. Grep whether each token survives anywhere; drop the ones that do. That left **7
   candidates, all false positives** — symbols the diff wrote qualified (`ColorTweenSet.pruneStale`)
   and the code writes bare.
2. **Cheap.** What survives goes to a small model at low effort, in one batch, judged from the line
   alone: fact or narration?
3. **Expensive, and only now.** The remainder goes to a high-effort reviewer with the file open.

### 11. Sample deliberately, and state what the sample was

The first audit drew one hunk per file, reported 0 critical losses, and its own reviewer then
observed the sample was favourable: the files it happened to hit were the ones with ADR coverage.
The second was widened on that advice — documentation, the pure-logic layer, two to three hunks per
file. An audit that does not describe its selection is not evidence.

### 12. `docs/adr/` is exempt

History is the product in an ADR. A record states what was decided at a date, and a supersession
postscript is the intended home for exactly the content rules 2 and 3 remove from code. ADRs are
also read on demand, not dragged in beside a file opened for another reason.

## Consequences

- **The recurring cost falls.** Every token removed is removed from every future read.
- **Some reconstruction gets harder.** A reader wanting to know *why*, with no ADR covering it, is
  left with `git log`. Rules 2 and 3 assume the reasoning either matters enough to be an ADR or does
  not matter enough to be re-read forever.
- **The bar for writing an ADR rises**, since it becomes the only durable home for rationale too
  long for a short comment.
- **Citation rot continues**, unmeasured, at roughly one misleading comment per sixteen stale
  citations. Rule 4 caps the damage at a wasted click.
- **The corpus's redundancy is load-bearing, and now known to be.** Nine reviewers found that a
  duplicate elsewhere — a type-level doc, a neighbouring declaration, a test, an ADR — is what made
  most deletions survivable. That is a reason for more care in thinly documented areas, not for
  removing the duplication: a second copy in a *test* is a different thing from a second copy in
  prose.
- **Rules 7 and 8 want a checker and do not have one.** Both are mechanical, and
  `scripts/check-doc-links.py` proves the shape works. Until one exists they rely on the author
  remembering, which is the failure mode they describe.
- **Judgment is required per site.** None of this is greppable: `no longer` usually describes
  current state, and a note that stops a false assumption ("there is no such state") does live work
  even though it names an absence.

## Verification

- `swift build` after each file, and the diff filtered to non-comment lines must be empty.
- Rule 6: run the risk-signal grep over the trim's own diff before committing.
- Rule 8: for each path in a changed doc, test that it resolves; for each command, run it.
- Rule 9: report the counts at each step, so a step that filtered nothing is noticed.
- Measure the win in comment bytes per file, not in sites edited — counting sites is what produced
  the 0.05% pass.
