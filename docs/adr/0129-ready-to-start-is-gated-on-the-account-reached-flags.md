---
status: accepted
date: 2026-08-24
supersedes: [0127]
---

# ADR-0129: A Codex read that reports the limit reached at zero usage is malformed data, not a quota state

> **Supersedes part of §D13 of [ADR-0127](0127-codex-quota-from-the-app-server.md).** Only the last
> clause is replaced — "the row is Claude's idle shape", which assumed the detection's output is
> always a drawable row. A window that has not started is now drawn that way **only** when the
> account's reached flags agree; when they do not, no row is drawn at all. **The rest of D13 still
> stands in full**: the ±120 s detection, the one-sample rule, why no anchor is reconstructed, and
> why the raw epoch stays in Troubleshoot.

## Context

`account/rateLimits/read` carries two fields beside the windows, and both describe the **account**
rather than any one window:

```
spendControlReached:  Bool?      // null on the live Plus account probed
rateLimitReachedType: String?    // null on the live Plus account probed
```

[ADR-0127](0127-codex-quota-from-the-app-server.md) §D13 renders a window reading zero against a
horizon of its own length as `ready to start` — a green knobless bar and no detail line. That reads
the window's own numbers and nothing else.

Upstream documents accounts where those numbers lie.
[openai/codex#34360](https://github.com/openai/codex/issues/34360) and
[#36528](https://github.com/openai/codex/issues/36528) report accounts showing 100 % left while
actually rate-limited. So the pairing exists in the wild: the server says **the limit is reached**
and **nothing has been used**, in one answer, about one account.

Those two statements cannot both be true. That is the fact this record turns on, and it is what
makes the state different from every other one the plate draws.

## Decision

### D1. The pairing is a defect in the answer, not a state of the quota

A window at 0 % beside a raised reached flag is not an account in an unusual condition. It is a
payload that contradicts itself, and **neither number can be believed**: not the zero, because the
flag says work is blocked; not the flag, because the window says nothing has been spent.

So the treatment is the one the popup already gives a Claude body whose `resets_at` will not parse
(`UsageSnapshot.hasBrokenActiveReset`): **withhold the rows and show a warning**. It is not the
treatment for a limit that has genuinely been reached, because we do not know that it has.

The contradiction requires **both** halves. A raised flag beside a window at 100 % is an ordinary
reading — that is what a real limit looks like — and nothing about it is withheld.

### D2. No bar is drawn for a contradicted window, on either surface

`CodexQuotaNormalizer.rows(from:now:)` emits **no row** for it. Not a grey one, not a zeroed one,
not an idle one.

A bar is a scale, and every scale here is built from `utilization` and a horizon. Drawing one from
values we have just rejected renders a measurement out of numbers declared meaningless a line
earlier — and it does so in the app's most glanceable surface, where the qualifying sentence cannot
follow. The row is **replaced** by the warning block, not decorated.

Both surfaces read the one row array, so withholding the row in the model is also what keeps the bar
out of the menu bar. That is why the drop happens in the normalizer rather than in the view: a
view-side suppression would have to be written twice and could disagree with itself.

### D3. The popup shows the ⚠️ error block, not the dimmed one

The plate carries the same two-line shape the popup gives a failed poll: a bold red title led by
`exclamationmark.triangle.fill`, then a secondary detail line.

There is a nearby state that looks like a precedent and is not. `weeklyResetUnknown` also draws a
title plus a detail line with no bar — but **dimmed**, with `noDataSymbolName`, deliberately: nothing
is broken there, the API answered correctly and simply has not opened a window yet. Ours **is**
broken, so it takes the warning treatment. Copying the dimmed styling because the layout matches
would report a provider-side defect in the vocabulary of an expected empty state.

The block keeps the plate standing on its own. With every Codex status service off and no drawable
window left, dropping the plate would take the only explanation with it and leave the bars silently
missing.

### D4. The title names the fault as the provider's, and the detail states the contradiction

**`Codex reset time bug`**, over: *Codex reported the limit reached and zero usage at once — its
quota numbers cannot be trusted right now.*

"Limit reached" was rejected as a title because it describes a state of the **account** and would
send the user to wait out a reset that may not be coming. What actually happened is that the answer
is wrong, and the user's correct response is to distrust this plate — not to change how they work.

The detail states what the server said and stops. The app does not know **why** the backend answers
this way — upstream has open reports and no cause — so a sentence guessing at one would be
invention. There is no next step to offer either, which is the honest difference from
`weeklyResetUnknown`, whose detail line names the action that fixes it.

The menu bar speaks the same fault in the same words (`Codex: reset time bug, quota numbers
unavailable`), the rule `weeklyResetUnknownTitle` already follows. Nothing is **drawn** in the
widget: a glyph would claim width for a provider the widget cannot say anything true about. But
silence is exactly what a screen-reader user cannot distinguish from a provider that is switched
off, so speech carries what drawing does not.

### D5. The gate itself: `nil` is unavailable, and any non-empty reached type counts

`spendControlReached` gates on `== true` only. `false` and `nil` both leave the read consistent,
for different reasons — `false` is the server saying no spend stop, `nil` is the server saying
nothing — and neither is grounds to withhold anything.

`rateLimitReachedType` gates on **any non-empty string**. The vocabulary is the server's and will
grow; a word we have not met is a reached state we have not met, not silence. Matching a known list
would make each new server word fail open, which is the bug's own failure direction.

Both are `try?`-decoded, so a wrongly-typed field costs the flag and leaves the windows intact. That
drops the gate as well — safe only because a dropped flag reads as unavailable rather than as
`false`: an unreadable answer never becomes permission.

## Consequences

- **A green `ready to start` now rests on the whole payload agreeing with itself**, not on one
  window's numbers. On a degraded backend that can withhold a row from an account that is fine — a
  flag stuck `true` server-side costs the user a bar they could have had. That is the deliberate
  direction: a missing bar with an explanation costs a glance, a wrong green bar costs the attempt.
- **The Codex plate can now show a warning where a bar was**, which no satellite plate did before.
  Its wording is the popup's failure vocabulary applied to a provider whose failures previously only
  reached Troubleshoot.
- **No live coverage exists for this state.** Both fields are `null` on the probed account and the
  pairing cannot be produced on demand — an account has to actually hit a limit *and* the backend has
  to answer wrongly. It rests on the stub and the unit tests, and the first live sighting will be in
  the dev quota log.
- **A partly-contradicted read still draws.** With two windows reported and only one contradicted,
  the surviving row keeps its bar and the warning sits above it. That is deliberate — the other
  window's numbers were never in question — but it does mean the plate can carry a "cannot be
  trusted" line above a bar the user is meant to trust.
- **This adds no history and no multi-poll state.** One payload in, one decision out, as D13
  requires. Confirming the contradiction across polls was refused for the same reason
  ([#519](https://github.com/artem-from-ua/tokenpace/issues/519), closed as wontfix), and it would
  buy nothing here: the contradiction is visible within a single answer, not inferred from a trend.

## Alternatives considered

- **Recolouring the row grey and reading `waiting for limit reset`**, reusing Claude's blocked idle
  shape. **This was built first and rejected by the maintainer on sight**, and the reasoning that
  produced it was wrong in a way worth recording, because it looks right. Claude's `sessionBlocked`
  is a **5-hour** row that is genuinely empty, blocked by a *separate* exhausted 7-day window: two
  windows, one honestly at zero (hence the grey scale) and one exhausted (hence the block). Grey
  there is a truthful bar. **Codex has one window.** With it flagged reached at 0 % there is no
  second empty bar to colour neutrally — the grey would be painted over the very number in dispute,
  and the row would assert a scale the read cannot support. The asymmetry is the whole point: the
  same visual borrowed across providers means different things because the payloads differ in shape.
- **A bare percentage with the reset line restored.** The reset is the sliding value D13 exists to
  suppress, and the percentage is the disputed number.
- **Hiding the plate entirely.** Indistinguishable from a provider that is off, and it discards the
  explanation.
- **The dimmed `weeklyResetUnknown` styling.** Reserved for a state where nothing is broken (D3).
- **Reading `nil` as `false`.** The exact error the bug is made of (D5).
- **Matching `rateLimitReachedType` against a known list.** Each new server word would fail open
  (D5).
- **Suppressing every bar on a flagged account**, rather than only the contradicted windows. An
  anchored window beside a raised flag is a consistent, ordinary reading (D1).
- **Confirming the contradiction across two polls** before acting on it ([#519](https://github.com/artem-from-ua/tokenpace/issues/519)).

## Verification

- `codex-quota-reached` ⏱ — the not-started reading with `rateLimitReachedType` set and
  `spendControlReached` left `nil`, so the scenario also proves the string alone triggers the fault.
  The frame proves three things: **no bar on the plate** for that window, the red ⚠️ block in its
  place, and **no Codex bar in the menu bar**. Run beside `codex-quota-not-started` — identical
  numbers, one draws a green ready-to-start bar and this one draws none.
- Unit tests: absence is not a reached account; either flag alone counts; an unknown word counts and
  an empty string does not; the contradiction needs both halves (a flag beside a spent window is
  ordinary); a contradicted window yields no row at all; the withheld row is absent rather than
  recoloured; the unflagged row stays `ready to start`; an anchored row is untouched; a multi-window
  read loses only the contradicted rows; the read contributes no menu-bar block; and the widget
  speaks the fault it does not draw.
- Live, `TOKENPACE_STUB=real` against the maintainer's account: it is anchored, so `hasNotStarted`
  is `false`, the contradiction cannot arise, and this record changes nothing there. That is the
  check — the ordinary path renders exactly as before.

## Related

- [ADR-0127](0127-codex-quota-from-the-app-server.md) — the collector and §D13, whose last clause this replaces
- [ADR-0043](0043-unified-reset-line-and-remove-resetnow.md) — home of `hasBrokenActiveReset`, the Claude-side malformed payload whose treatment this borrows
- [ADR-0107](0107-weekly-reset-reconstructed-from-the-last-known-one.md) — `weeklyResetUnknown`, the nearby state that is deliberately *not* an error
- [users-and-goals.md](../reference/users-and-goals.md) — the "would the user act differently" test D4's wording is argued against
- [#518](https://github.com/artem-from-ua/tokenpace/issues/518), [#519](https://github.com/artem-from-ua/tokenpace/issues/519), [#520](https://github.com/artem-from-ua/tokenpace/issues/520)
