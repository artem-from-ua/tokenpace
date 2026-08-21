---
status: accepted
date: 2026-07-24
superseded_by: [0036]
---

# ADR-0025: Update checking — dual fetch path, system banner, launch-time check

> **Partially superseded by [ADR-0036](0036-update-signals-single-dropdown-item.md).** The banner
> part (Decision §3, `UpdateNotifier`, `UNUserNotificationCenter`) is **removed** — no more system
> notifications; the signal is consolidated into a single dropdown item (0036). The fetch path (§1),
> `SemanticVersion` (§2), the cadence marker (§4), and the launch-time check (§5) still stand. The
> record below is unchanged historical context; read about the signal UX in 0036.

## Context

Until now TokenPace had no way to signal that a newer version was out — the user had to check GitHub
Releases themselves. Issue #37 (epic #3) adds a **periodic check** (twice a day) for the latest
release with an unobtrusive signal.

While clarifying requirements the scope grew beyond the original ticket (which excluded
notifications and a menu-bar item): the user asked for a **system macOS banner**, a **menu item**
with a blue dot (like the status indicators), and a **[Check now]** button in the settings window.

This raises decisions specific to this feature:

1. **Release source against a private repo.** The repository is currently **private**, so the
   anonymous GitHub Releases API returns 404. But the feature needs to work for the maintainers
   (Artem + Ostap) right now, not "sleep" until the repo goes public.
2. **The app's first system notification** — `UserNotifications` was never used before; the app is
   an `LSUIElement` agent (no Dock icon), which affects how the banner is presented and whether the
   framework is even available on an unsigned build.
3. **The first network-layer write into persisted config** — the `lastUpdateCheck` marker needs to
   advance on every check, which is semantically different from `StatusCadence`.

## Decision

