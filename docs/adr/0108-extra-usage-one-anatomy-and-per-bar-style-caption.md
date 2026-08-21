---
status: accepted
date: 2026-08-18
supersedes: []
superseded_by: []
---

# ADR-0108: "Extra usage" has one anatomy for every state, each bar labels its own scale under ⌥

> Extends [ADR-0098](0098-ruler-split-identify-always-explain-on-option.md) (the ruler split
> "identify always / explain under ⌥") into the **wording** layer, but **supersedes its labels** —
> `0` and the month edges (see §6). Supersedes the marker's **anatomy** from
> [ADR-0068](0068-credits-in-use-marker-anatomy.md): `PillView` stays, but the marker moves to the
> **right** half, changes its fill to the neutral `barTrack`, and is **no longer a knockout** — its
> ink is now plain `label`.
> The popup width, pinned by [ADR-0083](0083-live-dropdown-preview-in-settings.md) as "312 pt,"
> becomes one constant shared by both surfaces.

## Context

The "Extra usage" section drew a **different shape for every state**, and none of them named
itself.

Three separate observations that turned out to be one problem
([#396](https://github.com/artem-from-ua/tokenpace/issues/396)):

1. **The badge sat next to the wrong thing.** The `[$]`/`active` marker sat in the leading half,
   right after the word `Extra usage` — that is, the marker for **money** sat next to the **row's
   name**, not next to the amount or the verdict.

2. **Two of the three balance states had no marker at all.** `inUse` is
   `enabled && !spend_limit_reached && baseLimitExhausted` (`CreditsPacing.isSpending`). So a user
   with credits enabled that aren't covering anything yet, and a user with an **exhausted** balance,
   saw the **same** row — with no badge at all. The second case is the worse one: an exhausted
   balance means the exhausted plan is now actually blocking work.

3. **The unlimited row had a different anatomy.** With `limit: null` there's no bar and no reset,
   and the amount became a **status** in the right half of the header:
   `Extra usage … €10.8 spent`. One row instead of two, the number not in the column where numbers
   sit in every other section. Plus the word `spent` sat **at the end** without ⌥ and **at the
   start** under ⌥ (`€10.8 spent` → `spent €10.77`) — jumping around the row when the modifier was
   pressed.

In parallel — a fourth, independent gap: **the bar style is named nowhere**. The user has three
styles (`Pressure`/`Gauge`/`Progress`), and the popup says not a word about which one is active; it
can only be identified by shape. And it's worst on exactly the credit bar: it's **always** Progress
regardless of the setting ([ADR-0092](0092-extra-usage-own-ruler.md)), so in a column of Pressure
strips it reads as a glitch.

## Decision

### 1. One anatomy for every state

Every state of the section draws **the same two rows**:

```
Extra usage  progress ......... [badge] status
spent $10.77 of $15.00 ........ resets in 5d on Friday
```

The unlimited row gets a **second row** with the amount where numbers sit in every other section,
and `no limit set` in the status slot: this is **a billing configuration**, not a verdict, because
without a ceiling there's no pace to be "on" in the first place. It gets no style word — there's no
bar, nothing to name.

`addDetailLine` accepts an optional `reset` and follows the same path the fit gate already uses to
drop the right half — both shapes are rendered by one code path, not two layouts.

### 2. The state badge — into the right half, and only where it adds something

The badge moves next to the status word and qualifies it: `[$] well ahead of pace` reads as one
sentence.

| State | Badge | Color |
|---|---|---|
| money is moving right now (`credits.inUse`) | `[$]` → `active` under ⌥ | neutral gray (`barTrack`) |
| ceiling spent, **a cap exists** (`usageFraction >= 1`) | **none** — red is on the reset badge below | — |
| ceiling spent, **no cap** (`spendLimitReached`) | `out of credits` | red (`gapRed`) |
| enabled, nothing being spent | **none** | — |

**One solid red per row, and it's on the thing you're actually waiting for.** When a cap exists,
you're waiting for the **reset** — that's where the red capsule sits
(`resetIsBlocking`, [#158](https://github.com/artem-from-ua/tokenpace/issues/158)), and the header
says `limit reached` in plain text. When there's no cap, there's no reset (with no ceiling there's
nothing to reset), so the header itself is the only carrier of red. Both used to be drawn at once;
that spent the popup's one alarm color twice on one fact.

**There's no `available` badge.** An attempt to show the calm state as a separate gray capsule
survived exactly until the first live render: it repeated three things the row already says — the
section **doesn't even get built** without active credits (`CreditsPacing.isActive`,
`PopupLayout.creditsRow`), so its mere presence means "enabled"; the absence of red means "not
exhausted"; the absence of a badge means "nothing is being spent." A capsule whose value is "nothing
is happening" is exactly what empty space is for. It also happened to be the popup's **widest**
badge, and it set the window's width for a state in which nothing is happening.

**The `in use` capsule is gray, with `label` ink.** In accent color it read exactly as loud as the
blocking-reset badge next to it, putting "money is moving" (a fact) in the same visual class as
"you're blocked" (a problem). The fill became `barTrack`, and **knockout** dropped along with it:
cutting a hole through a light gray means showing a card of almost the same tone, so the glyph
wouldn't read — it would just fade. Plain `label` ink on gray is the same relationship every other
row has to the card ([ADR-0068](0068-credits-in-use-marker-anatomy.md) described exactly this
knockout — that part is superseded).

### 3. Each bar labels its own scale — under ⌥

Every section's header row carries the style word in the same dim ink as the supporting numbers:
`5-hour  gauge … on pace`.

Two rules, each of which one shared label in the header would violate:

- **Only under ⌥.** The word **explains**, it doesn't identify, and
  [ADR-0098](0098-ruler-split-identify-always-explain-on-option.md) puts explanation on the
  modifier: the zero tick already identifies the scale at a glance, and repeating one global setting
  on every row would be noise at rest.
- **From the scale that's actually drawn, not from `barStyle`.** The credit row labels itself
  `progress` even under Pressure; a label taken from the setting would lie exactly where it's the
  one thing explaining a row that looks unusual.

The word lives in `BarStyle.displayName` (kit), with `caption` as its lowercase form. The Settings
segments read **the same** property instead of their own literals:
[#387](https://github.com/artem-from-ua/tokenpace/issues/387)/[#388](https://github.com/artem-from-ua/tokenpace/issues/388)
propose renaming Gauge, and two literals would mean two half-renames.

**Lowercase — only in the popup.** There it's an annotation next to the row's name, and Title Case
would read as a second heading competing with the section's own name; in Settings the same word
labels a **control** and stays Title Case, like every other segment.

### 4. The plan label — on the same ⌥ layer

At rest, the header is a bare `Claude` mark. Under ⌥, **the whole tail** returns at once:
`Claude ･ Max (20x) ･ just now`.

The plan label and the age travel together because they answer questions of the same class — "which
plan is this" and "how fresh are these numbers" — asked once, not tracked continuously. At first,
only the label was hidden under ⌥ while the age stayed visible; then the header changed shape
**twice** on one modifier, and the dot before `just now` hung at rest with nothing to its left.

The separator is the same `･` used inside the label, so the whole popup uses one piece of
punctuation, not a different mark in every spot.

### 5. Width — 380 pt, one constant shared by both surfaces

The content column goes from 252 → **320 pt** (`380 − 2·14 cardInset − 2·16 hPadding`). It's dictated
by the widest row that **must** fit: `Extra usage ･ progress … [active] well ahead of pace` =
**307 pt** at 13 pt.

The **details** row can be wider (`spent $5,000.00 of $5,000.00` with the longest reset — 321 pt)
and doesn't set the width: overflow is the fit gate's normal job, and it drops the reset by design.
Only what has no right to fail to fit sets the width.

390/330 was tried first — sized for the `available` badge, which was later removed (§2); once it
was gone, the widest mandatory row got 15 pt narrower, and the window moved back down.

An alternative was to **shorten the phrases** (`well ahead of pace` → `well ahead`, −49 pt), but
they're shared verbatim with the token rows — shortening them for the credit row's sake would change
the wording on every bar, while shortening only here would produce different wording on neighboring
rows.

The width lives in `PopupViewController.popupWidth`, from which both `Metrics.width` and
`SettingsPreviewWindowController.Metrics.nominalWidth` read it. Previously these were **two
literal `312`s**, meaning the preview could silently open at a different width than the popup it's
showing.

### 6. Ruler labels are removed — only the ticks remain

Partially supersedes [ADR-0098](0098-ruler-split-identify-always-explain-on-option.md) and
[ADR-0092](0092-extra-usage-own-ruler.md): the `0` label under the zero tick, and the month-edge
labels (`Jan 1` / `Feb 1`) on the credit bar, are **removed**.

Each one was saying out loud what its own mark already shows: the tick **is** the zero, and the
month dates already sit on the reset line right above the bar. This was a second way of saying the
same thing — exactly the class of decision the cross-cutting principle warns against ("the value is
the model's input; color and verdict are its output").

The second reason is **rhythm**. The labels sat *under* the bar, right where the next section's
header begins, so holding ⌥ added half a line of text to every row, and the popup's composition
changed along with the modifier. An explanatory layer should add words **inside** a row, not between
rows.

**The ticks stay:** they divide the window into fractions — a fact nothing else in the row provides.

Consequence for the geometry: the credit bar is no longer taller than the others by one text line
(`creditsViewHeight` is removed along with the label metrics), and the card's bottom inset is
slightly tightened (12 → 8 pt) — those 12 were sized precisely to keep the words off the rounded
edge.

## Consequences

- **The fit gate fires less often — deliberately.** At 320 pt, ordinary ⌥ rows (`spent €10.77 of
  €15.00` + `resets in 5d on Friday`, 281 pt) **keep** both halves — previously, at 252 pt, they lost
  the reset. The gate remains for four-digit amounts: `spent €1,234.56 of €2,000.00` (322 pt) sits
  just past the column's edge, and a ceiling with the longest reset phrase (376 pt) sits well beyond
  that. This is documented in **three** places that had to be rewritten alongside the change: the
  `credits-wide-amounts` stub's blurb, the `detailHalvesFit` calibration table, and
  [ui-verification.md](../guides/ui-verification.md).
- **The incident-text width** goes from 233 to 301 pt, so where each name wraps has shifted, and the
  row with it. The expectations in `scripts/check-incident-chip-alignment.swift` were recaptured
  **from the actual render**, not predicted.
- **Three mirror scripts** (`check-detail-line-fit`, `check-incident-chip-alignment`,
  `check-badge-column`) were measuring a popup that no longer existed: `cardInset` 8 versus 14,
  `hPadding` 14 versus 16, an 8/8 point versus 9/10 — a 268 pt column instead of the real 252. Fixed
  in a separate commit **before** the width change, so it's visible what's broken right now, apart
  from what the ticket changes. None of them run automatically (there's no `.github/`, and the
  pre-commit hook only does build+test) — which is exactly how the drift lived unnoticed.
- **No test exists, or can exist, for popup geometry:** `PopupViewController` lives in the
  `TokenPace` executable target, which `TokenPaceKitTests` doesn't import. That's why the style label
  was put in the kit — `BarStyle.displayName`/`caption` — and it's the only part of this change with
  unit coverage (`BarStyleTests`). Everything else is checked by scripts and live stubs.
- **Three new stubs** mark boundaries and previously unreachable states: `credits-max-header` (the
  widest first row, 307 pt against 320), `credits-max-detail` (the widest second row, which the gate
  still drops), and `credits-no-limit-spent` (unlimited with an exhausted balance — the only state
  where the red badge sits in the header). The last one also required a fix to the stub layer itself:
  **every** credit frame hardcoded `seven_day: 100%`, so the base limit was always exhausted, and the
  state "credits enabled but covering nothing" was **unreachable** in the stubs.

## Open questions

Whether Anthropic's billing zeroes the `used` counter on the 1st of the month when there's **no**
cap set isn't visible from our code: `resetLine`, `resetLineVerbose`, and `monthBounds` are all
gated on `bar == nil`, and the amount arrives as a ready-made number from the server. Until this is
confirmed against real data, the unlimited row promises nothing about the month — it only says
`no limit set` and shows the amount.
