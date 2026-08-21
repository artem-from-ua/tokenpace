# Pixel alignment in the menu bar ("pixel hell")

Why the widget's elements sometimes look blurry on screen even though the geometry is "even" in the code,
and how to avoid it. Written after a session in which the diagnosis took several wrong turns — the
["How to diagnose"](#how-to-diagnose) section describes exactly where hours are easy to lose.

## In short

**`NSStatusBarButton` sits at a half-point coordinate.** Its 22 pt frame is centered in a status bar window
33 pt tall, which gives `(33 − 22) / 2 = 5.5`. Everything we draw in `snapshotImage()` reaches the screen
offset by **+5.5 pt**.

The counterintuitive consequence:

> **For an element's edge to be sharp, its `y` *inside the image* has to be a half-point** (`x.5`),
> not a whole number. A whole `y` in the image = a half-point on screen = blur.

| `y` in the image | `y` on screen (`+5.5`) | Result |
| --- | --- | --- |
| `8.5` | `14.0` | sharp |
| `4.0` | `9.5` | **blurry** |
| `4.5` | `10.0` | sharp |

## How it showed up

A single 5h bar (when the calm 7d one is hidden, #94) is centered as `rect.midY - barHeight / 2`
= `11 − 2.5` = **8.5** — a half-point by accident, which is why it always looked sharp.

Two stacked bars were centered as a block: `(22 − 14) / 2` = **4.0** — a whole number, so both bars blurred
at the top and the bottom. The difference between the two modes of the same widget was the symptom.

The fix is `halfPointAligned(_:)` in `StatusItemView`: it snaps the block's `topY` to the nearest half-point
(a shift of ≤ 0.25 pt, the block stays visually centered).

## Rules to follow

1. **The vertical coordinates of menu-bar widget elements are half-points.** For new elements, run `y`
   through `halfPointAligned(_:)` rather than relying on the arithmetic having "accidentally" produced the
   right number.
2. **The distances between elements are whole numbers of points.** `barGap` has to stay whole: the top
   bar's alignment carries over to the bottom one only when the offset between them is whole. A fractional
   gap will knock the bottom element off the grid again.
3. **Do not rely on the parity of the metrics.** That `(22 − 14) / 2` gives a whole number while
   `(22 − 15) / 2` gives a half-point is a coincidence of those particular numbers. Changing `barHeight` or
   `barGap` silently breaks the alignment if the coordinate is not run through the helper.
4. **An element's height affects where its edges land.** At an odd height (5 pt) centering yields a
   half-point, at an even one (6 pt) a whole number. Both work, but they require opposite alignment, which
   is why the helper is mandatory.

## How to diagnose

**A screenshot does not show this problem.** `screencapture` captures the backing store (2× the points),
where our elements land on whole pixels and look perfectly sharp. The blur is introduced later by the
compositor — when the backing store is output to the physical panel. Therefore:

- **The source of truth is Digital Color Meter** or the maintainer's eye on the live bar. This is the same
  reason [ui-verification.md](../guides/ui-verification.md#testing-menu-bar-widget-colors-swatch-mode--color-picker)
  forbids measuring colors from screenshots.
- **An empty result in a screenshot ≠ there is no problem.** In the session mentioned above, PNG analysis
  "proved" three times that everything was sharp while the maintainer was seeing blur live.
- **What is useful from the code:** print the button's actual position — that is exactly how the `5.5`
  coordinate was found:

  ```swift
  print("button frame in window:", button.convert(button.bounds, to: nil))
  // -> (8.0, 5.5, 44.0, 22.0)
  ```

- **Compare two states of the same widget** (one bar vs two) — if one is sharp and the other is not at the
  same element height, it is almost certainly alignment rather than size or color.

### False trails not worth spending time on

Hypotheses checked and **rejected** (in the order in which they tempt you):

- **"The bar heights differ"** — no, both modes draw 5.0 pt, and that is measurable reliably.
- **"The time-indicator marker is to blame"** — no; under `menuBarStyle = .pressure` (as under `.balance`)
  there is no marker in the menu bar at all, and the blur remains.
- **"A bare binary from `swift run` without an `.app` bundle"** — no, the release `.app` behaves the same.
- **"A scaled display resolution"** — it amplifies the effect but is not the cause: the blur reproduces
  through item centering too, and it is fixed in our code.
- **"Shift the bar to a position where the other bar is sharp"** — this does not work on its own: the shift
  has to be computed relative to `+5.5`, otherwise the element just moves to a different bad `y`.

## Where this lives in the code

- `StatusItemView.halfPointAligned(_:)` — the alignment helper.
- `StatusItemView.drawBars(fiveHour:sevenDay:reset:originX:in:)` — the two-bar block runs `topY` through the
  helper; the single-bar branch is already on a half-point by construction.
- `StatusItemView.Metrics.barGap` — a comment records the whole-gap requirement.

## Related

- [ADR-0009](../adr/0009-statusitemview-pure-layout-and-thin-shell.md) — the split of "pure geometry in
  `TokenPaceKit` / drawing in `StatusItemView`".
- [ADR-0059](../adr/0059-menu-bar-native-semantic-colours.md) — why the widget is drawn as a non-template `NSImage`
  (that is exactly why the intermediate image, where the coordinate grid lives, exists).
- [guides/ui-verification.md](../guides/ui-verification.md) — live verification of changes on stubs.
