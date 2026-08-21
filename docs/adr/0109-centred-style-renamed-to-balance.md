---
status: accepted
date: 2026-08-19
supersedes: []
superseded_by: []
---

# ADR-0109: The centered bar style is called **Balance**, not Gauge

## Context

The zero-in-the-middle style ([ADR-0079](0079-centred-zero-gauge-scale.md)) was called **Gauge**
starting with [#326](https://github.com/artem-from-ua/tokenpace/issues/326). The name has a flaw
that only shows up next to its neighbor: **`gauge` is the generic name for an instrument, and a
pressure gauge is a gauge too**. In the row `Pressure · Gauge · Progress`, the second word is a
**hypernym** of the first, so the most natural guess is that Gauge is some variant display of that
same pressure.

The actual relationship is the reverse in scope: `BarLayout.pressureLength` is literally
`max(0, balanceOffset)` — Pressure **is half** of this scale
([ADR-0101](0101-pressure-is-the-gauge-ahead-half.md)). So the name did not just fail to explain
itself — it pointed the wrong way.

This is a specific case of the principle from
[#381](https://github.com/artem-from-ua/tokenpace/issues/381): **a name describes the behavior the
user picks, not the mechanism it is implemented with**. `Gauge` is literally the mechanism (an
instrument); `Balance` is the behavior.

The naming discussion is [#387](https://github.com/artem-from-ua/tokenpace/issues/387); the
implementation is [#388](https://github.com/artem-from-ua/tokenpace/issues/388).

## Decision

**`BarStyle.gauge` → `BarStyle.balance`, `rawValue` `"gauge"` → `"balance"`, the UI label
`Gauge` → `Balance`.** Along with them: `BarLayout.gaugeOffset` → `balanceOffset` and the stub
`gauge-sweep` → `balance-sweep`.

### Why `Balance` specifically

A balance scale is the one everyday object whose **resting state is the middle**, so "zero in the
middle, deviation to either side" lands without any explanation needed. This is the same logic
[ADR-0076](0076-pressure-scale-for-marker-less-bar.md) used when it picked `Progress`: the name
must **confirm** the reading, not fight it.

Considered and rejected: `Drift` (accurate but passive — "drift" is something that happens to you
slowly, whereas the ahead-half is about urgency), `Balanced` (an adjective names the **centered
state**, i.e. what the bar shows when there is no deviation, not the style itself),
`Center-zero` / `Bipolar` / `Diverging` / `Differential` (formally the most precise, but these are
terms, not names: hyphenated, adjectival, or four syllables long).

### The accepted flaw in the name

`Balance` **is not perfect**, and that is recorded deliberately. The word is already used in the
app in a **monetary** sense, in an adjacent part of the UI, no less:

- `spend.balance` — a field of the usage API's credit block. The value never arrives (`null` in
  every state) and **is never decoded**, so there is no compile-time collision — but the word is
  already spoken for;
- [ADR-0037](0037-extra-usage-credits-model.md) uses title-case `Balance` in prose and leaves
  balance logic as "a separate future feature";
- in Settings, the hint *"Extra usage bar always draws in Progress style"* is pinned to **that
  same Style row** ([ADR-0100](0100-dropdown-style-tiles-and-retired-option-segment.md)), so the
  label and the words "Extra usage" sit next to each other.

**Why it was accepted anyway.** The problem `Balance` solves affects **everyone** who opens the
picker; the problem it creates affects only someone reading docs or code while holding both
meanings in mind at once. The mitigation: the `case balance` doc comment states outright that this
is not `spend.balance`, and this section of the ADR records the distinction between the two terms.
**ADR-0037 is not rewritten** — it is `accepted`, hence immutable.

### The cost turned out to be one line — thanks to ADR-0108

[ADR-0108](0108-extra-usage-one-anatomy-and-per-bar-style-caption.md) §3 reduced the style word to
`BarStyle.displayName` with a derived `caption`, and did so **anticipating exactly this rename** —
verbatim: "#387/#388 propose renaming Gauge, and two literals would mean two half-renames." So
changing the label on both surfaces is a **one-line** edit.

The second thing it bought: `displayName` is deliberately **not** derived from `rawValue` ("the raw
values are persisted keys"), so the UI name and the stored value could be changed
**independently** — the label in one commit, the case and migration in the next.

### Migration: one table entry instead of new code

A renamed `rawValue` **silently resets** the setting — both getters resolve an unrecognized raw
value to the preset default without an error. The rule from `releasing.md` ("renaming a raw value
is two edits, not one") is satisfied by this entry:

```swift
public static let legacyRawValues: [String: BarStyle] = [
    "pacing": .progress,   // #307
    "simple": .pressure,   // #307
    "gauge": .balance,     // #388
]
```

That is enough for the value to **read** correctly: every path that sees a stored raw value
consults the same table — `init(from:)`, `legacySurfaceStyles(for:)`, and decoding an exported
config.

But reading correctly is not enough. `migrateRawKey` only fires while **the key itself** is moving
from the old name to the new one (#381), so an installation that has already made that move leaves
the old *value* on disk forever: `defaults read` shows a raw value that matches no case name, an
exported config carries it forward, and on the day the legacy entry is removed, the setting resets
for real. So a **matching value pass** was added — `PersistedConfig.refreshRawValue`, which rewrites
the raw value **in place**, under the same key:

```swift
refreshRawValue(Key.menuBarStyle, label: "menu-bar-style") { BarStyle.legacyRawValues[$0]?.rawValue }
```

Applied to all six Appearance keys, not just the styles: **don't keep a legacy path around where a
working migration mechanism already exists.** No marker key is needed — the idempotence is
structural, as in the neighboring passes (#381: "Idempotent by construction, no marker key"): the
table only answers for raw values that are **not** current, so a single rewrite removes its own
trigger condition.

**One exception that needed fixing:** the `PersistedConfig.menuBarStyle` / `.dropdownStyle` getters
only consulted `rawValue`, meaning they were the one path that bypassed the table. They now read it
like everything else — which incidentally closed the same gap for `"pacing"`/`"simple"` that the
doc comment had acknowledged as open since #307.

### What of the word `gauge` remains in the code — and why

The `Pace → Pressure` precedent (#307) is the same one: `"pacing"` and `"simple"` stayed forever.
Here, what remains:

| What | Why |
|---|---|
| `"gauge"` in `legacyRawValues` | the heart of the migration; removing it would reset the setting for anyone who never re-picked a style |
| `\| "gauge" / "balance" \|` in migration tables | the left column describes **what's actually sitting in other people's `UserDefaults`** |
| JSON fixtures with `"gauge"` | a regression test: an old exported dump must still import |
| "Raw value was `"gauge"` before #388" | a historical marker, following the `"pacing"`/#307 pattern |
| "Until the centered scale arrived…" | a claim **about a moment in time** — replacing it would make it false |
| Slugs like `0079-…-gauge-scale.md` | ADR filenames are never renamed (52 references) |

So `grep -i gauge` **should not come back empty** — 12 deliberate mentions instead of 132.

### What was NOT renamed

**`BarScale.centred`** describes geometry, not style. [ADR-0079](0079-centred-zero-gauge-scale.md)
deliberately introduced `BarScale` to decouple the scale from the style's name, and the renderers
branch on it directly (`barStyle.scale == .centred`), not on the case — so the rename never touched
the drawing code at all.

## Consequences

- **The stored choice is not lost.** A user who picked this style sees the same thing after the
  update, just under a new name. This should get a line in the release notes.
- **`gaugeOffset` was public `TokenPaceKit` API**, so this is formally a source-breaking change.
  There are no external consumers, so no `@available(*, deprecated, renamed:)` shim was added.
- **`grep -i balance` got noisier** — it now mixes the style with the credit API. This is an
  accepted cost; `gauge` was a clean, unique token.
- **Three ADRs with a `gauge` slug now describe a style under a name that no longer exists.** Their
  bodies are unchanged, so each got a short postscript pointer. In particular,
  [ADR-0079](0079-centred-zero-gauge-scale.md) contains the note "`"gauge"` is a new raw value,
  **not a rename**, so `legacyRawValues` is left untouched" — which this very decision now
  overrides.
- **A "zero mentions" check doesn't work here.** Instead, three targeted greps for **broken
  references**: `BarLayout/gaugeOffset`, `BarStyle/gauge`, and markdown links to the ADR (there
  should be 52 of them left, and a drop in that count means a `sed` broke a link).

## Alternatives considered

- **Keep `Gauge`.** The cheapest option, and [ADR-0093](0093-bar-style-picked-by-picture.md) makes
  a strong case: the label was reduced to a tag because the style is picked **by picture**, so the
  word doesn't carry meaning. Rejected: the tag still gets read anyway — in the Settings navigator
  row (`Style: Balance`), in the popup caption under ⌥, and in release notes. A generic name that is
  a hypernym of its neighbor hurts in all three places.
- **Rename only the label, keeping `rawValue = "gauge"`.** Zero migration risk. Rejected: this is
  the same "case in code vs. name in UI" mismatch that
  [ADR-0076](0076-pressure-scale-for-marker-less-bar.md) called "a permanent tax on reading code
  and logs" and deliberately eliminated.
- **Rename `BarScale.centred` too.** Would make the style↔scale link literal. Rejected: the
  geometric neutrality of `BarScale` is precisely what it was introduced for.

## Related

- [ADR-0079](0079-centred-zero-gauge-scale.md) — the style itself and its scale.
- [ADR-0101](0101-pressure-is-the-gauge-ahead-half.md) — Pressure as half of this scale.
- [ADR-0108](0108-extra-usage-one-anatomy-and-per-bar-style-caption.md) §3 — `displayName`/`caption`,
  which made the rename a one-line change.
- [ADR-0016](0016-rename-to-tokenpace.md) — the "history isn't rewritten, live docs get renamed"
  boundary.
- [ADR-0037](0037-extra-usage-credits-model.md) — the other meaning of the word `balance` in this
  product.
