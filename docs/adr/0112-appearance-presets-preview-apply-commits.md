---
status: accepted
date: 2026-08-19
supersedes: []
superseded_by: []
---

# ADR-0112: Appearance presets — a click is a preview, only `Apply` commits

> Supersedes the last paragraph of the "Presets — radio buttons with explanations, not a
> segmented control" section of
> [ADR-0099](0099-appearance-nests-its-two-surfaces.md) (the rule "`Custom` is unclickable until
> there's a saved setup") and the "Presets (extended)" § of
> [ADR-0062](0062-configurable-bar-presentation.md) (`Custom` as an unclickable indicator). The
> rest of both ADRs still stands — including the prose radio group instead of segments and the
> three wording rules from 0099, and "the single source of defaults is the `.workHarder` preset"
> from 0062.
> Changes nothing in [ADR-0080](0080-per-surface-bar-style.md) (style per surface) or
> [ADR-0104](0104-appearance-named-for-behaviour-on-three-layers.md) (key names).

## Context

One list row meant **two different configs at once**.

`Custom` lit up whenever the live config didn't match any preset — i.e. it showed the *current
state*. But clicking it restored `customAppearanceValues` — a snapshot taken at some earlier point,
quite possibly a different one. Two roles, one name, and there was no way to see the difference
from the UI.

Clickability itself was also unstable: `canRestoreCustom = activePreset != nil && customAppearanceValues != nil`.
The row was sometimes pressable and sometimes not, for a reason invisible to the user.

Worst of all — **the snapshot was a moving target**. `apply(_:)` overwrote it every time the user
clicked a preset from an unmodified state. That produced a scenario that silently destroyed work:

1. Manual setup **A** → click `Chill` → snapshot = A.
2. Edit one option → config becomes `Chill′`, snapshot is **still A**, the `Custom` row is lit (it
   shows `Chill′` but would restore A — the same two roles again).
3. Click another preset → the snapshot is overwritten with `Chill′`. **A is gone forever**, with no
   signal at all.

The maintainer who wrote this code couldn't work out from the UI how it behaved — and assumed the
opposite ("after closing the window, the user won't be able to get back to their old settings").
That's the actual diagnosis: it wasn't missing an explanation, it was missing a model that could be
explained.

There are two things the user is actually doing here, and neither was served:

1. **Try on** a preset and compare it with their own — possibly staying with their own.
2. **Take a stock** preset as a base and start modifying it.

Both require that clicking a preset be **irreversible only on explicit confirmation**.

## Decision

### 1. A click is a preview; only `Apply` commits

Clicking a preset row puts its values into an **overlay** that every Appearance getter on
`PersistedConfig` consults. Both surfaces render the preset; nothing is written to `UserDefaults`.
Closing the Settings window discards the overlay. The **`Apply`** button on the previewed preset's
row is the only thing that writes.

You can switch between presets in any order, as many times as you like: there's no modal state to
exit, and no `Cancel`. That's exactly what makes the rows safe to click — and clicking is what
people come here to do.

### 2. `Custom` → `My setup`: the saved config itself, not a snapshot

The fourth row names the **saved config**. Not a snapshot, not "what it used to be" — what's
currently in the seven keys. It's always clickable (it restores from the preview), and it means
exactly one thing.

`customAppearanceValues` is retired: the config is never overwritten behind the user's back again,
so there's nothing left to snapshot. The key is swept away at startup and on Reset; the value is
**deliberately not migrated** — folding the snapshot into the live keys would silently change the
widget's appearance on update.

When the saved config happens to equal a preset, the row says so with a secondary-ink note —
`My setup · same as *Chill* preset`, the preset name in italics. This is an **observation, not a
choice**: a config that matches `Chill` today will stop matching after the very first edit, and
lighting up the `Chill` row would promise that the widget keeps tracking the preset. The note says
the same thing without the promise — and disappears on its own the moment the config diverges.

It follows that **`My setup` is always the active row without a preview**, even when it equals a
preset.

### 3. The overlay lives in `PersistedConfig`, not in the model

The render path reads Appearance almost entirely through seven `PersistedConfig` getters. Shadowing
them gets the preview to **every surface at once** — the menu bar, the dropdown, and the preview
window next to Settings — and no call site needs to know the preview exists.

The alternative "write the preset, restore on close" was rejected: a crash or a Quit mid-preview
would leave someone else's config written permanently, with no way for the user to find out it
wasn't their own setting. `windowWillClose` also doesn't fire on every `NSApp.terminate` path.
Restoring would then have to come from a snapshot — bringing back exactly the mechanism we're
eliminating. The overlay has no such state by construction: not a single byte is written to
storage, and losing the process only loses the preview.

The cost: `PersistedConfig` stops being a pure storage facade. Mitigated by
`beginAppearancePreview`/`endAppearancePreview` being the **only** enter/exit pair, and each getter
making exactly one call to `previewOr(_:_:)`, so "does this getter honor the preview?" isn't a
per-property decision: a getter that forgot would silently exclude its own surface from the
preview.

### 4. Setters clear the preview **before** writing

Editing a single option on a child page still writes to storage as before. But it first clears the
overlay and resyncs the model — otherwise the six fields it doesn't touch would stay shadowed, the
screen would show a mix, and closing the window would surface a third state.

### 5. The choice logic lives in the Kit, under tests

`AppearanceChoice` (`Sources/TokenPaceKit/`) answers three questions: which row is active, what the
note says, and whether `Apply` has anything to do. `SettingsModel` lives in the app target, which
**links no test target at all** — the same gap named in
[ADR-0111](0111-degraded-dot-is-yellow-on-every-surface.md). Pulling these three decisions into the
Kit is the cheapest way to cover the most confusing part of the screen.

## Consequences

- **Losing a manual setup by clicking is no longer possible.** The three-step scenario above has no
  step where anything disappears: the preview doesn't write, and `Apply` writes exactly what the
  user sees and confirmed.
- **A preset can't be "worn" — it can only be copied into your own.** The preview doesn't survive
  closing the window, so the only way to live on `Chill` is to press `Apply`, after which
  `My setup` **equals** `Chill`. This is deliberate: there is exactly one config, and it's always
  yours.
- **After `Apply`, the selection moves to `My setup`**, rather than staying on the preset row. The
  model is consistent (`My setup` is the saved config), but visually the selection "flees" the row
  that was just pressed — worth watching for on a live screen.
- **`selectable` on `RadioGroup` and `SegmentedControl` is left without a consumer.** It existed
  specifically for `Custom`. The mechanism is kept (for `SegmentedControl` it's the only path to
  `inactiveHelp`), but both doc comments say so, so a reader doesn't go hunting with grep.
- **The copy button moved to the `My setup` row** and reads storage past the overlay. From the
  section header it would look like it copies what's on screen — but during a preview that's a
  preset the user never chose.
- **`swift test` can't catch a regression in the preview mechanism itself** — the overlay and
  setters live in the app target. Only `AppearanceChoice` is under tests; the rest is a recipe in
  [ui-verification.md](../guides/ui-verification.md).
- Two new log lines, `appearance preview: <preset>` and `appearance preview: ended`, make a new
  class of complaint ("the widget doesn't look like what I configured") diagnosable.

## Alternatives considered

**Just hide `Custom` when the config matches a preset** — this is where the task started. Rejected:
the row is clickable precisely when a preset is active, so hiding it in that state would remove the
one state where it works. The symptom would be treated; the mechanism would remain.

**A "Restore my setup" button instead of a fourth row.** Would honestly represent a one-shot
action, but would make "your own" an unequal item for comparison — glancing at your own config
mid-tryout would require leaving the mode.

**A preview with `Cancel`/`Keep`.** Modal: once started, you have to exit through one of two paths.
But the comparison is inherently non-linear (Chill → your own → Chill → Work harder!), and going
back "just to glance" would end the preview session.

**Preset thumbnails instead of a live preview.** Touch nothing, but show only part of the picture:
rules like `hide until it needs attention` depend on data state. A mockup doesn't answer "what will
this look like **on my data**" — which is exactly the question here.

**Lock the child pages during a preview** (instead of clearing the overlay in the setters). Simpler
in code, but introduces the same modality rejected above.
