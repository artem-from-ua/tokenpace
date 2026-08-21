---
status: accepted
date: 2026-08-13
---

# ADR-0084: Settings child pages — drill-in, not sidebar rows

> Partially supersedes [ADR-0042](0042-settings-swiftui-form.md): `enum SettingsSection` is **no
> longer** the single source of where the window can navigate to — a route is now a pair, "section +
> optional child page," and `TOKENPACE_SETTINGS_SECTION` addresses both levels. The rest of 0042
> (SwiftUI `Form.formStyle(.grouped)`, `NavigationSplitView`, `@Observable SettingsModel`, the
> `AppDelegate.openSettings` contract) stands in full.

## Context

[#341](https://github.com/artem-from-ua/tokenpace/issues/341) removes the `Extra features` pane and
puts `Providers` in its place. The reason isn't the name: `Extra features` had no **axis** it could
grow along. It was a junk drawer — things that didn't fit anywhere else got put there, and Monitored
services, Sessions backup, and Session status had about as much in common as a sock and a screwdriver
in the same drawer.

`Providers` does have an axis, and it immediately demands a level of navigation the window never had.
There will be more than one provider (Codex is next), and each has its own set of things it collects
and monitors. Three layout options:

- **flatten everything onto one page** — with a second provider it becomes a list of toggles where
  "Claude Code" and "Codex CLI" sit side by side with nothing grouping them;
- **a sidebar row per provider** — the sidebar grows linearly with providers, and rows of different
  classes start appearing in it: "Notifications" (what the app does) next to "Claude" (whose data it
  is);
- **drill-in** — a row per provider on the parent page, each leading to its own page.

The third is what System Settings does in Network and "Internet Accounts," and it's the one that
doesn't change the sidebar's shape when a provider is added. It was chosen.

Two obvious drill-in implementations fall away for specific reasons.

**Indented rows in the sidebar** would turn the sidebar into a tree. System Settings doesn't do that:
its sidebar is flat, and details open via drill-in inside the detail column. We're copying exactly
that (see [system-settings-parity.md](../reference/system-settings-parity.md)), and a flat list is
also what keeps `SettingsSection` usable as the source of row order.

**SwiftUI's `NavigationStack` / `NavigationLink`** falls away because of a boundary the project has
already paid for twice. [ADR-0077 §3](0077-settings-toolbar-segmented-back-forward.md) established
this instrumentally: a `NavigationSplitView` inside an `NSHostingController` **doesn't register its
columns with the toolbar bridge**, so SwiftUI `.navigation` items surface above the **sidebar**, next
to the traffic lights, rather than above the detail column. `NavigationStack`'s built-in back button
would have painted exactly there. This is the same wall [#156](https://github.com/artem-from-ua/tokenpace/issues/156)
ran into with the pane title, and [#314](https://github.com/artem-from-ua/tokenpace/issues/314) with
the ‹ › pair.

Drawing a custom header with "‹ Back" inside the detail column was also already tried and rejected —
`SettingsToolbarController`'s doc comment ("Why the toolbar, and not a row in the detail column")
describes why: three independent sources of vertical spacing in a row, tuning one moves the other two.

## Decision

**Navigation state stays ours; SwiftUI only gets the job of showing the right view.**

1. **The route is a pair.** A generic `NavigationRoute<Section, Child>` in Kit: a section plus an
   optional child page. The rules it owns: drilling in preserves the section; changing section resets
   to the root (a sidebar selection can't leave you stranded inside someone else's child page); parent
   and child are **different** values, which is exactly what lets `NavigationHistory` count them as
   separate stops, so ‹ returns from `Providers › Claude` to `Providers` rather than jumping past the
   whole section.

   Generic for the same reason as `NavigationHistory`: the app target has no test target
   (`Package.swift`), so everything with rules that are easy to break lives in Kit and gets tested
   against strings. `NavigationHistory` reparameterizes over `NavigationRoute` **with no change at
   all** to its own structure.

2. **The sidebar stays flat and binds to the section.** `SettingsModel.selection` stays a
   `SettingsSection` — the direct target of `List(selection:)`; the child page lives in a separate
   `childPage` field, and `route` is a computed pair. While a child page is open, **the parent
   sidebar row stays highlighted** with the ordinary blue selection color; checked on live System
   Settings (Network → Wi-Fi), which behaves the same way.

3. **The navigator row** (`SettingsNavigationRow`) is a plain `Button` with `.buttonStyle(.plain)` and
   `.contentShape(Rectangle())`, so **the whole row** is clickable, not just its drawn content.

   Its anatomy is taken from System Settings → **Network / "Internet Accounts,"** not General — and
   this is a deliberate departure from how the ADR scaffold this mechanism was inherited from
   described this row. General draws a row that only **leads** somewhere, so it carries just a name
   and a small chip. Our row **reports**: `Usage API · 3 services monitored` answers the question the
   page exists to answer, and reading it shouldn't cost a click. Hence the subtitle.

   **There's no icon at all.** The obvious candidate is the provider's logo, and it's legally shaky; a
   generic glyph would be decoration in a spot where information belongs. An empty leading edge on the
   row is more honest than either option.

4. **The toolbar doesn't change at all.** `SettingsToolbarController.update(title:canGoBack:canGoForward:)`
   operates on a string and two `Bool`s — it was already general enough; only where the title comes
   from changed (`route.title` — the child page's name, when one is open).

5. **The dev hook addresses both levels.** `TOKENPACE_SETTINGS_SECTION` accepts `<section>` or
   `<section>.<child index>`: `7` is `Providers`, `7.0` is its first child page. The child index counts
   pages **in display order**, not by raw value, so the recipe reads as "the first page under
   Providers" without needing to know `SettingsChildPage`'s numbering.

   The hook **lands on** a page (`openAtLaunch`) rather than "navigating" there: a freshly opened
   window has both chevrons dimmed, because the page is **where** it opened, not somewhere someone
   navigated to.

   An unknown value is now **logged**, not silently ignored. A hook that silently no-ops looks exactly
   like a hook that fired and landed on the default pane — that's exactly how a stale recipe survives
   unnoticed. And #341 retired index `4`, so stale recipes already exist.

## Consequences

- **The raw value `4` is retired from use and never reused.** It stays a permanent gap in the
  numbering. Documented recipes and other people's cheat sheets still carry it, and pointing an old
  `TOKENPACE_SETTINGS_SECTION=4` at some other pane would produce a recipe that **lies** rather than
  fails.
- **The hierarchy is exactly one level deep.** `drilling(into:)` from a child page **replaces** it
  rather than nesting: a child page has no navigator rows of its own, so there's nothing to push a
  second level onto. If one is ever needed, that's a deliberate change to `NavigationRoute`, not an
  accidental consequence.
- **No container appeared between `detail:` and the pane.** The child page swaps in at the same level
  as the pane — otherwise it would break the `.contentMargins(.top, -20)` that `SettingsRootView`
  applies to the detail column, shifting the top of every card.
- **The filler stays in the last group.** `TOKENPACE_SIDEBAR_FILLER` used to attach to the
  `Extra features` group; after the reshuffle it hangs off `Notifications`. A group, not a pane —
  because its job is making the list long enough to scroll, and it's the last group that's needed for
  that.
- `glyphOffsetY` was removed. Its only non-empty branch was for `puzzlepiece.extension.fill` (half a
  point up — one device pixel at 2×), and that glyph left along with its pane; the property became an
  identity zero.
- **Shared sections stayed on the parent page.** Monitored service incidents, Sessions, and Backup
  belong to no single provider: awaiting-input reads the local client's state and would apply to any
  provider with a local CLI, the incident threshold filters the popup for every service at once, and
  there's one archiver. Moving them down into `Claude` would claim a per-provider granularity that
  doesn't exist.

## Alternatives considered

- **A `NavigationStack` in the detail column** — its back button paints above the sidebar (ADR-0077
  §3). Using the stack only as a container while hiding its back button would mean maintaining two
  sources of navigation state (its `NavigationPath` and our history) and keeping them in sync; our
  history would remain authoritative anyway, because ‹ › also travel **between** sections, which the
  stack can't do.
- **Child pages as ordinary `SettingsSection`s with indentation** — turns the sidebar into a tree
  (unlike System Settings) and breaks `SettingsSection`'s role as a flat source of row order.
- **A separate `NavigationHistory` per section** — ‹ would have to decide which history to step
  through, and would stop being "like a browser." One history over the pair gets this for free.
- **A provider row modeled on General (a chip + a name, no subtitle)** — that's how the scaffold this
  mechanism was borrowed from described it. Rejected: our row reports state rather than merely
  leading somewhere; hiding that state behind a click would leave the `Providers` page essentially
  empty.
