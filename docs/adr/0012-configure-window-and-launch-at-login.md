---
status: superseded
date: 2026-06-22
superseded_by: [0018]
---

# ADR-0012: The "Configure…" window and launch at login (SMAppService)

> **Partially superseded by [ADR-0018](0018-launch-at-login-notfound-recovery.md):** the part of §4's
> decision about "unavailability is visible, not silent" (treating a `.notFound` status as terminal →
> a grayed-out disabled checkbox) is gone. `.notFound` comes back **after a bundle is replaced on
> update** too, not only under `swift run`; the checkbox is now always clickable and `register()`
> decides for itself (#69). The rest of this ADR (a separate window, the pure-core / thin-shell split,
> opt-out, best effort on unsigned builds, the menu actions) still stands; the body is kept in its
> historical form.

> **Note (a later change):** the menu item and the window were subsequently renamed `Configure…` →
> `Settings…` (and the type `ConfigureWindowController` → `SettingsWindowController`). The decision
> still stands — only the label changed; this ADR's body is kept in its historical form.

> **Note (2026-07-22, [ADR-0020](0020-troubleshoot-window-and-diagnostics-pipeline.md)):** §5/§7 in
> the part about "items without a shortcut (`keyEquivalent=""`)" no longer holds. "Settings…" got
> `⌘,` and "Quit TokenPace" got `⌘Q`: a non-empty keyEquivalent is a **mandatory** precondition for a
> native ⌥ alternate ("Troubleshoot…"), so the visible glyph is now deliberate. This ADR's body is
> historical.

## Context

Issue #14 ("launch at login + Quit") is Phase 1's last infrastructure item. It needs minimal settings:
launching at login through `SMAppService.mainApp`, and an item to quit. The user widened the scope
beyond the original ticket: at the bottom of the detailed popup menu, two items — `Configure…` and
`Quit cc-timer` — where `Configure…` opens a **separate settings window** (the launch-at-login toggle,
the version, a link to the repository).

That produces several decisions of the same class as ADR-0009…0011 (where the module's boundary is,
what gets tested and what does not), plus two specific to this ticket:

1. **A settings window, contrary to the SPEC.** SPEC.md says outright "No settings screen" (just the
   launch-at-login toggle plus Quit, as "sensible defaults"). The user's decision deliberately
   overrides that.
2. **The autostart policy** — register on launch (opt-out) or only on an explicit click (opt-in).
3. **How to surface the actions** — as separate `NSMenuItem`s below the hosted popup, or as buttons
   inside the hosted view.
4. **How to open a window from an accessory app** (no Dock, `.accessory` policy).
5. **`SMAppService` is a system singleton** that cannot be injected or mocked: where the boundary of
   the testable part lies.

## Decision

