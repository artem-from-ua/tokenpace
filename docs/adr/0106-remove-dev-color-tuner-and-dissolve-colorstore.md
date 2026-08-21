---
status: accepted
date: 2026-08-18
supersedes: [0046]
---

# ADR-0106: Removing the dev color tuner and dissolving `ColorStore`

## Context

[ADR-0046](0046-dev-color-tuner-override-layer.md) introduced two types for the sake of one tool:
`ColorRole` — a flat catalog of named color roles — and `ColorStore`, an `@MainActor` singleton
through which **both** `Palette`s (menu bar and popup) read every color, so the live tuner
([#185](https://github.com/artem-from-ua/tokenpace/issues/185)) could override any of them at
runtime and see the result immediately.

The tuner did its job. The values it settled on have long since sat in `ColorRole.defaultColor`,
and after [ADR-0059](0059-menu-bar-native-semantic-colours.md) and
[ADR-0060](0060-popup-native-semantic-colours.md) almost all of them became **system semantic
colors** (`.systemGreen`, `labelColor`, and so on) — the kind the tuner can now only **break**: a
flat color it picks loses adaptation to light/dark mode and Increase Contrast. This was already
acknowledged in ADR-0060 itself (§"experimentation is done by editing `defaultColor`, not the
tuner").

Meanwhile the layer had a daily cost:

- **The catalog had to be edited in lockstep with the palette** — ADR-0046's rule, "when changing a
  `Palette` color, update `ColorRole.defaultColor` in the same commit," existed exactly because the
  value lived in **two** places.
- **A second popup preview window.** Next to the production preview
  ([ADR-0083](0083-live-dropdown-preview-in-settings.md)) sat a dev-only one, and `data-flow.md`
  warned outright: "there are now two previews, and they're easy to confuse."
- **The docs' description drifted from the code**: `data-flow.md` said "~38 roles,"
  `ui-verification.md` said "~35," and in fact only **18** remained after consolidating blue
  ([ADR-0081](0081-weekly-capacity-gate-for-blue.md)) and other merges.

The question: keep `ColorStore` as an empty seam (with an empty override dictionary), or collapse it
down to a direct read of the defaults.

## Decision

**Remove the tuner along with its preview window and dissolve `ColorStore` entirely.**

- `ColorRole` **stays** — but as the **app's palette**, not a catalog for a UI tool: cases plus
  `defaultColor`. Metadata that existed only to label the picker (`displayName`, `group`,
  `usageDescription`, `distortion`) is removed. The type moved from `DevColorTuner/` into
  `Sources/TokenPace/Palette.swift`.
- Both `Palette`s read `ColorRole.x.defaultColor` **directly**. `Settings` (update dots in About,
  the Claude brand badge) does the same.
- The `DevColorTuner/` folder → `DevTools/`; a single window controller remains in it.
- `PreviewChromeViews.swift` moved into `Settings/` **entirely** — once the dev preview is gone, its
  only remaining consumer is the Settings preview.
- The **Development tools window stays**, carrying two tools unrelated to color: the live stub
  selector ([ADR-0047](0047-live-stub-selector.md),
  [#187](https://github.com/artem-from-ua/tokenpace/issues/187)) and the status-payload JSONL
  logging checkbox ([ADR-0071](0071-incident-subscriptions.md) §10). The gate is unchanged:
  `devToolsEnabled` **and** ⌥ Option ([ADR-0053](0053-devtools-flag-via-defaults.md)); the key
  itself is now read as `PersistedConfig.devToolsEnabled`, with no intermediate
  `ColorStore.devToolsEnabled`.

### Why the roles stay separate

This is the main thing worth recording, because several still-standing ADRs justified themselves by
citing the tuner.

`ColorRole` stays split because each case **names a different signal**, not because each one used
to have its own slider. Phrasing like "a separate role so the tuner could tell them apart"
([ADR-0079](0079-centred-zero-gauge-scale.md) §, [ADR-0089](0089-gauge-centre-tick-calm-tone.md) §,
[ADR-0096](0096-zero-tick-on-pressure.md) §, [ADR-0051](0051-blocked-pause-glyph.md) §) should now
be read as: **the roles stay separate, but the argument shifted from tooling to semantics.** The
scale's zero isn't the same thing as a calm fill, even when both resolve to `labelColor`; the credit
bar isn't a pacing bar; the pause glyph isn't the service dot.

The flip side of the same principle already shows up in
[ADR-0081](0081-weekly-capacity-gate-for-blue.md) §: `paceBlue` was **merged** into `blue` precisely
because the split "only let the tuner tell apart what was conceptually one thing." This ADR is a
precedent, not an exception: the criterion was always semantic, the tuner just made splitting cheap.

### What else stops being true

- **The rule "update `defaultColor` in the same commit" becomes moot.** It guarded against two
  copies of a value drifting apart; there's only one copy now. This applies to its restatements in
  both [ADR-0059](0059-menu-bar-native-semantic-colours.md) § and
  [ADR-0060](0060-popup-native-semantic-colours.md) §.
- **`ColorStore.onChange` as the trigger for "instant" redraw** disappears — and with it the
  mention of the tuner among the cases where a color-transition animation gets cut short
  ([ADR-0070](0070-smooth-bar-colour-transitions.md) §). The rest of the cases (a theme flip,
  sleep/lock, a stub change) work as before; a snap on stub change follows its own path —
  `AppDelegate.switchScenario` calls `colorAnimator.reset()` directly, not through the store.
- **The argument "don't cache preview tiles, because the tuner changes colors"**
  ([ADR-0097](0097-bar-style-preview-rendered-at-runtime.md) §) loses one of its two grounds. The
  decision not to cache still stands — the second ground (redrawing on a theme flip) is sufficient
  on its own.
- **ADR-0064's point that "the tuner preview forces Vibrant appearance"**
  ([ADR-0064](0064-popup-translucent-card-and-glow-bars.md) §) now refers to a window that no longer
  exists. The mechanism itself is alive: the Settings preview carries it out through the same
  `PreviewChrome.vibrantAppearance`.

## Consequences

- **+** Minus ~1500 lines and two types; every color now has exactly one place it lives.
- **+** The dropdown preview is down to **one** — the source of confusion documented in
  `data-flow.md` is gone.
- **+** A palette change no longer requires a synchronized catalog edit.
- **−** There is no more live color picking. A replacement already exists and is documented
  ([ui-verification.md](../guides/ui-verification.md), the swatch-mode section): edit
  `ColorRole.defaultColor` → `TOKENPACE_SWATCHES=1` → measure with **Digital Color Meter** in sRGB
  on the **real** bar. For system semantic colors this isn't a regression but the only correct path
  — the tuner was flattening them anyway.
- **−** The WCAG helpers `relativeLuminance`/`contrastRatio` disappeared along with
  `ColorSpaces.swift` — they had no other consumers. If a contrast check is ever needed again,
  they'll have to be restored (the formulas are standard).
- **−** The color regression is **not** "zero by construction": the `devToolsEnabled` gate is a
  runtime `UserDefaults` read, so in theory `color()` could have returned something other than the
  default. In practice it's zero **by state**: overrides were never persisted, so the dictionary was
  empty on every fresh launch. Removing the layer pins that state permanently.
- As a side effect: `openDevTools()` no longer creates a second `PopupViewController` and a second
  floating window.

## Related

- [ADR-0046](0046-dev-color-tuner-override-layer.md) — the superseded decision (`ColorStore` plus a
  catalog for the tuner).
- [ADR-0047](0047-live-stub-selector.md) — the stub selector, which stays in the window.
- [ADR-0053](0053-devtools-flag-via-defaults.md) — the `devToolsEnabled` gate, unchanged.
- [ADR-0059](0059-menu-bar-native-semantic-colours.md) / [ADR-0060](0060-popup-native-semantic-colours.md)
  — the semantic colors that made the tuner pointless.
- [ADR-0083](0083-live-dropdown-preview-in-settings.md) — the preview that's now the only one.
