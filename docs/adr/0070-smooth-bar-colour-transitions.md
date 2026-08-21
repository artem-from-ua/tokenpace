---
status: accepted
date: 2026-08-04
superseded_by: [0073]
---

# ADR-0070: Smooth pacing-bar color transitions — the project's first animation

> **P.S. (2026-08-07).** Partially revisited by
> [ADR-0073](0073-awaiting-icon-reserved-slot-and-slide.md) in two places, the rest of the
> decision still stands:
>
> - "**Geometry is deliberately not animated**" is narrowed: motion is now animated for **one
>   decoration inside a reserved slot** (the awaiting hand). The gap's length and the marker's
>   position still jump — there, animation would hide exactly the fact the bar exists to show.
> - The argument "**with no moving boundary, 30 fps is enough**" applies only to color. For
>   motion, the number was re-checked separately (ADR-0073 §8) and 30 was kept on its own
>   grounds.

## Context

The pacing palette is a set of **step functions**: `PopupBarView.aheadColor` / `behindColor`
return a discrete `NSColor` at a threshold (`PacingModel.aheadThreshold` / `behindThreshold`). The
moment `usageFraction` crosses the boundary, the color **jumps** — green→yellow→orange→red, or
green↔blue.

The problem isn't the thresholds themselves (they're correct and shared with the Kit's
`severity`, ADR-0044/0061/0062), but that near a boundary, adjacent polls land on different sides
of it, and the bar **flickers**. Toggling `CalmColorMode` produces the same kind of jump — a
colored bar instantly turns white.

Until now, the project had **no animation at all**: no `CABasicAnimation`, no
`NSAnimationContext`, no `animator()`. `StatusItemView` even has a documented policy to the
opposite effect: *"repaints only when the data changes — never on a timer (architecture.md:
energy efficiency)."*

## Alternatives considered

1. **Hysteresis on the thresholds** (different bounds for entering and leaving). Would remove
   flicker right at the boundary, but wouldn't touch any *real* transition — a jump green→orange
   after a genuine usage spike would be just as abrupt. Plus, two thresholds instead of one would
   have to be kept in sync with the Kit.
2. **CoreAnimation on layers.** Would work for the popup, not for the menu bar: the widget is
   drawn as a single non-template `NSImage` (`snapshotImage()`), because hosting a custom `NSView`
   in a status button isn't reliable (ADR-0059). `wantsLayer` + an overlay also **breaks**
   vibrancy (ADR-0059, option 2).
3. **Interception at the `ColorRole`/`ColorStore` level.** Looks cheapest, but roles are
   **shared**: `.green` covers bars, service dots, and text alike. Animating a role would drag
   along elements that changed for an unrelated reason.
4. **A dedicated tween layer, keyed by element (chosen).**

## Decision

**Interpolate the final resolved color of a specific element, ~1.0 s, a smoothstep curve; frames
are driven by a timer that only exists during the transition.**

### 1. The math lives in `TokenPaceKit`, AppKit-free

`ColorTween.swift`: `RGBA` (four channels as `Double`), `TweenCurve.smoothstep` (`3t²−2t³`),
`ColorTween` (from/to/startedAt/duration + `value(at:)`), `ColorTweenSet` (a registry keyed by
identity).

The reason for the split is testability: the sole test target depends **only** on the Kit
(`Package.swift`), and the `TokenPace` target has no coverage at all. All time-dependent behavior
is verified by passing explicit `Date`s instead of waiting on a real clock (24 unit tests).

### 2. The key — an element's identity, not its position

`TweenKey` = `.bar(surface:row:part:)` / `.credits(surface:part:)` /
`.serviceDot(surface:component:)`.

**A row is keyed by its name (`LimitRow.title`), not its index.** Per-model rows appear and
disappear (the "Show model-specific limits" toggle, a change in which models the response
returns), which shifts every index below them. Keying by index would **hand a vanishing row's
animation off to its neighbor** — Opus would visibly pick up Sonnet's transition. For the menu bar
the key is `LimitWindow.id` (`"5h"`/`"7d"`), more type-safe than a string literal.

