---
status: superseded
date: 2026-08-13
supersedes: [0034]
superseded_by: [0090]
---

> **Postscript ([#381](https://github.com/artem-from-ua/cc-timer/issues/381)).** The type
> introduced here is named [`TopBarHiding`](../../Sources/TokenPaceKit/TopBarHiding.swift) (was
> `CalmBarHiding`), the Settings row is **`Hide the top 5h bar`**, the segments are
> `Until it needs attention | Never` (was `When it's calm`), the key is `menuBar.hideTop5hBar`, the
> `MenuBarLayout.make(hideCalmBar:)` parameter is `hideTopBar:`
> ([ADR-0104](0104-appearance-named-for-behaviour-on-three-layers.md)). Legacy raw `fiveHour` /
> `sevenDay` values are resolved through `TopBarHiding.legacyRawValues`. **The behavior has not
> changed** — the `BarView.isCalm` predicate, the invariant "at most one bar is ever hidden," and
> treating idle as calm still stand; the only thing dropped from the string was the first phrase of
> the hint, which the segment itself already duplicated.

> **Superseded by [ADR-0090](0090-menu-bar-answers-can-we-work.md).** The symmetry was rolled back:
> the `7-day` segment was removed, leaving `When it's calm` / `Never`, and the row names the bar
> ("Hide 5h (top) bar"). Still standing: the `BarView.isCalm` predicate, the invariant "at most one
> bar is ever hidden," treating idle as calm, and diagnostic bars in the error state.

# ADR-0086: Hiding a calm bar — a three-way choice instead of a boolean

> Replaces [ADR-0034](0034-hide-calm-seven-day-bar.md), which offered the same "less noise" idea,
> but only for the 7-day bar. The same lineage as
> [ADR-0028](0028-hide-reset-label-when-pacing-is-calm.md) /
> [ADR-0029](0029-reset-countdown-selection-by-severity.md) and
> [#105](https://github.com/artem-from-ua/tokenpace/issues/105): it reuses the `BarView.isCalm`
> predicate.

## Context

[ADR-0034](0034-hide-calm-seven-day-bar.md) introduced the `hideCalmSevenDayBar` option — "hide the
7-day bar while it's calm" — so that in the typical calm state the widget would be a single bar
instead of two. The option turned out to be **asymmetric**: only the 7d bar could be hidden.

The need, though, is symmetric. For someone whose 5-hour window is rarely tight but whose weekly
budget is the real constraint, the useful bar on the item is the 7-day one, and the calm 5-hour bar
just takes up space. The old option couldn't do this — it could only hide the opposite bar.

On top of that, the option was **inverted**: Settings showed "Show 7-day bar when calm," while
`UserDefaults` stored `hideCalmSevenDayBar` (the opposite value). Every reader had to hold the
inversion in their head, and several docs recorded the label wrong ("Hide 7-day bar when calm" —
something the UI never actually said).

## Decision

The option becomes three-way: **"Hide the calm bar"** with segments `7-day` / `5-hour` / `Never`,
where the segment names the bar that gets **hidden** while it's calm. The segment order goes from
the longer window to the shorter one and then to "hide nothing"; it's set by the order of the enum
cases, since the control is built from `allCases`.

### A type, not a flag

A new `CalmBarHiding` in `TokenPaceKit` (`String`-raw, `CaseIterable`, forward-compatible decode) —
following the canon of `PopupSectionVisibility` / `ResetCountdownMode` / `BarStyle`. The predicate
lives **inside the enum itself**:

```swift
public var hiddenWindow: LimitWindow? { … }
public func hides(_ window: LimitWindow, isCalm: Bool) -> Bool { isCalm && hiddenWindow == window }
```

### Invariant: at most one bar is ever hidden

`hides` compares its argument against the **single** window the value names, so the set of windows
it can ever return `true` for has cardinality ≤ 1. From this: no matter what severity either bar
has, the other one is always left standing — **the widget can never go empty**.

This is a property of the *type*, not a check inside `MenuBarLayout`, so it cannot drift out of sync
with the call site. Pinned by a test that runs the matrix "mode × calm/noisy × active/idle."

### The model: `expanded.fiveHour` is optional too

`MenuBarMode.expanded(fiveHour:sevenDay:resetToShow:)` had `sevenDay: BarView?` and a **non-optional**
`fiveHour`. Both are now optional — the same as it long was in `.error`. The two cases' shapes now
match, which is exactly what the comment "The split mirrors `expanded`" had promised.

`nil` in `.expanded` and `.error` means **different things**, and this is pinned in the type's doc
comment: in `.expanded` it means "deliberately not drawn," in `.error` it means "there is no data."

### Idle — no exception

An inert 5-hour bar in session-idle ("ready to start") always has `severity == .calm`, so in
`5-hour` mode it gets hidden **too**. There is no special case, deliberately: idle *is* the state
where the 5h window has nothing to measure.

The consequence is visible: in `5-hour` mode, between sessions the item is left with just the
7-day bar, and the "no session running" signal lives in the dropdown. This is accepted deliberately
(see Consequences).

### The error state stays diagnostic

The stale/error branch rebuilds the layout by calling `make` **without** `hideCalmBar` (default
`.never`), so both bars next to ⚠️ stay intact — whichever one the user hides in the healthy state.
Same as in ADR-0034 for 7d.

### What did NOT change

- **`selectReset` sees the real severities** — hiding only touches the *bar*, not the countdown
  selection. A hidden calm bar never drove that choice before either.
- **Item width** does not depend on the number of bars (`barsMaxX` is computed from
  `Metrics.barWidth`).
- **The geometry stays the same** — centered on `rect.midY`. A lone 7-day bar sits exactly where a
  lone 5-hour bar used to sit: the layout depends on the *count* of bars, not on which window
  survived.
- **`pauseHidesBars`** fires earlier and removes both bars — there is no overlap.

### No more inversion

`calmBarHiding` is stored exactly as the UI shows it. `hideCalmSevenDayBar` was the last inverted
value in the Appearance set.

## Consequences

### The factory default changes (the most visible change)

Presets: `chill` and `workHarder` → `.fiveHour`, `controlFreak` → `.never`. Since `workHarder` is
`AppearancePreset.default`, i.e. the source of all factory defaults, **the default behavior
inverts**: previously the 5-hour bar stayed during calm periods, now it's the 7-day one.

Who notices: anyone who has **never touched** the old option (no key in `UserDefaults`). After the
update, such a user will see the weekly bar instead of the 5-hour one during calm periods, and in
**idle** — just the weekly bar, with no blue "ready to start."

We deliberately do **not** pin the old behavior by writing `.sevenDay` for people who never chose.
Reasons:

- Precedent from [ADR-0080](0080-per-surface-bar-style.md): the factory-default shift for
  `BarStyle` similarly affected only people who never made a choice, and that was accepted as the
  norm.
- Writing a value "on someone's behalf" would create a **second** default that contradicts the
  preset: `workHarder` says `.fiveHour`, while the migrated user would sit on `.sevenDay` — and
  their config would no longer match any preset, so the segmented control would immediately show
  **"Custom"**, even though they never configured anything.
- A written value "sticks": any future shift of that user's default would never reach them again.

We compensate not with a migration but with communication — a dedicated paragraph in the release
notes.

### Migrating an explicit choice

`migrateCalmBarHidingIfNeeded()` (idempotent, following the pattern of
`migrateModelLimitsVisibilityIfNeeded`) carries over only an **explicitly stored** old value:

| Old `hideCalmSevenDayBar` | New |
|---|---|
| `true` (explicit) | `.sevenDay` |
| `false` (explicit) | `.never` |
| no key present | write nothing → the new preset default `.fiveHour` |

The mapping itself lives in `CalmBarHiding.migrated(fromLegacyHide:)` — in the Kit, so it's unit
testable (`PersistedConfig` lives in the app target, and there's only one test target) and so **both**
readers of the old value use it: the `UserDefaults` migration and decoding an exported config. The
same split as in `BarStyle.legacySurfaceStyles(for:)`.

### Config export

The key `hideCalmSevenDayBar` (bool) → `calmBarHiding` (raw string) **at the same position** in the
pane's order. The old key stays around as a read-only case in `CodingKeys`, so a dump from an older
build imports through the same mapping. A dump with neither key present falls back to `.sevenDay` —
the semantics that build actually drew, not today's default.

### The cost

- `MenuBarMode.expanded` now has two optional fields, so call sites that read `five` need to unwrap.
  The real footprint turned out small: most tests go through helpers.
- The `(nil, nil)` branch in `drawBars` is unreachable given the invariant, but exists in the code
  as a silent no-op — the view stays a thin shell
  ([ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md)), not a place for assertions.
