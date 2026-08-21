---
status: accepted
date: 2026-08-15
supersedes: []
superseded_by: [0112]
---

# ADR-0099: `Appearance` is one pane again, and the two surfaces are its child pages

> Supersedes the decision in [#333](https://github.com/artem-from-ua/tokenpace/issues/333) to split
> `Appearance` into **three adjacent sidebar rows**. The axis of the split (the surface an option
> configures) still stands and doesn't change — only the level it lives at changes. The drill-in
> mechanics are [ADR-0084](0084-settings-drill-in-child-pages.md), unchanged; the preview's binding
> to the pane is discussed below and partially supersedes
> [ADR-0083](0083-live-dropdown-preview-in-settings.md).
>
> **The last paragraph of §"Presets — radio buttons with explanations" is superseded by
> [ADR-0112](0112-appearance-presets-preview-apply-commits.md):** `Custom` no longer exists — it's
> replaced by `My setup`, which is always clickable because it names the saved config itself, not a
> snapshot. The rest of the section (radio buttons instead of segments, the three wording rules)
> still stands.

## Context

[#333](https://github.com/artem-from-ua/tokenpace/issues/333) split the `Appearance` pane into
`UI presets` · `Menu bar` · `Dropdown` and set all three as top-level rows. The argument was
simple: the sidebar has room for three rows, and a divider would signal they belong together —
cheaper than the extra click a parent page would cost.

What actually resulted is visible on the live window. The sidebar has seven rows, and **two of them
are halves of one topic**: `Menu bar` and `Dropdown` don't answer "what does the app do" (the way
`General` or `Providers` does) and aren't separate topics — they're two surfaces the same thing gets
drawn on. Their kinship was carried **only by the divider plus a shared green capsule tint** — two
purely visual cues that only read after a user has already read the list.

A second problem the first one had been masking showed up separately: `Notifications` sat in **its
own group at the bottom**, cut off by a divider from the UI trio. #333's rationale was that it
configures a surface outside the app's windows (Notification Center). But once the two surfaces move
down a level, the top list is left with `Appearance` and `Notifications` — and both answer the same
question: **how the app presents itself**. The divider between them was drawing a distinction that
no longer exists at this level.

## Decision

**The two surfaces become child pages of `Appearance`**, and `Appearance` and `Notifications` share
one sidebar group with no divider between them.

Sidebar: `About` / **`General` · `Providers`** / **`Appearance` · `Notifications`** — five rows
instead of seven, three groups instead of four.

- **The mechanism is the same drill-in as `Providers › Claude`**
  ([ADR-0084](0084-settings-drill-in-child-pages.md)): a `SettingsNavigationRow` on the parent page,
  the child's name in the toolbar, ‹ returns to the parent. Nothing new was built —
  `SettingsChildPage` simply gained two cases.
- **`SettingsSection.appearance` keeps its raw value of `2`** through both renamings
  (`Appearance` → `UI presets` → `Appearance`): it's the same pane, so documented recipes and
  `TOKENPACE_SETTINGS_SECTION=2` still lead where they always led.
- **`5` and `6` are retired from circulation, the way `4` was before them.** The pages they used to
  name haven't gone anywhere — they moved down a level and are addressed with the dotted form
  `2.0` / `2.1`. Pointing the old `5` at some other pane would be a recipe that **lies**, rather than
  one that fails.
- **The surface chips move to navigation-row badges.** Black (menu bar) and white with a hairline
  (dropdown) — the same measured `CapsuleTint`s that lived in the sidebar, now via
  `SettingsRowBadge.tinted`. The `distribute.vertical` crop (the `0.28…0.72` band, measured on a
  64 pt glyph) is factored into a shared `SymbolTrim`: the band is a property of the **glyph**, not
  of where it's drawn, so it had to survive the move from the sidebar chip to the larger row badge.
- **The row's subtitle is that surface's current Bar style**, taken from the same
  `AppearanceBarStyle.segments` that labels the segments on the child page itself: a row saying
  "Gauge" while the control inside says something else would be worse than a row with no subtitle.
  It's written with a label — `Style: Gauge`, not a bare style name — because the row's title names
  only the **surface**, so "Gauge" alone would leave the reader guessing which of the page's several
  settings they were looking at. The label repeats the child page's control caption verbatim
  ("Style"), so the summary and the control it summarizes name the setting the same way.

### The dropdown preview binds to the pane

[ADR-0083](0083-live-dropdown-preview-in-settings.md) deliberately did **not** bind the preview to
the selected section: the argument was that a registry of "sections that show a preview" is one more
thing to keep in sync, and that a future pane (Guide/Legend, #261) would get the preview for free.

That decision is now revisited in one direction. The preview is a **second window occupying real
width** next to Settings; on `About` or `Notifications` it would occupy that width to answer a
question nobody asked on that page. The registry turned out to be a single computed property,
`SettingsSection.showsDropdownPreview`, which each new pane answers the moment it's added — the cost
named in 0083 turned out, in practice, to be smaller than the awkwardness it caused.

An easy-to-miss consequence: `occupiedWidth` returns **0** while the preview is hidden. Centering
treats the "window + preview" pair as one unit, so without this, a window opened on a pane without a
preview would drift left by half the width of a preview nobody sees.

### Presets — radio buttons with explanations, not a segmented control

The three names (`Chill` / `Work harder!` / `Control freak`) read as **a mood**, not as behavior, and
the question a user actually needs answered — *which signals does this preset make most
prominent* — has nowhere to fit in a segment. A radio group gives one line of prose per option; the
text lives in `AppearancePreset.summary`, next to the values it describes.

Three rules, each drawn from a live review:

- **Every line stands on its own.** The `Work harder!` draft started with "Like Chill, but…" — in a
  list, every item is someone's first read, and the middle one became unreadable without the one
  before it.
- **Name the cost, not just the benefit.** `Control freak` says "Maximum info, but signals take a
  bit longer to spot": turning off the dimming both shows the whole picture and makes it slower to
  read.
- **Never promise what ⌥ doesn't do.** The modifier reveals hidden rows and labels, but **never
  changes the bar style** — Pressure stays Pressure under ⌥. Wording like "the full picture without
  ⌥" would describe a swap the key doesn't actually perform.

The description under an option **does not change** with the option's state: a second string that
would appear only in one particular state would reflow the list under the cursor.

> ~~`Custom` is unclickable until there's a saved setup — but its row describes the option itself,
> not its current reachability.~~ Superseded by
> [ADR-0112](0112-appearance-presets-preview-apply-commits.md): the fourth row is now called
> `My setup`, names the saved config itself, and is always clickable. The rule about a stable
> description survived the replacement — a row's state is now conveyed by **a note next to the
> name** (`· same as *Chill* preset`), which is shorter and doesn't move rows under the cursor.

## Consequences

- The sidebar stopped mixing levels: all five rows are topics, none of them half of its neighbor.
- The two surfaces cost one click. That's the same cost 0333 avoided — and it's accepted as
  reasonable: surface settings are opened less often than the list is read.
- `TOKENPACE_SETTINGS_SECTION` has **three** dead indices (`4`, `5`, `6`) instead of one. Each is
  documented in the table in [ui-verification.md](../guides/ui-verification.md) with the reason and
  its replacement.
- `TitlePlaqueView` gained an **optional** second line; the dev tuner doesn't pass it and stays
  unchanged. In the Settings preview it mentions ⌥ — otherwise this feature is found only by
  accident.
- The preview is no longer "always on while the window is open," so any new pane where it makes
  sense has to say so explicitly. This is a deliberate cost: the silent default was exactly what
  showed it where it wasn't needed.
