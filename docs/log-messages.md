# Log message catalog

A complete, verbatim inventory of every log statement TokenPace emits, grouped by
source file. All logging goes through the `AppLogger` facade (`os.Logger` /
unified logging) — see [`Sources/TokenPaceKit/AppLogger.swift`](../Sources/TokenPaceKit/AppLogger.swift).

> **Keep this in sync.** Whenever you add, remove, or change the text of a log
> statement, update the matching row here in the same change. See
> [conventions.md → Логування](conventions.md#логування).

## Facade

- **Subsystem:** `com.artem-n.tokenpace` (shared by the `.app` bundle and `swift run`).
- **Categories:**
  - `network` — Usage/Status API requests, HTTP result codes, decode failures, snapshot synthesis.
  - `keychain` — Keychain reads via the `security` CLI (exit status, ADR-0019), token-expiry checks, delegated token refresh (ADR-0017).
  - `lifecycle` — app launch, launch-at-login, sleep/wake, network up/down, polling-interval changes.
  - `ui` — menu-bar rendering diagnostics (defined, currently unused).
  - `archive` — session-log archiver: sync start/finish, file/byte counts, failures (ADR-0030). File paths only at `.debug` (they contain project names).

## Collecting logs — methods & gotchas

TokenPace logs through `os.Logger`, which is easy to *not* see if you use the wrong command.
The single biggest gotcha: **most of our lines are `.notice`/`.info`, and those are not written to
the persistent store** — only `.error`/`.fault` are. So the method matters.

### 1. Live stream — the reliable default (use `--level debug`)

```sh
log stream --predicate 'subsystem == "com.artem-n.tokenpace"' --level debug
```

`--level debug` is **mandatory**: without it the stream shows only `.error`, so `.notice`/`.info`
lines (the bulk of the catalog below — `update: checking`, `usage 200 ok`, …) silently never appear.
This is the trap that makes the app look "silent" when it is logging fine.

To catch **launch-time** lines (the update check, migration, launch-at-login — all fire once at
startup), start the stream **first**, then relaunch the app while it runs:

```sh
( timeout 20 log stream --predicate 'subsystem == "com.artem-n.tokenpace"' --level debug \
    --style compact > /tmp/tp.log ) &
sleep 3   # let the stream attach
open -n /Applications/TokenPace.app   # relaunch; launch logs land in /tmp/tp.log
```

### 2. `log show` — only for `.error`/`.fault` (persisted history)

```sh
log show --predicate 'subsystem == "com.artem-n.tokenpace" AND messageType == error' --last 1h
```

`log show` reads the **store**, so it can retrieve past `.error`/`.fault` but **will not** show
`.notice`/`.info`/`.debug` no matter what flags you pass (they were never persisted). Do not conclude
"the app didn't log" from an empty `log show` of notice-level events — use the live stream instead.

### 3. Console.app

Filter by subsystem `com.artem-n.tokenpace`, and turn on **Action ▸ Include Info/Debug Messages**
(the GUI equivalent of `--level debug`) — otherwise, same trap as above.

### 4. `swift run` dev build — logs still go to unified logging, not stdout

A `swift run` build logs through the same `os.Logger`, so read it with the **same stream command**
(same subsystem). It does **not** print to the terminal. When a value must be seen directly (e.g. a
signed release whose store is inconvenient), a temporary `FileHandle.standardError.write(…)` in the
code, run from a `.app` bundle, is the escape hatch — but that is a debugging aid, never committed.

> **Signed/notarized release builds.** They log identically — the "invisible logs" people hit on a
> release build is almost always method (1) run without `--level debug`, or method (2) used for
> notice-level events, not a real difference in the build.

## Privacy

`os.Logger` redacts interpolated dynamic values as `<private>` by default in
release builds. Secrets (OAuth `accessToken`/`refreshToken`, Keychain payloads)
are **never** logged. Only safe diagnostics (HTTP status codes, backoff
intervals, token *length*, `OSStatus`, sleep/wake events, utilization) are marked
`.public`. API response bodies are logged `.public` because tokens travel only in
the request `Authorization` header, never in the response.

In the tables below, `<…>` marks an interpolated value.

## `Sources/TokenPace/App.swift`

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 261 | `lifecycle` | `.info` | `TokenPace status item attached (<version>); live polling started` | `applicationDidFinishLaunching` — after the status item is attached and polling starts |
| 313 | `lifecycle` | `.notice` | `manual refresh requested (Troubleshoot)` | `forceRefresh()` — the user clicked "Refresh now" in the Troubleshoot window; a `.manualRefresh` signal is sent and the status poll is marked due (ADR-0020) |
| 358 | `lifecycle` | `.notice` | `optimistic reset applied, forcing refresh` | `fireOptimisticReset()` — a window's reset boundary passed; the retained snapshot is rolled forward locally (zero usage + next `resets_at`) and rendered immediately (no ⏰), then `.manualRefresh` forces the authoritative poll (#36, ADR-0030) |
| 421 | `lifecycle` | `.notice` | `config: first run, no prior version (<version>)` | `runConfigMigrationsIfNeeded()` — no `lastRunVersion` stored (fresh install or a pre-persistence build); records the version, no migrations (#71, ADR-0023) |
| 423 | `lifecycle` | `.notice` | `config: version unchanged (<version>)` | stored `lastRunVersion` equals the running version — nothing to migrate |
| 426 | `lifecycle` | `.notice` | `config: version <old> → <new>, running migrations` | stored version differs from the running one — the `.upgraded` extension point (empty scaffold for now) |
| 445 | `lifecycle` | `.notice` | `launch-at-login: not an .app bundle (swift run), skipping opt-out auto-register` | `registerLaunchAtLoginIfNeeded()` — running as a bare `swift run` binary, so opt-out auto-register is skipped to avoid polluting Login Items (#69) |
| 451 | `lifecycle` | `.notice` | `launch-at-login: status=<status>, no auto-register` | status is `.registered`/`.requiresApproval`, so no auto-register is needed |
| 456 | `lifecycle` | `.notice` | `launch-at-login: auto-registered (opt-out)` | successful auto-registration (`.notRegistered`, or recovery from `.notFound` after an update — #69) |
| 461 | `lifecycle` | `.error` | `launch-at-login: auto-register failed: <error>` | `LaunchAtLoginController.enable()` threw on an installed `.app` bundle — an unexpected, registerable-but-refused case |
| 640 | `network` | `.notice` | `update: checking (userInitiated=<bool>)` | `performUpdateCheck` — an update check begins (launch, daily heartbeat, or "Check now"); #37 |
| 684 | `lifecycle` | `.notice` | `update: TOKENPACE_GH_AUTH found in login shell env` | `resolveGHAuth` — the gh-auth flag was absent from `ProcessInfo` but found in the login shell's rc files via `ShellEnvironment` (#37) |
| 702 | `lifecycle` | `.notice` | `update: new version available tag=<tag> firstSeen=<bool>` | `handleUpdateFound` — a newer release was found; `firstSeen` gates the one-per-version banner (#37) |
| 719 | `lifecycle` | `.notice` | `update: user opened releases page` | `openReleasesPage` — the user clicked the "New version available" menu item (#37) |
| — | `archive` | `.notice` | `archive: sync starting (userInitiated=<bool>)` | `performArchiveSync` — an archive sync begins (daily heartbeat or "Archive now"); #110, ADR-0031 |
| — | `archive` | `.notice` | `archive: sync ok — <n> files, <bytes> bytes` | `performArchiveSync` — the sync finished; the `lastArchiveSync` marker is advanced (#110) |
| — | `archive` | `.error` | `archive: sync failed — <error>` | `performArchiveSync` — the sync threw (e.g. destination unwritable); marker not advanced, retried next heartbeat (#110) |

## `Sources/TokenPace/LogArchiver.swift`

Accumulate-only mirror of Claude Code's session logs (#110, ADR-0031). Per-file copy failures are
logged and skipped without aborting the sync; file paths stay `.private`/`.debug` (project names).

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| — | `archive` | `.debug` | `archive root <root>: <n> source files, <m> to copy` | `sync(to:)` — per allow-listed root (`projects`/`file-history`/`plans`), after the plan is computed |
| — | `archive` | `.error` | `archive copy failed for <path>: <error>` | `sync(to:)` — one file could not be copied (unreadable/locked); logged and skipped, sync continues. `<path>` is `.private` |

## `Sources/TokenPace/ShellEnvironment.swift`

Reads a variable from the login shell's rc files for a login-launched app (#37, ADR-0025).

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 62 | `lifecycle` | `.error` | `shell-env: failed to launch shell: <error>` | `value(for:)` — the login shell (`zsh -l -i`) could not be spawned |

## `Sources/TokenPace/ClaudeCLIRefresher.swift`

Delegated token refresh (ADR-0017): the outcome of every `claude` CLI spawn is logged; the
token itself never is.

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 44 | `keychain` | `.error` | `delegated refresh: claude binary not found` | none of the known install locations holds an executable `claude` |
| 51 | `keychain` | `.notice` | `delegated refresh: launching cli, path=<binary>` | before spawning the CLI; logs the resolved binary path |
| 54 | `keychain` | `.error` | `delegated refresh: cli timed out after <timeout>s` | the CLI outlived the 30 s cap and was terminated |
| 57 | `keychain` | `.error` | `delegated refresh: cli exited status=<code>` | the CLI exited non-zero (or failed to launch → `unknown`) |
| 71 | `keychain` | `.notice` | `delegated refresh: expiresAt advanced` | post-run Keychain re-read shows a newer `expiresAt` — refresh succeeded |
| 74 | `keychain` | `.error` | `delegated refresh: cli exited 0 but keychain unchanged` | the CLI finished cleanly but the stored credentials did not change |

## `Sources/TokenPace/SettingsWindowController.swift`

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 158 | `lifecycle` | `.notice` | `launch-at-login: user set <true/false>` | user toggled the launch-at-login checkbox successfully |
| 164 | `lifecycle` | `.error` | `launch-at-login: toggle failed: <error>` | toggle threw (e.g. unsigned build) — a deliberate user action, so it stays `.error` |
| 424 | `lifecycle` | `.notice` | `calm-colors: menu-bar set <bool>` | user toggled the "Calm MenuBar Widget colors" checkbox (#105) |
| 434 | `lifecycle` | `.notice` | `reset-countdown: menu-bar mode set <mode>` | user picked a "Reset countdown" radio (#103); `<mode>` is the raw `ResetCountdownMode` |
| 442 | `lifecycle` | `.notice` | `service-status-dot: menu-bar set <bool>` | user toggled the "Show service status dot on issues" checkbox (#31) |
| 439 | `lifecycle` | `.notice` | `update: automatic checks set <bool>` | user toggled the "Check for updates daily" checkbox (#37) |
| — | `lifecycle` | `.notice` | `archive: enabled set <bool>` | user toggled the "Archive session logs to a folder" checkbox (#110) |
| — | `lifecycle` | `.notice` | `archive: destination chosen` | user picked an archive folder via `NSOpenPanel` (#110); the path itself is not logged |

## `Sources/TokenPace/GHReleaseFetcher.swift`

The `gh api` subprocess for the maintainer update-check path (#37, ADR-0025); the token never appears
(gh resolves it from keyring internally).

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 46 | `network` | `.notice` | `update: gh path, launching <binary>` | before spawning `gh api …/releases/latest` under `TOKENPACE_GH_AUTH` |

## `Sources/TokenPace/UpdateNotifier.swift`

The first `UserNotifications` use (#37, ADR-0025). Completion handlers run off the main actor, so
their bodies live in `nonisolated` helpers.

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 54 | `lifecycle` | `.error` | `update: notification auth failed: <error>` | `requestAuthorization` returned an error |
| 57 | `lifecycle` | `.notice` | `update: notification auth granted=<bool>` | authorization resolved (granted or denied) |
| 68 | `lifecycle` | `.notice` | `update: skip notification (not an .app bundle)` | `post` called outside a real `.app` — banner unavailable, menu/Settings still carry the signal |
| 87 | `lifecycle` | `.error` | `update: notification post failed: <error>` | `UNUserNotificationCenter.add` returned an error |
| 128 | `lifecycle` | `.notice` | `update: notification action opened releases page` | the user clicked the banner body or its "Update" button (`didReceive`); "Close" does nothing |

## `Sources/TokenPace/PollingShell.swift`

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 46 | `lifecycle` | `.notice` | `system will sleep, pausing polling` | `NSWorkspace.willSleepNotification` fired |
| 52 | `lifecycle` | `.notice` | `system did wake, polling immediately` | `NSWorkspace.didWakeNotification` fired |
| 85 | `lifecycle` | `.notice` | `network monitor started (satisfied=<bool>)` | first `NWPathMonitor` callback (initial reading) |
| 87 | `lifecycle` | `.notice` | `network restored, polling immediately` | transition to `.satisfied` |
| 90 | `lifecycle` | `.notice` | `network lost, showing stale data` | transition to `.unsatisfied` |

## `Sources/TokenPaceKit/UsageClient.swift`

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 98 | `network` | `.error` | `usage decode failed body=<body>` | `decode(from:now:)` — JSON `DecodingError`; body capped to 500 chars |
| 155 | `network` | `.error` | `usage request transport error: <error>` | `diagnosedFetch` — `transport.data(for:)` threw (network error) |
| 166 | `network` | `.error` | `usage response not HTTP` | response was not `HTTPURLResponse` |
| 187 | `network` | `.notice` | `usage 200 ok body=<bodyText>` | HTTP 200; logs the full JSON body |
| 199 | `network` | `.error` | `usage rate-limited: HTTP 429 retryAfter=<n>` | HTTP 429 |
| 207 | `network` | `.error` | `usage request failed: HTTP <statusCode>` | other non-200/non-429 status |

## `Sources/TokenPaceKit/StatusClient.swift`

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 52 | `network` | `.error` | `status decode failed` | `decode(from:)` — JSON `DecodingError` |
| 72 | `network` | `.error` | `status request transport error: <error>` | `transport.data(for:)` threw |
| 78 | `network` | `.error` | `status response not HTTP` | response was not `HTTPURLResponse` |
| 85 | `network` | `.notice` | `status 200 ok components=<count>` | HTTP 200; logs component count |
| 91 | `network` | `.error` | `status request failed: HTTP <statusCode>` | non-200 status |

## `Sources/TokenPaceKit/GitHubRelease.swift`

Update-check release decode (#37, ADR-0025).

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 55 | `network` | `.error` | `update: release decode failed` | `GitHubReleaseDecoder.decode(from:)` — JSON `DecodingError` |

## `Sources/TokenPaceKit/GitHubReleaseClient.swift`

Update-check orchestration (#37, ADR-0025); every branch of a fetch outcome logs once. `.notFound`
(private repo / no release) and "not newer" are expected no-ops → `.notice`; genuine faults → `.error`.

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 106 | `network` | `.notice` | `update: releases/latest 404 (repo private or no release)` | anonymous fetch 404'd — expected while the repo is private |
| 108 | `network` | `.error` | `update: fetch transport error: <message>` | a network/connectivity failure |
| 110 | `network` | `.notice` | `update: fetch unavailable: <message>` | the `gh` path was unavailable (binary missing / non-zero exit) |
| 112 | `network` | `.error` | `update: fetch decode error` | a non-404 HTTP error or an undecodable body |
| 116 | `network` | `.error` | `update: fetch unexpected error: <error>` | a non-`UpdateFetchError` thrown by the fetcher |
| 123 | `network` | `.notice` | `update: latest=<tag> not newer than <current>` | a release was found but it is not newer than the running version |

## `Sources/TokenPaceKit/TokenProvider.swift`

The Keychain read spawns `/usr/bin/security find-generic-password -w` (ADR-0019); the secret
itself is never logged — only exit status and byte count.

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 284 | `keychain` | `.error` | `security cli launch failed` | `readRawData()` — `Process.run()` threw; the `security` tool could not be spawned |
| 289 | `keychain` | `.error` | `security cli read timed out after <timeout>s` | the `security` tool outlived the 10 s cap and was terminated |
| 296 | `keychain` | `.debug` | `security cli read exit=<status> bytes=<count>` | `readRawData()` — after every Keychain read; logs the tool's exit status and payload size |

> The `token expired, len=<count>` line moved to `PollingEngine.pollOnce` with the expiry decision
> (ADR-0020) — see the `PollingEngine.swift` table below. Text, category, and level are unchanged.

## `Sources/TokenPaceKit/UsageSnapshot.swift`

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 268 | `network` | `.notice` | `filled <key> sub-window resets_at from seven_day (was null)` | a per-model sub-window's `resets_at` was null; borrowed from the parent 7-day window |
| 314 | `network` | `.notice` | `synthesized <key> window on reset boundary (utilization=0, resets_at source=limits[])` | a core window's `resets_at` was null but a matching `limits[]` entry supplied one — a reset-boundary blip |
| 327 | `network` | `.notice` | `synthesized <key> window on reset boundary (utilization=0, resets_at source=local-estimate)` | **`seven_day` only** — the weekly window's `resets_at` was null and no `limits[]` entry supplied one; a local `now+7d` estimate is used (`five_hour` in this case is idle, see the `PollingEngine` table — no synthesis, no log) |

## `Sources/TokenPaceKit/PollingEngine.swift`

One log line per interval change. The format is built by
`IntervalDecision.logMessage` (line 170): `interval <from>→<to>: <phrase>`.

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 435 | `lifecycle` | `.notice` | `interval <from>→<to>: <phrase>` | the polling interval moved; emitted once per change |
| 441 | `network` | `.notice` | `five_hour idle — no active session (resets_at absent)` | the 5h window flipped to session-idle (`sessionIdleTransition`); emitted **once per transition**, not every poll (#100, ADR-0027) |
| 441 | `network` | `.notice` | `five_hour window active again` | the 5h window came back (idle → active); same call site, once per transition (#100, ADR-0027) |
| 511 | `keychain` | `.notice` | `token expired, len=<count>` | `pollOnce` — the read credentials are expired (`isExpired` true); moved here from `TokenProvider` with the expiry decision (ADR-0020) |

`<from>`/`<to>` render as whole minutes (`3m`) or fall back to seconds (`90s`).
`<phrase>` is one of six, keyed by `IntervalDecision.Cause` (lines 180–189):

| `Cause` | Full example message | When |
|---------|----------------------|------|
| `.claudeInactive` | `interval 3m→6m: no Claude Code session — idle override` | no running Claude Code session → idle override |
| `.claudeActiveResumed` | `interval 6m→3m: Claude Code session active — resuming adaptive cadence` | a Claude Code session reappeared → adaptive cadence |
| `.contentChanged` | `interval 6m→3m: usage changed — tracking closely` | snapshot moved → adaptive snapped to the 3-min floor |
| `.contentUnchanged` | `interval 3m→6m: usage unchanged — backing off` | two adjacent snapshots matched → adaptive doubled the interval |
| `.rateLimited` | `interval 3m→8m: rate-limited (HTTP 429) — server backoff` | HTTP 429 → server backoff overrides adaptive/idle |
| `.rateLimitCleared` | `interval 8m→3m: rate-limit cleared — resuming adaptive cadence` | a 200 cleared an active 429 backoff |

## Counts

| Category | Calls | Files |
|----------|-------|-------|
| `network` | 24 | `UsageClient` (6), `StatusClient` (5), `UsageSnapshot` (3), `PollingEngine` (1), `GitHubReleaseClient` (6), `App` (1), `GHReleaseFetcher` (1), `GitHubRelease` (1) |
| `lifecycle` | 32 | `App` (13), `SettingsWindowController` (7), `PollingShell` (5), `PollingEngine` (1), `UpdateNotifier` (5), `ShellEnvironment` (1) |
| `keychain` | 10 | `TokenProvider` (3), `ClaudeCLIRefresher` (6), `PollingEngine` (1) |
| `ui` | 0 | — (category defined, unused) |
| `archive` | 5 | `App` (3), `LogArchiver` (2) |

**Total: 69 log statements** — `.error` ×26, `.notice` ×40, `.info` ×1, `.debug` ×2.

The `five_hour idle …` / `window active again` pair is one call site (`sessionIdleTransition`) that
emits one of two strings; it is counted once under `PollingEngine` network.
