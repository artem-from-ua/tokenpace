---
status: accepted
date: 2026-08-19
supersedes: []
superseded_by: []
---

# ADR-0110: Legend — a static page rendered by the live code

> Completes stage 3 of the pages reorganization ([#317](https://github.com/artem-from-ua/tokenpace/issues/317)),
> where the reference page was planned under the working name `Guide`.
> Extends the precedent from [ADR-0097](0097-bar-style-preview-rendered-at-runtime.md) ("style
> previews are drawn at runtime by real code, not by images") from **comparing styles** to
> **explaining markers**, and uses the `PopupBarView.render(in:)` seam that was carved out
> specifically for this ([ADR-0093](0093-bar-style-picked-by-picture.md)).
> Does not change any rule from [ADR-0098](0098-ruler-split-identify-always-explain-on-option.md)
> (the ruler under ⌥) — but it introduces the one place where ticks are visible **without** ⌥, and
> §3 explains why this is not an exception to that rule but its direct consequence.

## Context

TokenPace encodes a lot of meaning in very little space: five pacing colors, three bar styles
([ADR-0080](0080-per-surface-bar-style.md), [ADR-0101](0101-pressure-is-the-gauge-ahead-half.md),
[ADR-0109](0109-centred-style-renamed-to-balance.md)), a dozen SF Symbols, badges, a ruler.
**None of it is explained anywhere in the app** ([#261](https://github.com/artem-from-ua/tokenpace/issues/261)).
A user who sees a blue strip, a raised palm, or a currency symbol has no way to find out what they
mean: the knowledge lives in `USER-GUIDE.md`, in ticket threads, and in the maintainer's head.

Three questions had to be answered **before** writing any code, because each one determines the
other:

1. **Where the images come from.** Screenshots and hand-drawn diagrams go stale silently: the very
   first change to a metric or a threshold makes the reference page lie about the app it lives
   inside. A reference page that lies is worse than no reference page.

2. **Whether the page reacts to the user's settings.** The temptation is obvious: show exactly the
   bar style and palette the person picked. But the page explains **every** style and **every**
   color — including the ones not visible in the current configuration.

3. **Where it lives.** A standalone sidebar row, as originally planned in
   [#261](https://github.com/artem-from-ua/tokenpace/issues/261), a child of a page, or its own
   window behind `HelpLink`. This isn't cosmetic: it determines whether you can read the
   explanation **while also** operating the switch it explains.

## Decision

### 1 · Every element is drawn by the production code

No images in resources, no duplicated drawing. Bars go through `PopupBarView.render(in:)` and
`StatusItemView.snapshotImage()` — the same calls used by the popup and the menu bar. Tier colors
come from `PopupBarView.aheadColor`/`behindColor`, called by the widget itself. Glyphs come from
`LegendGlyphs`, which the drawing sites in `StatusItemView` **also read**.

The last part is not a detail. Before this, SF Symbol names were string literals at every drawing
site, and the legend could advertise a glyph the widget no longer drew. A shared catalog makes that
drift impossible: renaming a symbol breaks both sides at once, and visibly.

The states the samples are drawn from live in `LegendCatalog` **in the Kit, not in the app** — so
they're covered by tests (the app target has no test target at all,
see `Package.swift`). Every state is built through
`PacingModel.barLayout(utilization:resetsAt:now:window:blueAllowed:)`, never a `BarLayout` literal —
for the same reason that's forbidden in `ui-state-truth.md`: a literal lets you draw a combination
the model never produces.

### 2 · The page is static, and that is not a compromise

The demo states are fixed. The page does **not** read the user's `BarStyle` or their `ColorAdvice`.

Reactivity looked correct at first and was rejected because it contradicts the page's whole
purpose: it explains the **vocabulary**, not the current configuration. A user with Balance on both
surfaces still needs to learn what Progress and Pressure are — otherwise they won't know what the
switch on the neighboring page is offering them. A page that only shows what's already chosen
explains the least to exactly the person who never changed anything.

The second, more practical argument: a reactive page has exactly as many states as Appearance does,
and none of them are covered by tests. The static page has one — the one in the PR screenshot.

There is exactly one exception, and it isn't about settings: **theme**. The dropdown samples are
non-template `NSImage`s, their semantic colors are resolved at bake time, so the view reads
`@Environment(\.colorScheme)` and redraws them on a switch. Glyphs are handled differently — a
template image plus `.foregroundStyle`, i.e. the platform's own answer to the same problem. The
menu-bar samples are immune: they are deliberately pinned to `.vibrantDark`, because the menu bar
is dark under any theme.

### 3 · The ruler on anatomy bars is always on

[ADR-0098](0098-ruler-split-identify-always-explain-on-option.md) hides the ticks under ⌥, because
in the live popup they are the explanatory half of the ruler, and a bar that shows them all the
time is louder than it needs to be. The style tiles keep them off for a second reason: a tile baked
with ⌥ on advertises a state the row isn't actually in.

This page is exactly the case both arguments carve out. It exists **to name the parts**, and the
ruler is one of them: a diagram captioned "hour/day ticks" next to a bar with no ticks explains
nothing. So `showsRuler` is a renderer parameter, on for anatomy bars and off for the short reading-
rule samples, which are about the strip, not the scale.

A consequence that cost a separate iteration: `PopupBarView.viewHeight` **does not include** the
ruler's depth —
[#388](https://github.com/artem-from-ua/tokenpace/issues/388) deliberately removed that band because
in the live popup it read as empty padding. A canvas exactly `viewHeight` tall clipped 2 of the
ticks' 5 pt, and the sample lied about their size. Hence `PopupBarView.rulerDepth` — a public
constant for anyone drawing a bar **together with** its ruler.

### 4 · A child of Appearance, not a sidebar row

Legend is `SettingsChildPage.appearanceLegend`, the first section on the Appearance page, **above**
the presets.

The original plan ([#261](https://github.com/artem-from-ua/tokenpace/issues/261),
[#317](https://github.com/artem-from-ua/tokenpace/issues/317)) put it in a standalone sidebar row
next to About. That was rejected for the same reason the ticket weighed `HelpLink` into its own
window: **reading the legend shouldn't require leaving the page where the switches it explains
live.** A child of Appearance gets this almost for free — the "back" step leads exactly where you
came from, and the dropdown preview stays on screen.

A side benefit that settled everything else: `TOKENPACE_SETTINGS_SECTION` indices **don't shift**. A
standalone sidebar row would have bumped every section after About by one and rewritten every
recipe in `ui-verification.md`
([#333](https://github.com/artem-from-ua/tokenpace/issues/333) already showed what that costs). Child
pages live in their own range of raw values; Legend got `53`.

A cost this decision didn't reveal right away: **the dev hook couldn't see the page.** The dotted
index `TOKENPACE_SETTINGS_SECTION` resolves through `SettingsChildPage.pages(of:)`, which filters on
`configuresSurface` — Legend configures nothing, so it wasn't in the list, and no index named it.
Worse than plain unreachability: recipes were written as `=53`, i.e. as a **raw value**, which
parses as a *section*; the hook honestly logged `unknown section 53 — ignored` and opened whatever
the window had last shown — which was usually Legend itself. The recipe looked like it worked.
The logging of unknown values added in [#341](https://github.com/artem-from-ua/tokenpace/issues/341)
specifically against this didn't help here: the value was never a child index to begin with.

Hence `reachablePages(of:)` next to `pages(of:)` — two different questions, two different answers.
The parent page asks "what do I draw in the unnamed surfaces section" (without Legend, or the row
would double up); the hook asks "what can I open" (everything the user can reach). Sorting is **by
display order**, because the Legend row sits above both surfaces while its raw value is the
largest of the three; sorting by raw value would name the page's second row `2.0`. Current indices:
`2.0` Legend, `2.1` Menu bar, `2.2` Dropdown.

The `HelpLink` → Help Book option is rejected for good: it requires a `.help` bundle with static
HTML, which directly contradicts §1. `HelpLink` → its own window remains a possible next step if
the Appearance child turns out to not be discoverable enough — but it adds a window that has to be
placed alongside the two that already exist (Settings and the preview), and that's worth doing from
data, not preemptively.

### 5 · Diagram geometry is derived, not hardcoded

The leader lines and captions of the anatomy bar live in **one** coordinate space
(`ZStack` + `.offset`), and `Geometry` computes the verticals by reading the metrics of
`PopupBarView` itself. A leader line's length is the distance from a marker to its caption row, not
a number written next to it.

This is already the second revision: the first laid out captions in three stacks, each with its own
padding, and every edit to one shifted the others — captions drifted off their markers, and lines
fell short of the marker, the ticks, and the track by turns. The distinction is fundamental: in
derived geometry, drift is **impossible**; in hardcoded geometry it's merely invisible until someone
looks at a screenshot.

The horizontals stayed as constants — deliberately. They come from the renderer's `scaleX`, and
deriving them would make the page depend on its internal **shape**, not just its values: a formula
change would then silently move the captions. A hardcoded number next to the arithmetic breaks
**visibly** — the caption ends up not over its marker, and that shows up in the very first
screenshot.

## Consequences

- **The legend can't drift from the widget graphically.** A change to a metric, a threshold, or a
  symbol redraws the page automatically. It can only drift in **words** — so the text remains
  something that has to be proofread by hand whenever behavior changes.
- **`USER-GUIDE.md` gets a source for its images.** Per the agreement in
  [#247](https://github.com/artem-from-ua/tokenpace/issues/247), the guide owns the prose, this page
  owns the graphics; screenshots for the guide are taken from it, not drawn separately.
- **Three new public members of `PopupBarView`**: `rulerDepth`, `tickGap`, and
  `trackTint`/`markerGlowScale`. The first two are ruler arithmetic for anyone placing something
  beneath it. The other two acknowledge that on the flat Settings surface, the track and the
  marker's glow read differently than on the popup's vibrant card.
- **The indices of two surfaces shifted** — `2.0`/`2.1` are now Legend and Menu bar, Dropdown
  became `2.2`. The recipes in `ui-verification.md` were updated; the hook has no external
  consumers.
- **The page is not covered by UI tests, and won't be** — the app target has no test target. So all
  the logic that can be verified was pulled out into `LegendCatalog` in the Kit, and it is verified.
- **Ticks are visible without ⌥ in exactly one place in the app.** This is deliberate (§3), but it
  is also the sole counterexample to the rule in
  [ADR-0098](0098-ruler-split-identify-always-explain-on-option.md), which will need to be
  remembered the next time the ruler changes.

## Open questions

- **Discoverability.** Legend sits two clicks deep (Appearance → Legend) and is mentioned nowhere
  else. If it turns out people can't find it, the cheapest next step is a row in About or an item in
  the status-item menu; neither needs a new window.
  Related to [#291](https://github.com/artem-from-ua/tokenpace/issues/291) (onboarding and hints).
- **Text synchronization.** The words on the page and in `USER-GUIDE.md` need to match, and nothing
  checks that. For now it's manual discipline, tracked in
  [#247](https://github.com/artem-from-ua/tokenpace/issues/247).