The two surfaces have **separate** key spaces: the popup can be closed while the menu bar is
animating.

### 3. State lives outside the view

`PopupViewController.rebuild()` tears down and rebuilds **every** `PopupBarView` on each refresh
— the view has no identity across frames. So the registry lives on `AppDelegate`
(`ColorAnimator`), and the view carries only the key.

### 4. The timer only exists during a transition

`ColorAnimator` spins up a `Timer` (30 fps) on the first active transition and stops it on the
first frame where nothing is animating. **There is no loop outside transitions** — the
energy-efficiency policy still stands, only its wording changes: "never on a timer" → "on a timer
only while a color is changing."

`.common` run-loop mode is mandatory: the popup is an `NSMenuItem.view` inside an `NSMenu`, which
runs a modal tracking loop; a timer in `.default` mode would starve exactly where the transition
matters most.

**30 fps, not 60:** every menu-bar frame is a full `snapshotImage()` (lockFocus → draw the whole
widget → unlockFocus → a new `NSImage` for the button), noticeably more expensive than compositing
a layer. For *color*, with no moving boundary, 30 is enough — there's nothing to strobe.

### 5. It's the **final** tone that's interpolated

`resolve(...)` is called **after** `bright()`/`accent()` and after the calm-muting decision.
Consequence: the "colored → calm white" transition is smooth too, and ADR-0059's alpha/desaturation
agreements stay untouched. Glow in the popup (ADR-0064) fades for free — it's derived from the
same color; so does `GlowDotView.fill`, which was already a closure.

### 6. Where interpolation is **wrong** — snap instead

`finishAll()` (jump instantly to the target) applies to: **a theme flip** (the endpoints resolve
in *different* appearances — a blend belongs to neither), **the dev color tuner** (the tuner's
whole point is an exact color, immediately), **sleep/lock** (no one is watching), **a stub
change** (two unrelated worlds).

**An element's first appearance is never animated** — a new bar simply *is* its color, rather
than driving in from someone else's.

### 7. Cleanup by age, not by pass

`pruneStale` discards entries untouched for >5 s. A set of "drawn in this pass" doesn't work: the
two surfaces are drawn by **different** passes (the menu-bar image / the popup rebuild), and the
popup even redraws itself under NSMenu tracking — one surface's pass would evict the other's keys.

### 8. The `color-cycle` stub — direct color, frozen geometry

Polling can't be sped up: `PollingEngine.minInterval` = 60 s, with its own guardrail tests. So the
stub has **its own timer** (5 s per zone), which overlays `lastOutput` and re-renders — the same
trick as `fireOptimisticReset`. **No call to the usage API at all.**

The zone sequence: `blue → green → yellow → orange → red → orange → yellow → green` (both
directions of every adjacent transition), while service statuses cycle in parallel. The **5h bar
and dot** move; 7d stays a motionless reference alongside it.

**Geometry is frozen — but only on the 5h row** (`frozenStripFraction = 0.5`): if the zones were
driven by `usageFraction`, the strip's length and the marker's position would jump along with the
color, and the eye couldn't tell a color transition apart from a geometry jump. The other rows
(7d, per-model, credits) keep **real** geometry — a motionless reference next to the animated one.

**The time marker isn't hidden** — it parks at the end of the pinned strip. Otherwise, under the
stub, Progress would be indistinguishable from Pressure, meaning the stub would be verifying a
different presentation than the one it actually shows.

## Consequences

- **The first animation in the codebase.** The documented "never on a timer" policy is narrowed,
  not repealed: the timer only lives within a transition.
- **The 0.8 s duration was tuned live** (0.45 → 0.7 → 1.0 → 0.8). At shorter values, for
  neighboring hues (especially green→yellow), the fade finished before the eye could register it
  — that is, it read as the same abrupt jump the feature exists to remove. The bar is
  **ambient**: it's glanced at, not stared at, and no interaction waits for the transition to
  finish — so it can afford a duration long enough to read unambiguously as a transition. 1.0 s
  turned out slightly sluggish once the high-contrast blue→`calmWhite` transition became easy to
  trigger from a Settings toggle, so the value moved back to 0.8 s. The value is **not**
  configurable — no new Settings option.
