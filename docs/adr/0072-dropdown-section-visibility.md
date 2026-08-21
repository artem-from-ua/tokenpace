---
status: superseded
date: 2026-08-05
superseded_by: [0087]
---

# ADR-0072: Three-state dropdown section visibility instead of boolean toggles

> **Partially superseded by [ADR-0087](0087-above-zero-section-visibility.md):** the set of modes
> is no longer three-state, and no longer shared between the two groups. `aboveZero` was added (a
> gate on **value**, not on severity), and the credits row **lost** `nonCalm` — at the unlimited
> cap there is no bar, so that mode hid spending forever. Along with it, the "fourth mode"
> alternative rejected here dropped away too (the segments are no longer shared: 4 on the model
> row, 3 on credits), as did the default `extraUsageVisibility: nonCalm` for
> `.chill`/`.workHarder` (now `aboveZero`). The consequence predicted below, about the group
> expanding at 2–4%, is exactly what `aboveZero` cures — but **not** via a threshold in
> `PacingModel`, as advised here. The rest of this ADR still stands: the "non-calm" predicate
> (`.ahead`/`.exhausted`, not `!isCalm`), the groups' independence, the gate living in the view,
> hiding rows by skipping them for the sake of `BlockingReset` indices, and the fact that the menu
> bar's `showExtraUsage` is a separate setting.

## Context

The dropdown has two **optional** row groups on top of the base `5-hour`/`7-day`:

