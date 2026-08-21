---
status: accepted
date: 2026-07-23
---

# ADR-0024: Configurable logical services instead of two fixed status components

> Replaces [ADR-0013](0013-claude-status-line.md) in scope ("exactly two fixed components,
> `Claude Code` + `Claude API`"). The rest of ADR-0013 (state source = `component.status` only,
> incidents not decoded, cadence floors, pure core/thin shell) still stands.

## Context

[ADR-0013](0013-claude-status-line.md) §1 deliberately hardcoded the scope into **two fixed
components** of status.claude.com — `Claude Code` + `Claude API (api.anthropic.com)` — as the
`claudeCode`/`claudeAPI` fields of the `StatusHealth` struct, with `worstProblem` being a
worst-of-2 over them.

Issue #89 makes the set **configurable**: in the Configure… window, the user chooses which logical
services to monitor. While the requirements were being refined, the model simplified relative to
the ticket's initial phrasing (instead of "one `Claude Code` toggle over two worst-of-two
components"):

```
[x] Claude API          ← gray, ALWAYS on, not editable       → monitors: "Claude API (api.anthropic.com)"
[x] Claude Code                                                → monitors: "Claude Code"
[x] Claude WEB/Desktop                                         → monitors: "claude.ai"
    (o) Chat only
    ( ) Chat and Cowork                                        → adds:     "Claude Cowork"
```

This raises decisions about: how to represent "a logical service = a group of 1–2 components with a
worst-of-N color," where the config lives, how the menu-bar dot aggregates several services, and
how to avoid breaking every consumer of `StatusHealth` while preserving the pure-core/thin-shell
split (ADR-0009/0013).

## Decision

1. **`StatusHealth` moves from a fixed pair of fields to a `checks: [ServiceCheck]` collection.**
   Each `ServiceCheck` is a semantic `ServiceID` (`claudeAPI`/`claudeCode`/`webDesktop`) +
   `coworkEnabled` + `[ResolvedComponent]` (named sub-components with their `ServiceStatus`) + a
   computed `status` = **worst-of-N** over the sub-components, using the existing
   `ServiceStatus.severity` (no new severity logic). This generalizes ADR-0013 §3 (per-component
   state) to groups.

2. **`Claude API` is an immutable, always-on service, not part of the config.** It is always the
   first `check`, unconditionally — because TokenPace's own ability to call the usage API depends on
   it. So **there is no empty state**: status.claude.com is always polled (if only for Claude API),
   and the original ticket's acceptance criterion "both off → don't poll" **does not apply**. There
   is no flag for Claude API in `MonitoredServices` — there's nothing to store.

3. **The config is `MonitoredServices` (a pure Codable value type in `TokenPaceKit`).** Two flags
   (`claudeCodeEnabled`/`webDesktopEnabled`) plus `WebDesktopMode` (`chatOnly`/`chatAndCowork`).
   Both types are `Codable` for persistence (ADR-0023: the `PersistedConfig` shell stores them as
   JSON in `UserDefaults`; the kit only describes the shape). `WebDesktopMode` is a raw-value
   `String` (`"chat_only"`/`"chat_and_cowork"`) with stable keys, and a forward-compatible
   `init(from:)` (an unknown mode → `.chatOnly`), like `ServiceStatus.unknown`.
   `MonitoredServices.init(from:)` decodes every key via `decodeIfPresent` + a default (a
   partial/old blob → defaults, not a crash), like `StatusSummary`.

4. **`from(_:config:)` and `unknown(for:)` replace `from(_:)` and `static let unknown`.** Both build
   `checks` through one private helper, `checks(for:statusOf:)` — the single source of truth for
   which services/sub-components exist given a config; they differ only in the status source
   (summary vs. the `.unknown` constant). The old parameterless `from(_:)` is gone (the
   `claudeCode`/`claudeAPI` fields disappeared), so the tests were rewritten around `checks`.

