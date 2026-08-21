---
status: accepted
date: 2026-08-17
supersedes: [0087, 0100]
superseded_by: []
---

# ADR-0104: Appearance is named for behavior — on all three layers at once

> Fully supersedes [ADR-0087](0087-above-zero-section-visibility.md) (segment composition, the
> `.optionOnly` case and its marker-based migration) and §5–§6 of
> [ADR-0100](0100-dropdown-style-tiles-and-retired-option-segment.md) (there the case still lived in
> the enum, and the rename only touched one segment). Implemented in
> [#381](https://github.com/artem-from-ua/cc-timer/issues/381).

## Context

The Appearance pane had accumulated a vocabulary spoken by **the code**, not the user. Three
examples from a single screen:

- the **`Calm non-critical colors`** row with segments `Off | Yellow + Green | + Blue` — "calm" is
  the name of the `PacingSeverity.calm` case, and the segments list the **hues** that get muted,
  while the reader is choosing **what they want to be told**;
- the **`Hide 5h (top) bar`** row with a `When it's calm` segment — the same term-as-artifact, and
  the caption under the row duplicated the segment itself;
- the dropdown row with a **`Non-calm only`** segment — a double negative built on a term the UI
  never explains anywhere.

The same names sat underneath as `UserDefaults` **keys** (`calmColorMode`, `calmBarHiding`,
`modelLimitsVisibility`, `menuBarStyle`, `dropdownStyle`, `showServiceStatusDot`,
`extraUsageVisibility`) — flat, with no surface marker, even though the pane itself had already been
split into **Menu bar** and **Dropdown** for two releases
([ADR-0099](0099-appearance-nests-its-two-surfaces.md)). Config export
([#257](https://github.com/artem-from-ua/cc-timer/issues/257)) surfaced the same flat list: knowing
which surface `showServiceStatusDot` belonged to required knowing the code.

One more legacy artifact: `PopupSectionVisibility.optionOnly` lived in the enum purely for decoding
([ADR-0100 §5](0100-dropdown-style-tiles-and-retired-option-segment.md)), rewritten by a separate
migration step with its own marker key. Two such markers had piled up — the second one for
`nonCalm → aboveZero` on the credit row ([ADR-0087](0087-above-zero-section-visibility.md)).

And one last detail that reads as sloppiness on screen: the pane's segmented controls faced **in
different directions**. `Hide the top 5h bar` went "quieter → louder," both dropdown rows went the
opposite way, `Always` on the left.

## Decision

### 1. The name is chosen for behavior — and consistently across three layers

The pane's row label, the storage key, and the raw value are renamed **together**, by one criterion:
the name describes what the user gets, not the mechanism that produces it.

| Before (row) | After (row) | Key | Values |
|---|---|---|---|
| `Calm non-critical colors` | **`Colors tell me`** | `menuBar.colorsTell` | `slowDown` / `slowDownOrSpeedUp` / `howItsGoing` |
| `Hide 5h (top) bar` | **`Hide the top 5h bar`** | `menuBar.hideTop5hBar` | `untilItNeedsAttention` / `never` |
| `Show service status dot on issues` | **`Show service status dot`** | `menuBar.showServiceStatusDot` | — |
| `Show per-model & per-service limits` | **`Show per-model and per-service limits`** | `dropdown.showPerModelLimits` | `whenItNeedsAttention` / `onceUsed` / `always` |
| `Show *Extra usage*` | unchanged | `dropdown.showExtraUsage` | `onceUsed` / `always` |
| `Style` (both surfaces) | unchanged | `menuBar.style`, `dropdown.style` | — |

The types follow the row labels: `CalmColorMode` →
[`ColorAdvice`](../../Sources/TokenPaceKit/ColorAdvice.swift), `CalmBarHiding` →
[`TopBarHiding`](../../Sources/TokenPaceKit/TopBarHiding.swift), the `MenuBarLayout.make(hideCalmBar:)`
parameter → `hideTopBar:`.

The segments carry their own explanation, so the `Colors tell me` row reads as one sentence together
with the chosen segment — "Colors tell me — slow down." The caption about the hiding mechanism itself
disappeared from `Hide the top 5h bar` (the segment already repeated it); what remains is what
nothing else says: "Either way, once a limit is actually reached both bars give way to the countdown
to it" — a behavior this row does **not** control
([ADR-0091](0091-countdown-only-where-work-is-not-running.md)), and at the same time the app's most
alarming transition.

The word `calm` stays **in the model**: `PacingSeverity.calm`, `BarLayout.isCalm`,
`PacingSeverity.isNonCalm`. These are terms about data, and the property describes the model, not a
control's caption.

### 2. Presets — a deliberate exception

`Chill` / `Work harder!` / `Control freak` are **not** named for behavior, and they stay that way. A
preset doesn't describe one behavior — it sets seven values at once; any "behavioral" name would
either lie about part of them or degenerate into a list. These three are **mood** names the reader
recognizes themselves in, each with an explanatory line underneath
([ADR-0099](0099-appearance-nests-its-two-surfaces.md)). The rule in §1 applies to controls that set
**one** value.

### 3. Keys get a surface prefix, JSON gets nested groups

Storage is renamed **together with** the row, not left on its old name. The reasoning is direct: the
key is what the maintainer reads in `defaults read` and in a config dump, and a mismatch between "one
thing on screen, another in the key" costs exactly the same time the original bad name did. The
`menuBar.` / `dropdown.` prefix makes the surface visible without knowing the code.

[`AppearanceConfigExport`](../../Sources/TokenPaceKit/AppearanceConfigExport.swift) now emits
**nested** JSON accordingly:

```json
{
  "menuBar" : { "style" : "gauge", "colorsTell" : "slowDown", … },
  "dropdown" : { "style" : "gauge", "showPerModelLimits" : "whenItNeedsAttention", … },
  "preset" : "workHarder",
  "appVersion" : "0.105.0"
}
```

The order within a group is **the order of the rows on the page**, as before; grouping adds the
surface on top of that. The decoder reads the nested key first, then the pre-#381 flat one, then the
preset default — so a config copied from an older version imports without loss.

### 4. One key migration instead of two value migrations

[`PersistedConfig.migrateAppearanceKeysIfNeeded()`](../../Sources/TokenPace/PersistedConfig.swift)
moves all seven keys to their new names, running values through the corresponding type's
`legacyRawValues` **along the way**. Each enum now carries this table itself — next to its cases,
unit-tested from Kit, and shared by both readers of an old value (the `UserDefaults` migration and
decoding an imported config), the same split `BarStyle.legacySurfaceStyles(for:)` already had.

This **removes both marker keys**: `extraUsageVisibilityMigratedFromNonCalm` and
`sectionVisibilityMigratedFromOptionOnly` are retired (kept as constants only so an Appearance reset
sweeps them up). Idempotency is now a property of the construction rather than a separate flag: each
key's step is gated on "the new key doesn't exist yet" and **consumes** the old one, so completeness
is evident from the old key simply being gone. A raw value the type doesn't recognize is **not
copied over** — the getter returns the preset default, which is what an unread value always meant
anyway.

### 5. `.optionOnly` is removed from the enum

The case no control has offered since #374 no longer exists as a case at all. The old raw value
`optionOnly` is resolved through `PopupSectionVisibility.legacyRawValues` into `.onceUsed` — the same
surviving intent ("stay collapsed while there's nothing there") the retired migration used to give.
The difference is that now there's nowhere to fall back to: the raw value matches no case, so
importing an old config won't revive it either.

`aboveZero` → `onceUsed` and `nonCalm` → `whenItNeedsAttention` are cleaned up the same way — and
separately, `foldedForCredits`: the credit row only offers `.onceUsed` / `.always`
([ADR-0087](0087-above-zero-section-visibility.md)), so a value the control doesn't have is folded
**before** it reaches the row. The `creditsOffered` list lives next to the enum and is read by all
four paths that can place a value into this key — otherwise the control would open with **no segment
highlighted at all**.

### 6. One shared axis for segments: quieter on the left

Every segmented control in Appearance is ordered so that **the leftmost option leaves the least on
screen**, and the rightmost leaves the most. Both dropdown rows are reversed
(`When it needs attention | Once used | Always`; for Extra usage, `Once used | Always`); the menu bar
ones were already ordered this way.

Consequence for the code: segment lists are **spelled out explicitly**, not mapped from `allCases`.
On-screen order is a **presentation** decision; deriving it from the enum's declaration order would
mean a control reflow reads as a change to the persisted type.

### 7. A shared threshold — shared wording

`When it needs attention` (dropdown) and `Until it needs attention` (menu bar) deliberately echo each
other: it's **the same threshold**, viewed from two different sides — one decides when to **show**
the section, the other when to **stop hiding** the bar. The underlying predicates differ, and stay
different (`PacingSeverity.isNonCalm` versus `BarView.isCalm`, which counts blue `farBehind` as
calm), and that's not a contradiction: both answer the question "is there anything to do here."

## Consequences

**The config dump changed shape.** A script or habit that read flat top-level keys will now see two
groups. Importing old dumps still works (§3); the reverse doesn't: an older version reading a config
with nested groups will see "nothing set" and fall back to preset defaults.

**Renaming a key now has a cost, and it's recorded.** Any future rename requires a `migrateRawKey`
step **and** an entry in the type's `legacyRawValues` — otherwise a user's saved choice silently falls
back to the default. This is recorded in [releasing.md](../guides/releasing.md) as a pre-release
checklist item.

**Old verification recipes have gone stale.** `defaults write com.artem-n.tokenpace calmBarHiding …`
does nothing after the first launch of a new build — the key will already have been consumed by the
migration. Current recipes are in [ui-verification.md](../guides/ui-verification.md).

**What actually needs verifying is the migration.** The most expensive mistake here isn't in a name —
it's a user opening Settings and not seeing their own choice. A scenario ("seed old keys → launch →
check the log and the new keys") was added to
[ui-verification.md](../guides/ui-verification.md).

## Alternatives considered

**Rename only the rows, leave the keys.** Cheapest and worst: the mismatch between the screen and
`defaults read` is exactly the cost this rename was meant to remove — just shifted from the user onto
the maintainer.

**Keep flat keys, but with a prefix.** A middle ground — a prefix with no JSON nesting. Gives half
the benefit (the surface is visible in `defaults`), but the dump stays a flat list of seventeen rows
where groups have to be guessed from the prefix.

**Keep `.optionOnly` in the enum "just in case."** That's how it stood since #374, and that exact
"just in case" was what kept the separate marker-based migration alive. A case no control offers and
no default ever produces is an execution path nobody checks.