- **The `pruneStale` threshold must exceed the app's slowest re-render interval.** "Untouched for a
  while" only means "gone from the screen" when a *present* element is guaranteed to have been
  drawn recently — and the widget deliberately doesn't redraw every tick, so between polls its
  floor is the 30-second `ageTimer`. The initial 5 s emptied the registry for 25 out of every 30
  seconds: a bar still visible on screen was swept out, and the next color change landed in the
  "key's first appearance" branch (`duration: 0`) instead of fading. That's exactly why the
  **first** toggle of calm mode after a pause snapped, while quick repeats animated. The threshold
  was raised to 45 s.
- **Toggles that only change color still go through `render()`.** `ColorAnimator.frameTime`
  advances only inside `beginFrame()`, which lives in `render(_:at:)`; a bare
  `refreshStatusImage()` dated the new tween to the moment of the last poll, so it was born already
  expired and the frame timer never started. The calm-mode callback now calls
  `reRenderForCurrentTime()`, like its neighbors.
- **`progress(at:)` carries an epsilon at the end.** A round trip through `Date` doesn't preserve
  a fractional interval exactly: `t0.addingTimeInterval(0.8).timeIntervalSince(t0)` yields
  `0.7999999523162842` (a shortfall of ~6·10⁻⁸ — single-precision resolution), so the fraction
  never quite reaches 1, and the transition would stay "almost finished" forever — the color a
  hair from its target, the frame timer never collapsing. A duration of exactly 1.0 s masked this;
  0.8 does not.
- **Geometry is deliberately not animated.** The gap's length and the marker's position still
  jump: they already change in small steps on every poll, and smooth geometry on every update
  would read as a "floating" widget.
- **The two surfaces stay in sync.** Both go through one `ColorAnimator` and the same
  `aheadColor`/`behindColor`; no color logic was duplicated.
- **`LimitWindow` became `Hashable`** (+ `id`) — additive, breaks nothing.
- **The per-frame cost on the menu bar is a full re-snapshot.** Accepted deliberately (see §4); if
  profiling ever shows a problem, the cheapest lever is `framesPerSecond`, a single constant.
- The transition was confirmed by measuring consecutive frames of a real bar: `sat` 183 → 175 →
  136 → 75 → 12 → 6 instead of a single jump (this is proof of **smoothness**, not color
  calibration — for RGB values the "Digital Color Meter only" rule still applies, CLAUDE.md).

## Related

- [ADR-0059](0059-menu-bar-native-semantic-colours.md) — eager resolution of semantic colors
  against `button.effectiveAppearance`; the source of the requirement to interpolate **after**
  resolution and snap on a theme flip.
- [ADR-0060](0060-popup-native-semantic-colours.md) — the unified palette across both surfaces.
- [ADR-0064](0064-popup-translucent-card-and-glow-bars.md) — the popup's glow takes the bar's
  color, so it fades for free.
- [ADR-0046](0046-dev-color-tuner-override-layer.md) — ColorStore/ColorRole; the tuner snaps
  transitions.
- [ADR-0044](0044-dynamic-pacing-threshold.md), [ADR-0061](0061-far-behind-blue-pacing-zone.md),
  [ADR-0062](0062-configurable-bar-presentation.md) — the thresholds between which the transition
  happens; **unchanged** (the presentation is animated, not the logic).
- [ADR-0047](0047-live-stub-selector.md) — the dev-tools selector that switches on `color-cycle`.
- [ADR-0073](0073-awaiting-icon-reserved-slot-and-slide.md) — the first **motion** animation: it
  reuses the duration, curve, epsilon, timer discipline, and the "state lives outside the view"
  rule from here; partially revisits the two points above (see P.S.).