5. **The menu-bar dot is one, worst-of-all-enabled.** `StatusHealth.worstProblem` is now the most
   severe non-operational state among **all** sub-components of **all** enabled services (Cowork
   only in `chatAndCowork` mode), or `nil`. **The signature is unchanged** (`ServiceStatus?`), so
   `MenuBarLayout`, `StatusItemView`, `StatusCadence`, and the status loop in `App` are untouched.
   This is a deliberate choice against "one dot per service" (a wider widget, out of scope): the
   popup already distinguishes services by row.

6. **The popup renders one line per COMPONENT, not per service.** In the dropdown, each monitored
   component is its own line with its own status and colored dot: `API` always, then `Code`,
   `WEB/Desktop`, and `Cowork` (when the mode is `chatAndCowork`) — following the enabled services.
   So WEB/Desktop with Cowork produces **two separate lines** (`WEB/Desktop` + `Cowork`), not one
   collapsed "with Cowork" line. This is a deliberate choice for the user: every sub-component reads
   on its own, with no aggregation in the popup. The popup section header is now **"Claude"** (was
   "Claude Code").

7. **Component display names live in the view, matching names live in the kit** (the ADR-0009/0013
   seam). The view maps `ResolvedComponent.name` (a kit constant) to a short label in
   `PopupViewController.displayName(_:)`: `Code` / `API` / `WEB/Desktop` / `Cowork` — **with no
   "Claude" prefix** (that's in the section header); an unknown name falls back to the name itself
   (forward-safe). The matching constants in the kit became `public`, so the view can do this
   mapping by component name. **⌥ expansion was removed** — every line is now atomic (one
   component), so there's nothing left to expand. The visibility rule from ADR-0013 is preserved:
   status lines appear only on a real problem (`worstProblem != nil`); Claude API is not made
   "always visible" in the popup. `ServiceCheck` remains in the model (carrying
   `id`/`coworkEnabled`/`components` plus a computed worst-of-N `status`), but the popup now
   iterates `components` directly; the worst-of-N computation still exists for the menu-bar dot
   (`worstProblem`, worst-of-all across every component).

## Consequences

- `TokenPaceKit` stays free of AppKit: the new `ServiceID`/`ResolvedComponent`/`ServiceCheck`/
  `MonitoredServices` are semantics + `Foundation`. Mapping and worst-of-N are covered by unit tests
  (`StatusHealthTests` rewritten around `checks`; `MonitoredServicesTests` — defaults, a Codable
  round-trip, forward-compatible decoding). The Settings UI and persistence are manual-verify
  (shell).
- **The blast radius is small thanks to keeping `worstProblem: ServiceStatus?`**: the real changes
  are `StatusHealth` (the model), `PopupViewController` (iteration + `displayName` + the ⌥
  sub-lines), the `from` call sites plus the new config field in `App`,
  `SettingsWindowController` (the General/Monitored services sections), `PersistedConfig` (+ the
  `monitoredServices` key). `StatusClient`/`StatusSummary`/`StatusCadence`/`MenuBarLayout`/
  `PollingEngine` are unchanged.
- **A config change applies live**: `AppDelegate.monitoredServicesChanged` drops the stale
  `lastStatusHealth`, forces an immediate re-poll (via the `.manualRefresh` heartbeat), and redraws
  — so the dot/lines match the new service set within a moment.
- **ADR-0013 is partially superseded** (the two-fixed-components scope); its record stays
  unchanged, its number/title is struck through in the README, its frontmatter becomes
  `superseded`, and a postscript pointing to this ADR is added at the top. The rest of 0013's
  decisions still stand and are reused here.

## Related

- [ADR-0013](0013-claude-status-line.md) — the earlier decision (two fixed components), superseded
  in scope; its state source / cadence / seam split still stand.
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — the pure core / thin shell split,
  localization in the view; service display names follow the same split.
- [ADR-0023](0023-persisted-config-version-marker.md) — the persistence layer (`PersistedConfig`),
  which `MonitoredServices` extends with its own key.
- Issues: #89 (this ticket), #31 (the original status line), #71 (the persistence foundation).