1. **A separate `Configure…` window (despite the SPEC's "no screen").** The autostart toggle needs
   *some* affordance; a window is more discoverable than a menu checkbox and gives the version and the
   repository link a natural home. This is a deliberate departure from SPEC.md, recorded here. The
   Phase 1 content: a "Launch cc-timer at login" toggle, a `Version <CCTimerKit.version>` line, and a
   GitHub link.

2. **A pure `LaunchAtLogin` core in `CCTimerKit` plus `LaunchAtLoginController` glue in `cc-timer`** —
   the same pure-core / thin-shell split as `UsageHealth` (ADR-0010) and `AdaptiveCadence` (ADR-0011).
   `SMAppService` cannot be injected, so the code that *calls* `register()`/`unregister()`/`status`
   lives in the executable and is verified by hand (like `PollingShell`). Only the pure semantics are
   tested:
   - `LaunchAtLogin.Status` — a framework-free mirror of `SMAppService.Status`
     (`registered`/`notRegistered`/`requiresApproval`/`notFound`).
   - the `shouldRegisterOnFirstLaunch` / `toggleState(for:)` / `needsSystemSettings` predicates (table
     tests in `LaunchAtLoginTests`).

3. **Opt-out autostart on first launch.** If the status is `.notRegistered` → `register()`
   automatically; leave every other status alone (the user or the system already decided). The result
   is logged through `AppLogger.lifecycle` (`.notice` for events, `.error` for failures,
   `privacy: .public` for the details).

4. **Best effort on unsigned builds — the key limitation.** `SMAppService.mainApp` is reliable **only
   on a signed** `.app` bundle. What follows, by build type:
   - `swift run` (a bare binary with no bundle) → status `.notFound` → opt-out does **not** register
     (there is nothing to register); the toggle shows as off. That is correct, not a bug.
   - an unsigned `.app` (no Developer ID, as on a personal MVP) → `register()` is unreliable: it may
     throw, or fail to activate the login item; the toggle may stay off even after a click.
   - a signed `.app` (Developer ID) → autostart and the toggle work reliably.

   So every `register()`/`unregister()` call is wrapped in `do/catch`: a throw is logged and **never**
   brings the app down. Full reliability is expected once signing is in place (SPEC §"Phase 1 scope").

   **Unavailability is visible, not silent.** When the status is `.notFound` (there is no registrable
   login item for this code identity — `swift run` or an ad-hoc bundle), the `LaunchAtLogin.isAvailable`
   predicate returns `false`: the window **disables** the checkbox (grayed out) and explains why right
   next to it — install `cc-timer.app` and launch it from Launchpad/Finder, not a dev build. That way
   the user does not click a toggle that does nothing. On available statuses the hint honestly notes the
   best-effort behavior on unsigned builds.

5. **Separate `NSMenuItem`s below the hosted popup (the user's decision, to judge by eye).** A
   `separator` plus `Configure…` plus `Quit cc-timer` in the same `NSMenu`, both with
   `keyEquivalent=""` (no shortcut) and `target=self`. The alternative — buttons inside the popup's
   hosted view (one visual block, but with its own hover highlighting plus `cancelTracking`) — remains
   the fallback if the look of separate items does not satisfy.

6. **No `setActivationPolicy(.regular)` for the window.** An accessory app brings the window to the
   front with `NSApp.activate(ignoringOtherApps:)` plus `window.level = .floating` plus
   `makeKeyAndOrderFront`. Switching to `.regular` would add a flickering Dock icon for the sake of a
   single window. The window is single-instance (`isReleasedWhenClosed = false`, the `configureWC`
   field): a second click focuses the existing one rather than creating another.

7. **Quit goes through the standard `NSApplication.shared.terminate(nil)`** — which guarantees that
   `applicationWillTerminate` runs (cleaning up pollTask/ageTimer/sleepWake/network, unchanged). There
   is no default ⌘Q, because there is no main menu (`.accessory` plus no `setMainMenu` anywhere) — so
   there is nothing to remove.

## Consequences

- `CCTimerKit` stays free of AppKit and ServiceManagement: `LaunchAtLogin` deals purely in semantics →
  reusable in Phase 2 (iOS/watchOS can have their own registration behind the same enum and
  predicates).
- The feature's test coverage is just three predicates (`LaunchAtLoginTests`); all of the
  SMAppService/NSWindow/NSMenu glue is manual verification, as the convention has it (ADR-0009 §8).
- The toggle re-syncs with `SMAppService.status` every time the window is shown
  (`syncToggleFromSystem`), because the user may have changed the state in System Settings. On
  `.requiresApproval` after `register()`, the window points the user at System Settings → Login Items
  (`openSystemSettingsLoginItems`).
- **A known limitation:** on an unsigned build, autostart is best effort (see Decision §4). Real
  registration has to be checked on a signed `.app`; on a dev build the toggle being off is expected.
- **Verified (2026-06-22):** on a Developer ID-signed and **notarized** `.app` launched from
  `/Applications`, `SMAppService.status` → `.enabled`, the toggle is active and on; opt-out on first
  launch works. `swift run` / running the binary directly → `.notFound` (as expected). The
  signing-plus-notarization setup lives in `scripts/build-app.sh` (ADR-0004).
- If Phase 2 brings more settings (the interval, themes) — the same window is extended; a new decision
  about their content or behavior → a new section here or a separate ADR.

## Related

- [ADR-0002](0002-ukrainian-documentation.md) — the documentation's language (this window stays
  unlocalized in Phase 1).
- [ADR-0004](0004-build-system.md) — the bundle/Info.plist/signing; `SMAppService` depends on a valid
  signed bundle.
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md),
  [ADR-0010](0010-usage-health-and-error-states.md),
  [ADR-0011](0011-polling-engine-adaptive-cadence-and-signal-seams.md) — the same pure-core /
  thin-shell split and "the glue is not tested".
