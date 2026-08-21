---
status: superseded
date: 2026-08-14
supersedes: []
superseded_by: [0097, 0100]
---

# ADR-0093: The menu bar's bar style is picked by picture, not by word

> **Partially superseded by [ADR-0097](0097-bar-style-preview-rendered-at-runtime.md)**: §1
> (pictures are static PNGs) and §3 (shown unscaled) no longer stand — the tiles are drawn at
> runtime by the widget's own code, and the specimen has its own natural size of 38×22 pt. §2
> (black background) remains as a **decision**, but its rationale changed: the shadow from
> `screencapture` disappeared along with the screenshots, and an opaque tile is now needed so the
> press layer's `.lighten` doesn't bleed through the render's alpha. §4 (frames shown in full)
> still stands unchanged. **§5 (menu bar surface only) has been superseded by
> [ADR-0100](0100-dropdown-style-tiles-and-retired-option-segment.md)**: the dropdown row is now
> also picked by tiles, and the asymmetry named "temporary" here has been resolved.
>
> The cost named here in "Consequences" as hypothetical — "previews can go stale silently" —
> **came true within two releases**: [#371](https://github.com/artem-from-ua/tokenpace/pull/371)
> and [#372](https://github.com/artem-from-ua/tokenpace/pull/372) gave Pressure a zero tick, and
> the screenshots stayed old. That's exactly what triggered the switch.

## Context

The **Settings → Menu bar → Bar style** row offered three words — `Pressure | Gauge | Progress` —
in a text segmented control. The words don't carry what actually distinguishes the styles: the
difference is purely visual (where the strip grows from, whether it has a time marker, which zero
it measures against).

An attempt to close the gap with prose had already been made and rolled back: in #341, three
paragraphs describing the styles were removed — they cost more vertical space than they gave back.
The comment left in the row's place justified the lack of hints with the live preview beside the
window ([ADR-0083](0083-live-dropdown-preview-in-settings.md)). That justification didn't hold: that
preview renders the **popup**, meaning it doesn't show this particular row's style at all. The
menu bar row was left with no way to see the choice before clicking.

At the same time, [system-settings-parity.md](../reference/system-settings-parity.md) sets a goal:
"TokenPace should follow the interface design of native macOS apps as closely as possible… System
Settings above all." The system's own **System Settings → Appearance** solves the same problem — a
choice that can only be described visually — with a row of labeled pictures and an accent outline
around the selected one.

## Decision

**The menu bar's Bar style row is picked by preview pictures**, in the form of the system's
Appearance picker: three tiles in a row, a label under each, a `Color.accentColor` outline around
the selected one, its label in bold.

Downstream decisions, each with its reason:

1. **The pictures are static PNGs in resources, not a runtime render.** A deliberate intermediate
   step: screenshots of the real widget give a truthful preview immediately, whereas a live render
   would require extracting `StatusItemView.render(in:)` into a portable context. A seam for
   replacement was left in place — the picture source is localized in a single property,
   `BarStylePicker.images`; switching to a live render only changes that.

2. **The tile background is black in both themes.** Not an oversight, and not a semantic color.
   The screenshots were taken with `screencapture` in windowed mode, so their transparent margins
   carry a black shadow (α ≤ 24, measured). It disappears on black; on any light surface it would
   have produced a gray halo around every preview. As a side effect, this is also true of the
   subject itself: the menu bar is dark even in light mode.

3. **The pictures are not scaled.** They're shown at their natural 54×33 pt (@2x files, 108×66 px)
   inside a roomier tile. The point of the preview is "how this will look in my menu bar"; a
   doubled-size widget answers a question nobody asked, and upscaling a 5-pt bar blurs exactly the
   subtlety that makes `Metrics.barHeight` that thin in the first place.

4. **The frames are shown whole, uncropped.** Progress's time marker and Gauge's center tick
   extend past the bar strip; cropping to the "useful" content would cut off exactly what
   distinguishes the styles.

5. **Menu bar surface only.** The dropdown row remains a text segmented control.

## Consequences

**The two surfaces temporarily have different controls for one choice.** This is deliberate, not
an unfinished refactor: verify the shape on one surface first, migrate the dropdown in a separate
PR. Both controls read `AppearanceBarStyle.segments`, so the order and labels are shared and
cannot drift apart — this is also what keeps the release-notes recipe working, since it greps
labels straight out of `UIPanes.swift`.

**Previews can go stale silently.** The PNGs freeze the widget's current geometry and palette; a
change to `Metrics.barWidth`/`barHeight`/`barGap` or the pacing colors makes them false with no
signal from the compiler at all. The mitigation is partial: the `images` doc comment lists the
constants the screenshots depend on. This is the main cost of the static approach and the main
argument for a future live render.

**The preview shows a single pacing state** (green 5h + orange 7d). No far-behind-blue, no red, no
idle. The system's Appearance picker likewise shows a single state.

**The project got its first resource bundle.** This wasn't free: `scripts/build-app.sh` used to
build the `.app` by copying only the binary, so the bundle had to be copied explicitly — and
**before** `codesign`, otherwise the signature breaks. The script fails with an error if the bundle
is missing, because otherwise the defect is invisible: under `swift run` the bundle sits right next
to the binary, and an `.app` with no pictures would pass every check unnoticed. The convention is
recorded in [conventions.md](../reference/conventions.md).

> Added later: this check turned out insufficient. Copying the bundle into `Contents/Resources` is
> correct, but `Bundle.module` looks for it in the **wrong place**, so 0.94.0 crashed on opening
> this picker. The cause and the accessor replacement — [ADR-0095](0095-own-resource-bundle-lookup.md).

**The row became three times taller** than a normal one (tile + label vs. a segmented control).
The Settings window's height is unconstrained
([ADR-0069](0069-settings-window-height-resizable.md)), so this is safe; the "Bar style" label is
top-aligned, otherwise it would sag in the middle of the block.

## Alternatives considered

**A system primitive.** Checked in the AppKit SDK headers: Apple doesn't expose a "row of picture
options" control (`NSColorPicker`, `NSDatePicker` exist; the Appearance picker in System Settings
is private). So a custom SwiftUI control here doesn't violate "prefer a system mechanism first"
([ADR-0040](0040-native-system-metrics-no-hardcoded-ui.md)) — no system mechanism exists.

**Generalize the existing `SegmentedControl`.** It serves five different enums and needs to stay
value-agnostic; a picture per case would drag resources into the generic control and smear one
responsibility across two files.

**Explain the styles in text.** Already tried and rolled back (#341).

## Related

- [ADR-0080](0080-per-surface-bar-style.md) — the style choice made separately per surface.
- [ADR-0083](0083-live-dropdown-preview-in-settings.md) — the live popup preview beside the
  Settings window; this ADR closes the gap it left for the menu bar surface.
- [ADR-0076](0076-pressure-scale-for-marker-less-bar.md), [ADR-0079](0079-centred-zero-gauge-scale.md)
  — the scales the previews show.
- [system-settings-parity.md](../reference/system-settings-parity.md) — the System Settings parity
  goal.