- **per-model / per-service** rows — `Opus`/`Sonnet` from legacy fields, plus `weekly_scoped`
  models from `limits[]` (`Fable`, `Mythos`, #65/#211);
- the **Extra usage** section — paid credits (#145).

They were governed inconsistently. The first had a boolean opt-out, `showModelSpecificLimits`
("show or not"); the second had **no** setting in the popup at all: it was always drawn whenever
`CreditsPacing.isActive`. Meanwhile, the existing `showExtraUsage` key gates the **¤ icon in the
menu bar**, not the popup — a name collision that's easy to confuse.

A boolean choice turned out too coarse for both. "On" keeps rows on screen that stay green for
months and add nothing; "off" hides them even when a model is **exhausted** — exactly when
they're needed. The user is forced to choose between constant noise and a blind spot.

The menu bar already solves this problem: `CalmBarHiding` hides the chosen strip **while it's
calm**, and brings it back the moment it turns orange. The popup had nothing like it. (At the time
of this ADR that was a boolean `hideCalmSevenDayBar`, able to hide only the 7-day strip; the menu
bar moved to a three-position version — and hence to a "third state" in the same sense as here —
in [ADR-0086](0086-tri-state-calm-bar-hiding.md).)

## Decision

Both groups are governed by a shared three-state type, `PopupSectionVisibility`
(`always` / `nonCalm` / `optionOnly`), one key per group:
`modelLimitsVisibility` and `extraUsageVisibility`.

```swift
public func shows(isNonCalm: Bool, optionHeld: Bool) -> Bool {
    switch self {
    case .always:     return true
    case .nonCalm:    return isNonCalm || optionHeld
    case .optionOnly: return optionHeld
    }
}
```

### "non-calm" = orange or red, not `!isCalm`

The predicate is `PacingSeverity.isNonCalm` (`.ahead || .exhausted`), **not** the negation of
`BarLayout.isCalm`. The difference is blue `.farBehind`: it means **headroom** (usage is behind
time) and, on the scale, is *calmer* than green. `!isCalm` would treat it as alarming and expand
the group exactly when everything is at its best. This is the same reason
`MenuBarLayout.selectReset` checks "noisiness" via `.ahead`/`.exhausted` directly (see the note in
`PacingModel.isCalm`).

The groups are evaluated **independently**: a red `7-day` does not expand the per-model group,
because the base rows are always visible anyway — what needs expanding is whatever is hidden and
has gone wrong.

### ⌥ Option reveals content in both hiding modes

In `.nonCalm`, holding ⌥ shows the calm group; in `.optionOnly`, ⌥ is the only way to see it at
all. This isn't a new mechanic but an existing popup idiom: `showStatusRows`, `showAge`, and the
service-component filter already read as `optionHeld || <problem>` (ADR-0020). The live ⌥ state is
provided by a 50 ms polling timer, because `isAlternate` is inert in a status-item menu and an
event monitor starves during menu tracking.

### The gate lives in the view; rows from the model never disappear

`PopupLayout` **always** builds the full set of rows and adds three computed fields:
`perModelRowsStart`, `perModelRowsAreNonCalm`, `creditsIsNonCalm`. The decision of whether to draw
is made by `PopupViewController`.

Two reasons, both required:

1. **`optionHeld` changes without a repoll.** The model is rebuilt on every poll; ⌥ is pressed and
   released while the menu is already open. Gating in `make(...)` would require rebuilding the
   model on every finger movement.
2. **`BlockingReset` is tied to `rows` indices.** Its `.token(id:)` is a row's position in the
   *full* order (`0` = 5h, `1` = 7d, then per-model), and the view checks it as `id == index`.
   Dropping rows from the array would renumber the rest and would paint **the red reset badge on
   the wrong row**. So the view hides rows by **skipping** them in the loop, preserving the
   original indices.

### Extra usage — a new option, not an extension of `showExtraUsage`

The menu-bar icon and the popup section stay separate settings, because they answer different
questions. The icon is a glossy badge that must stay silent until the paid tier is actually
engaged (`shouldShowIcon`: credits active **and** the base limit exhausted). The section is a
detail the user opened the dropdown to look at, so its gate is softer (`isActive`). Merging them
into one key would make "I don't need the icon, but I want the amount" impossible.

### Preset defaults

| Preset | `modelLimitsVisibility` | `extraUsageVisibility` |
|---|---|---|
| `.chill` | `nonCalm` | `nonCalm` |
| `.workHarder` (factory) | `nonCalm` | `nonCalm` |
| `.controlFreak` | `always` | `always` |

## Consequences

- **A change in default behavior.** Before this, all three presets had
  `showModelSpecificLimits: true`. Now `.chill`/`.workHarder` collapse both groups while they're
  calm. This is deliberate: the loudness of these presets lives in the menu bar, not in a
  permanently expanded popup.
- **The migration is one-shot and idempotent** (`migrateModelLimitsVisibilityIfNeeded`, modeled on
  `migratePauseKeysIfNeeded`): explicit `true` → `.always`, explicit `false` → `.optionOnly`, no
  key present → the preset default. `.optionOnly`, not `.nonCalm`, because whoever **hid** the
  rows never asked to have them come back on a color change; ⌥ remains the way to pull them up on
  demand. There's no separate migration for Extra usage — the popup option never existed before.
- **`AppearancePresetValues` grew from 11 to 12 fields**, so the config export
  (`AppearanceConfigExport`, keys in on-screen order) and its order-guard test were updated.
- **Early in the 7-day window, `.nonCalm` expands the group more often than expected**: at low
  usage, pacing reads as `.ahead` ("ahead of pace"), which is an orange status. That's formally
  correct (the group really is non-calm), but as a side effect, per-model rows sometimes show at
  just 2–4%. If this turns out to be annoying, the threshold should be raised in `PacingModel`,
  not by introducing a fourth mode here.

## Alternatives considered

- **A fourth mode, `never`** (hide forever, even under ⌥) — to reproduce the old "off" exactly.
  Rejected: four segments don't fit in one Settings row, and `.optionOnly` gives the same quiet
  while leaving a way to look at the data when it's suddenly needed.
- **One shared key for both groups.** Rejected: per-model rows and money are signals of a
  different character, and wanting to see the spending amount doesn't mean wanting to see five
  model bars.
- **A gate in `PopupLayout` (as it was with the boolean).** Rejected for the two reasons above —
  the dynamic ⌥ state and the renumbering of `BlockingReset` indices.
