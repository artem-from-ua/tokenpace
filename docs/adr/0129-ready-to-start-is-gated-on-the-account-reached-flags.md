---
status: accepted
date: 2026-08-24
supersedes: [0127]
---

# ADR-0129: `ready to start` is gated on the account's reached flags, not on the window alone

> **Supersedes part of §D13 of [ADR-0127](0127-codex-quota-from-the-app-server.md).** Only the last
> clause is replaced — "the row is Claude's idle shape", which named exactly one shape. It now names
> two, chosen by the account's reached flags. **The rest of D13 still stands in full**: the ±120 s
> detection, the one-sample rule, why no anchor is reconstructed, and why the raw epoch stays in
> Troubleshoot.

## Context

`account/rateLimits/read` carries two fields beside the windows, and both describe the **account**
rather than any one window:

```
spendControlReached:  Bool?      // null on the live Plus account probed
rateLimitReachedType: String?    // null on the live Plus account probed
```

[ADR-0127](0127-codex-quota-from-the-app-server.md) §D13 renders a window reading zero against a
horizon of its own length as `ready to start` — Claude's idle shape, a green knobless bar and no
detail line. That reads the window's own numbers and nothing else.

Upstream documents accounts where those numbers lie.
[openai/codex#34360](https://github.com/openai/codex/issues/34360) and
[#36528](https://github.com/openai/codex/issues/36528) report accounts showing 100 % left while
actually rate-limited. A spotless window is a claim about the window, not a promise that the next
request succeeds — and the widget exists to answer *can I work right now*
([users-and-goals.md](../reference/users-and-goals.md)). Saying **yes** over a server that has
already said no is the worst answer it has: every other error costs the user a re-read, this one
costs them the attempt.

Two things about the fields shape the decision. They are **account-level** while `hasNotStarted` is
a method on a window, so there is a level mismatch to resolve rather than a condition to add. And
`spendControlReached: null` means **unavailable**, not `false`, per OpenAI's own model — decoding
absence as "you are fine" would silently downgrade "we do not know" into "go ahead", which is the
same class of error as the bug.

## Decision

### D1. The predicate lives on the snapshot, and the two levels meet in the normalizer

`CodexQuotaSnapshot` gains `isReachedFlagged`, and `CodexQuotaNormalizer.rows(from:now:)` — which
already takes the whole snapshot — reads it once per read and hands the answer to the row builder.
`CodexQuotaWindow` learns nothing new.

The alternative is to copy the account fact onto every window at normalization time so
`hasNotStarted` can consult it. That is worse in a specific way rather than merely untidy: it makes
it *representable* for two windows off one read to disagree about whether the account is blocked, a
state the server cannot produce and nothing downstream could resolve. Keeping the fact at the level
it arrives at means the disagreement has nowhere to live.

It also keeps `hasNotStarted` answering one question. Its whole justification in D13 is that it is a
pure function of one window's three fields, and a fourth argument that changes the *word* without
changing the *detection* would blur what the method is for.

### D2. A flagged account draws the blocked idle row, not a percentage and not a suppressed row

The row keeps its shape — `sessionIdle: true`, no detail line — and takes `sessionBlocked: true`,
which the view already answers with a **grey** knobless bar and the words `waiting for limit reset`.
The menu-bar block goes grey with it and VoiceOver reads `waiting for reset`, both through paths
that already existed.

That wording was chosen on the Claude side to be neutral about *which* limit blocks — the blocker
there can be the weekly window or a reached credits cap — and that neutrality is exactly what lets a
Codex spend stop borrow it unchanged. The user learns what to do (wait) without the row claiming to
know a reset instant it does not have.

The alternatives were weighed against the "is there an action the user would take differently" test
([users-and-goals.md](../reference/users-and-goals.md)):

- **A bare `0%` with the reset line restored.** The reset is the sliding value D13 exists to
  suppress, and `0%` is the model's *input* shown next to nothing — the reader is asked to redo the
  computation and would reach the same wrong conclusion the encouraging word gave them.
- **Hiding the row.** A missing row is indistinguishable from a provider that is off or failing, and
  it removes the one place the state could be explained.
- **A new status word of its own** — `blocked`, `limit reached`. It says the same thing in a second
  dialect, and the row would then read differently from Claude's identical state two plates up.

### D3. `nil` is unavailable; any non-empty `rateLimitReachedType` is a reached state

`spendControlReached` gates on `== true` only. `false` and `nil` both leave the row encouraging,
which is correct for different reasons — `false` is the server saying no spend stop, `nil` is the
server saying nothing — and the row's behavior is the same either way, so the two need not be told
apart here.

`rateLimitReachedType` gates on **any non-empty string**. The vocabulary is the server's and will
grow; a word we have not met is a reached state we have not met, not silence. Matching a known list
would make each new server word fail open, which is the bug's own failure direction.

The two are `try?`-decoded, so a wrongly-typed field costs the flag and leaves the windows intact.
That drops the gate as well — safe only because a dropped flag reads as unavailable rather than as
`false`: an unreadable answer never becomes permission.

### D4. The gate reaches the not-started row and nothing else

An anchored window keeps its percentage, pacing, bar and countdown while the account is flagged.
Every one of those stays true — the window really is 62 % spent, the reset really is where it says —
and a flag that suppressed them would remove information the user acts on to fix an encouraging word
that is not being drawn.

## Consequences

- **The encouraging state is now rarer than the window's numbers alone would make it**, and on a
  degraded backend it can be rare wrongly: a flag stuck `true` server-side leaves the row grey while
  the account is fine. That is the deliberate direction. A wrongly grey row costs a user one
  attempt they could have made; a wrongly green one costs them the attempt they make and lose.
- **No live coverage exists for the flagged state.** Both fields are `null` on the probed account
  and the state cannot be reached on demand — an account has to actually hit a limit. It rests on
  the stub and the unit tests, and the first live sighting will be in the dev quota log rather than
  on screen.
- **The blocked word arrives on a plate that has never drawn it.** Claude's blocked idle row needs
  an exhausted week *and* credits that cannot cover; Codex's needs one flag. Same words, different
  preconditions, and a reader comparing the two plates will not see that.
- **This adds no history and no multi-poll state.** One payload in, one row out, as D13 requires.
  Confirming a flag across polls was refused for the same reason
  ([#519](https://github.com/artem-from-ua/tokenpace/issues/519), closed as wontfix): the machinery
  costs state the quota has nowhere to keep, and the flag is the server's own assertion rather than
  a value we are inferring.

## Alternatives considered

- **Plumbing the flags onto `CodexQuotaWindow`** so `hasNotStarted` could consult them. Makes an
  impossible disagreement representable (D1).
- **A fourth parameter on `hasNotStarted(now:)`.** Changes the word without changing the detection,
  which is not what that method answers (D1).
- **Reading `nil` as `false`.** The exact error the bug is made of (D3).
- **Matching `rateLimitReachedType` against a known list.** Each new server word would fail open
  (D3).
- **Suppressing the bars entirely on a flagged account**, the way a failed read drops them. A flag
  is not a failed read: the windows decoded fine and their numbers are worth drawing.
- **Confirming the flag across two polls** before acting on it (D-consequences, [#519](https://github.com/artem-from-ua/tokenpace/issues/519)).

## Verification

- `codex-quota-reached` ⏱ — the not-started reading with `rateLimitReachedType` set and
  `spendControlReached` left `nil`, so the scenario also proves the string alone gates the row. Run
  beside `codex-quota-not-started`: identical numbers, opposite verdicts, the flag the only
  difference. The stub sets only the string deliberately — one setting both would pass even if only
  the `Bool` were consulted.
- Unit tests over the gate: absence is not a reached account, either flag alone counts, an unknown
  word counts and an empty string does not, the flagged row goes blocked while the unflagged one
  stays ready, an anchored row is untouched, the flag reaches every not-started window in a
  multi-window read and no other, and the blocked row survives into the menu-bar block and its
  spoken label.
- Live, `TOKENPACE_STUB=real` against the maintainer's account: it is anchored, so `hasNotStarted`
  is `false` and this record changes nothing there. That is the check — the ordinary path renders
  exactly as before.

## Related

- [ADR-0127](0127-codex-quota-from-the-app-server.md) — the collector and §D13, whose last clause this replaces
- [ADR-0027](0027-session-idle-no-phantom-reset.md) — the idle shape both providers now share
- [users-and-goals.md](../reference/users-and-goals.md) — the "would the user act differently" test D2 is argued against
- [#518](https://github.com/artem-from-ua/tokenpace/issues/518), [#519](https://github.com/artem-from-ua/tokenpace/issues/519), [#520](https://github.com/artem-from-ua/tokenpace/issues/520)
