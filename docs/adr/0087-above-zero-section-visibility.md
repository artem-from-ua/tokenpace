---
status: superseded
date: 2026-08-13
supersedes: []
superseded_by: [0100, 0104]
---

# ADR-0087: The `aboveZero` mode for dropdown sections, and why credits lose `nonCalm`

> **Superseded by [ADR-0104](0104-appearance-named-for-behaviour-on-three-layers.md)**
> ([#381](https://github.com/artem-from-ua/cc-timer/issues/381)). None of the raw values this ADR
> operates on survive: `aboveZero` → `onceUsed`, `nonCalm` → `whenItNeedsAttention`, and
> `.optionOnly` was **removed from the enum** — old raw values are resolved through
> `PopupSectionVisibility.legacyRawValues`. The marker key
> `extraUsageVisibilityMigratedFromNonCalm`, introduced here, has been retired: the value now
> carries over along the way when the key itself moves to `dropdown.showExtraUsage`, so
> idempotency is guaranteed by the construction rather than by a flag. The segment order has been
> reversed (quieter goes on the left). **The substance of the decision still stands** — the
> predicate "value, not verdict," two different predicates for the two groups, and the fact that
> the credits row doesn't offer a verdict-driven mode (the blind spot for an unlimited cap); in
> code this is `PopupSectionVisibility.creditsOffered` / `foldedForCredits`.

> **Partially superseded by [ADR-0100](0100-dropdown-style-tiles-and-retired-option-segment.md)**
> (#374): the **`With ⌥ Option`** segment was removed from **both** rows — ⌥ is already added
> through `||` on top of every other mode, so `.optionOnly` differed only in that it **hid** the
> group when its data became interesting. The case remains in the enum for decoding stored values
> (the same procedure applied here to `.nonCalm` on the credits row), with migration to
> `.aboveZero`. The `aboveZero` mode itself, its predicate, and its defaults still stand;
> **the segment's name changed** to `Once used`, so the argument below about "two short words" and
> about four segments in one row no longer describes the UI.

Builds on [ADR-0072](0072-dropdown-section-visibility.md), which introduced the three-state
`PopupSectionVisibility`. That ADR remains the standing description of the gate's mechanics (the
"non-calm" predicate, the gate's placement in the view, hiding rows by skipping them); this one
revisits the **set of modes** and the **defaults** — including the "a fourth mode" alternative it
rejected.

## Context

ADR-0072 gave both optional popup groups the same three modes: `always` / `nonCalm` /
`optionOnly`. The middle one was meant to mean "show it when it's worth looking at," and it
measured that through `PacingSeverity.isNonCalm` — orange or red.

Use in practice showed that severity is a poor proxy for "worth looking at," and each group breaks
in its own way.

**Per-model rows expand too early.** ADR-0072 itself predicted this, in its "Consequences": early
in the 7-day window, small usage paces as `.ahead` ("ahead of the target pace"), which is orange.
Formally correct — the group really is non-calm — but in practice the Opus/Sonnet/Fable rows pop
out already at 2–4%, i.e. exactly when the numbers are least interesting. The ADR advised "raising
the threshold in `PacingModel`" for this case.

**Credits have a blind spot, and it's worse than being premature.** The credits' severity comes
from `credits.bar`, which is `nil` under an unlimited cap (`spend.limit == null`, the
`credits-no-limit` stub). So `creditsIsNonCalm` is **always** `false` there, and in `nonCalm` mode
the section never appears, no matter how much money gets spent. A user who deliberately removed
their spending ceiling gets the least visibility — even though `nonCalm` was the **default** for
`.chill` and `.workHarder`.

## Decision

### A new `aboveZero` mode that reads a value, not a verdict

```swift
case .aboveZero:  return isAboveZero || optionHeld
```

- per-model: any row in the group has `utilization > 0` (the base 5h/7d values are discarded the
  same way as in `groupIsNonCalm`);
- credits: `!credits.spent.isZero`.

The project's cross-cutting principle: **a value is the model's input, a color and a verdict are
its output**. `nonCalm` asks the model what it thinks about a number; `aboveZero` asks the number
itself. These are not two phrasings of one threshold, and neither derives from the other: 2% is
simultaneously `aboveZero` and `.ahead`, and an unlimited €10.80 is `aboveZero` and never
`nonCalm`. So the predicates are computed independently, and `shows(...)` takes both.

### The threshold lives in visibility, not in `PacingModel`

ADR-0072 advised raising the threshold in `PacingModel`. Rejected: `PacingModel` colors **every**
surface, and shifting the `.ahead` threshold would change the color of menu bar bars, popup bars,
and verdicts everywhere just to fix one group's layout problem. It also wouldn't cure the credits
blind spot: under an unlimited cap there's no bar at all, so no pacing threshold exists there to
shift.

### The credits row loses `nonCalm`

The `Non-calm only` segment is removed from "Show extra usage." Two reasons, each sufficient on its
own:

1. **It's unreachable under an unlimited cap** — severity doesn't exist there (above).
2. **It's redundant under a set cap** — reaching orange first requires spending a nonzero amount,
   so `aboveZero` always fires earlier. The difference between the modes would reduce to "show it
   later," with no meaning of its own.

The `.nonCalm` case itself **stays in the enum** — it's a stored value that must still decode.
Only its offer in the control is removed; stored values are carried over by migration.

### Asymmetric segment sets

A consequence: the two rows no longer share one list. `DropdownPane` holds two explicit arrays
instead of `allCases` — the same as `AppearanceBarStyle.segments`, which is also enumerated by
hand.

```
Show model & service limits   [ Always | Above zero | Non-calm only | With ⌥ Option ]
Show extra usage              [ Always | Above zero | With ⌥ Option ]
```

This removes ADR-0072's objection to a fourth mode ("four segments don't fit one Settings row")
exactly where it was sharpest: the credits row stays three-segment, and only the model row has
four. The labels stay short for the same reason — `Above zero` is deliberately two words, and
unlike `Non-calm only` it needs no "only": the threshold phrase is already exclusive.

### Defaults

| Preset | `modelLimitsVisibility` | `extraUsageVisibility` |
|---|---|---|
| `.chill` | `nonCalm` (unchanged) | **`aboveZero`** (was `nonCalm`) |
| `.workHarder` (factory) | `nonCalm` (unchanged) | **`aboveZero`** (was `nonCalm`) |
| `.controlFreak` | `always` (unchanged) | `always` (unchanged) |

The per-model default is left unchanged deliberately: premature expansion is annoying, but it's
**visible**, and whoever it affects now has somewhere to switch to. The credits default changed
because its flaw is **invisibility**: a silent blind spot the user has no way to notice, let alone
complain about.

## Consequences

- **Migration `nonCalm` → `aboveZero` for credits** (`migrateExtraUsageVisibilityIfNeeded`).
  Preserves the intent that made `nonCalm` the default ("don't show it until there's something to
  look at") and carries it to every billing configuration. Idempotency comes from its own marker
  key, not from deleting the legacy key: this rewrites the **value** of a key that stays in use,
  and `nonCalm` is still legal for the neighboring row. Without the marker, a user who restored
  `nonCalm` via a config import would get silently rewritten a second time.
- **`PopupLayout` grew two fields** — `perModelRowsAreAboveZero`, `creditsIsAboveZero`. The gate
  stays in the view for both of ADR-0072's original reasons (a live `optionHeld` without a
  re-poll; `BlockingReset` indices).
- **`Money.isZero`** — a new helper that compares whole minor units rather than `majorUnitValue`:
  exact for any `exponent` and free of division error.
- **`shows(...)` became three-parameter.** Both predicates are always passed, deliberately with no
  default: a default would let a new call site silently pass a permanent `false` and break the
  mode.
- **The credits section now appears earlier by default** — on the first cent spent instead of at
  orange. For those who pay rarely, this is a noticeable change; `With ⌥ Option` remains a way to
  remove it entirely.

## Alternatives considered

- **Raise the `.ahead` threshold in `PacingModel`** (ADR-0072's suggestion) — rejected: it affects
  color on every surface and doesn't cure the credits blind spot.
- **Keep `nonCalm` on the credits row for symmetry** — rejected: an unreachable or redundant mode
  in the control is worse than asymmetry, because it looks functional and silently isn't.
- **Cure the blind spot by making `creditsIsNonCalm` true under an unlimited cap** — rejected: that
  would lie about severity (no ceiling means no alarm) just to push the fact of spending through
  the gate. Spending is a value, and it deserves its own predicate.
- **Hide zero per-model rows individually rather than as a group** — rejected in this pass: the
  group gate stays a single value, and row order is preserved for `BlockingReset` indices. Worth
  a separate look if groups with half-zero rows turn out to be common.