1. **A dual fetch path behind the `UpdateFetcher` protocol.** One seam ("hand back the raw JSON
   bytes of the release") with two conformers:
   - `HTTPUpdateFetcher` (in `TokenPaceKit`) — anonymous HTTPS through the existing `UsageTransport`
     (no second transport protocol, ADR-0008); 404 → `.notFound`. Works once the repo goes public.
   - `GHReleaseFetcher` (in `TokenPace`) — runs `gh api …/releases/latest` as a **subprocess**, so a
     locally authenticated `gh` reads the private repo with its own credentials from the keyring.
     Selected at runtime when the **`TOKENPACE_GH_AUTH`** env var is set (a presence flag).

   **Resolving `TOKENPACE_GH_AUTH`:** the app starts at login through `SMAppService`, meaning
   launchd starts the `.app` **without a shell**, so `export TOKENPACE_GH_AUTH=1` in `~/.zshrc` is
   invisible through `ProcessInfo`. So the flag is resolved once (memoized): first `ProcessInfo`
   (launched from a terminal / `launchctl setenv`), then — as a fallback — from the login shell's rc
   files via `ShellEnvironment` (`zsh -l -i`). This way, `export` in `.zshrc` is enough for the user,
   with no `launchctl`/LaunchAgent needed.

   Both paths feed bytes into the **same** pure `GitHubReleaseDecoder` and the same
   `SemanticVersion`/`UpdateComparison` comparison, so decoding/comparison stay testable without a
   live network or process. The subprocess is a platform side effect, so it lives in the shell behind
   a kit protocol (like `DelegatedRefresher`/`ClaudeCLIRefresher`); it inherits the environment (`gh`
   needs `HOME`/keyring).

2. **`SemanticVersion` is written from scratch** (there was no semver in the project) as a pure
   `Comparable` struct: conservative parsing (exactly 3 numeric components after an optional `v`), a
   `-beta`/`+meta` suffix is tolerated (repo tags are flat `vX.Y.Z`, so pre-release ordering §11 is
   out of scope). **`UpdateComparison.isNewer` returns `false` on any parse error** — a "never act on
   garbage" contract: no unparseable tag surfaces a phantom update.

3. **The system banner is a bonus channel, not the primary one.** Always-available signals are the
   **menu item** and the **row in Settings…**; they work on any build. `UNUserNotificationCenter`
   only functions in a **signed, installed `.app`** (a bare `swift run` has no bundle id, and the
   permission request fails there), so every `UpdateNotifier` entry point is gated on
   `LaunchAtLoginController.isAppBundle` and tolerates a refusal. The delegate is set before the app
   finishes launching: `willPresent → [.banner]` (an accessory app is never "frontmost," otherwise
   the banner is suppressed; **no sound** — a version check is low priority), `didReceive` reacts
   only to the button. The banner carries **one** custom action `UNNotificationCategory` —
   **Update** (`.foreground`, opens the release page); the matching **Close** button is added by the
   system. Deliberately one action, not two: macOS collapses *several* custom actions into an
   "Options" dropdown, and a single one shows as a separate button next to the system Close (the
   Reminders pattern). A tap on the body deliberately does nothing (only the Update button opens
   anything). Whether both buttons show versus a dropdown also depends on the system style (Alerts vs
   Banners) — that's the user's choice, not code. Deduplicated per version
   (`lastSeenLatestVersion`) so we don't notify repeatedly about the same version.
   > **`UNUserNotificationCenter` completion handlers run on a non-main queue**, so any
   > `@MainActor`-isolated code inside them crashes with `SIGTRAP` (`dispatch_assert_queue`) —
   > discovered during a manual run of the notarized `.app`. The handler bodies were moved out into
   > `nonisolated` helpers; this is the main argument for the "run the GUI before committing" rule
   > (unit tests don't catch this). Showing the banner on a **locked screen** is a system per-app
   > setting, not controlled by code.

4. **The `lastUpdateCheck` marker advances on EVERY attempt** (success or graceful failure), not
   only on success. This is the **opposite** of `StatusCadence` (which only moves the marker on
   success, because the status page needs to retry quickly): otherwise the private anonymous path
   would hit GitHub every heartbeat after every 404. The 12-hour cadence gate is on the **attempt**,
   not the result.

5. **An unconditional check at startup** (when the option is enabled), plus a 12-hour re-check on
   heartbeat. A freshly installed/restarted build should show an available update right away, not
   half a day later; `UpdateCheckCadence` only governs re-checks during a long session. The check
   rides the usage heartbeat (like `pollStatusIfDue`, #31), with no separate timer.

6. **The `automaticUpdateChecks` option is default-on (opt-out)**, persisted through
   `PersistedConfig` with the `object(forKey:) as? Bool ?? true` idiom (a missing key → `true`;
   `bool(forKey:)` would silently give `false` and break the default).

## Consequences

- **The "New version available" item** (blue `circle.fill`, like the status rows) sits above `Quit`
  behind its own separator; the separator and the item hide in lockstep, so no update leaves a
  "dangling" divider line.
- **`TOKENPACE_GH_AUTH`** joins the family of verification env vars (`TOKENPACE_STUB`). Plus
  `TOKENPACE_FAKE_LATEST=vX.Y.Z` — a verification override (forces "update available"/"up to date"
  with no network), like the stub transports; it takes priority over `TOKENPACE_GH_AUTH`. Both are
  for diagnostics only, never in a normal run.
- The feature **degrades silently**: 404 (private repo), timeout, missing `gh`, network error — all
  map to "no update available," with no crash and no intrusive errors.
- **Test boundary** (ADR-0009): the pure core (`SemanticVersion`, `GitHubReleaseDecoder`,
  `UpdateCheckCadence`, `GitHubReleaseClient` with a stub fetcher) is covered by unit tests; the
  shell (`GHReleaseFetcher`, `UpdateNotifier`, the menu, `PersistedConfig`) is verified by hand.
- **Banner limitation**: on an unsigned/`swift run` build the banner and the permission request are
  no-ops; the full flow is only verified on a notarized `.app` launched from `/Applications`.

## Related

- [ADR-0008](0008-usageclient-pure-backoff-and-transport-seam.md) — the `UsageTransport` seam, reused
  by the HTTP path.
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — pure core / thin shell.
- [ADR-0013](0013-claude-status-line.md) — "riding the heartbeat" and the cadence seam
  (`StatusCadence`), which `UpdateCheckCadence` follows as a model.
- [ADR-0017](0017-delegated-token-refresh.md) — the subprocess seam (`DelegatedRefresher`), which
  `GHReleaseFetcher` follows as a model.
- [ADR-0023](0023-persisted-config-version-marker.md) — `PersistedConfig`, extended with keys for
  #37.
