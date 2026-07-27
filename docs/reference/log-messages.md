# Log message catalog

A complete, verbatim inventory of every log statement TokenPace emits, grouped by
source file. All logging goes through the `AppLogger` facade (`os.Logger` /
unified logging) — see [`Sources/TokenPaceKit/AppLogger.swift`](../../Sources/TokenPaceKit/AppLogger.swift).

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
| 640 | `network` | `.notice` | `update: checking (userInitiated=<bool>)` | `performUpdateCheck` — an update check begins (launch, 12 h heartbeat, or "Check now"); #37 |
| 684 | `lifecycle` | `.notice` | `update: TOKENPACE_GH_AUTH found in login shell env` | `resolveGHAuth` — the gh-auth flag was absent from `ProcessInfo` but found in the login shell's rc files via `ShellEnvironment` (#37) |
| — | `lifecycle` | `.notice` | `update: new version available tag=<tag> firstSeen=<bool>` | `handleUpdateFound` — a newer release was found; `firstSeen` = first time this tag is surfaced (`lastSeenLatestVersion`), #37 |
| — | `lifecycle` | `.notice` | `update: cleared pending what's new (superseded by newer release)` | `handleUpdateFound` — a release newer than the installed build pre-empts an unseen "what's new" (#130, ADR-0036) |
| — | `lifecycle` | `.notice` | `update: menu item = <hidden\|updateFailed\|updateAvailable\|updatePending\|whatsNew>` | `refreshUpdateMenuItem` — the single update dropdown item's resolved state (#130, ADR-0036) |
| — | `lifecycle` | `.notice` | `update: user opened releases page (item=<state>)` | `openReleasesPage` — the user clicked the update item; opens the releases page (#37/#130) |
| — | `lifecycle` | `.notice` | `update: cleared pending what's new (user opened it)` | `openReleasesPage` — opening the `whatsNew` item acknowledges it, clearing `pendingWhatsNewVersion` (#130) |
| — | `lifecycle` | `.notice` | `update-install: decision=install target=<tag> asset=<name>` | `evaluateAutoInstall` — all gates passed; this release would be auto-installed (#122, ADR-0033). Phase 2 runs the installer only under `TOKENPACE_UPDATE_DRYRUN` (download/verify/unzip, no replace) |
| — | `lifecycle` | `.notice` | `update-install: decision=skip reason=<auto-install-off\|not-newer\|not-app-bundle\|no-asset>` | `evaluateAutoInstall` — why auto-install stood down (opt-out off / not newer / dev build / no version-named `.zip` asset); the single dropdown item still carries the signal (#122/#130) |
| — | `lifecycle` | `.notice` | `update-install: decision=defer reason=insufficient-space target=<tag>` | `evaluateAutoInstall` — installable, but downloading would leave < 5 GB free; deferred until space frees up. Not bypassed by a forced install. Re-evaluated next heartbeat (#124) |
| — | `lifecycle` | `.notice` | `update-install: decision=defer reason=on-battery target=<tag>` | `evaluateAutoInstall` — installable, but on battery; deferred until AC power. Re-evaluated next heartbeat. Bypassed by a forced (dry-run) install (#123) |
| — | `lifecycle` | `.notice` | `update-install: decision=defer reason=metered-network target=<tag>` | `evaluateAutoInstall` — installable, but on a metered (expensive/constrained) network; deferred until unmetered. The update *check* is unaffected. Re-evaluated next heartbeat (#123) |
| — | `lifecycle` | `.notice` | `update-install: auto set <bool>` | user toggled the "Install updates automatically" checkbox (#122; default-on since #130) |
| — | `lifecycle` | `.notice` | `update-install: skip (not an .app bundle)` | `UpdateInstaller.install` — gated out on a dev build before any I/O (#123) |
| — | `network` | `.notice` | `update-install: download started tag=<tag> asset=<name> via=<gh\|https>` | `UpdateInstaller` — the asset download began; `gh` path for the private repo (asset needs credentials), else anonymous HTTPS (#123) |
| — | `network` | `.notice` | `update-install: download ok bytes=<n>` | `UpdateInstaller` — the asset downloaded successfully (#123) |
| — | `network` | `.error` | `update-install: download failed <error>` | `UpdateInstaller` — network / HTTP-status / write failure; falls back to manual Download (#123) |
| — | `lifecycle` | `.notice` | `update-install: unzip ok path=<tmp>` | `UpdateInstaller` — `ditto -x -k` extracted the `.app` to a temp dir (#123) |
| — | `lifecycle` | `.error` | `update-install: unzip failed <reason>` | `UpdateInstaller` — extraction failed or the archive held no `.app` (#123) |
| — | `lifecycle` | `.notice` | `update-install: verify ok teamID=S5A4U9798Y gatekeeper=accepted` | `UpdateInstaller` — `codesign` + Team-ID + Gatekeeper (`spctl`) all passed (#123) |
| — | `lifecycle` | `.error` | `update-install: verify FAILED reason=<reason>` | `UpdateInstaller` — signature / Team-ID / notarization check failed; the bundle is discarded, nothing replaced (#123) |
| — | `lifecycle` | `.notice` | `update-install: dry-run — would replace <target> with <tag> (verified OK) [TOKENPACE_UPDATE_DRYRUN]` | `UpdateInstaller` — dry run stops here: verified but not installed (#123) |
| — | `lifecycle` | `.notice` | `update-install: dry-run complete, verified bundle at <path>` | `AppDelegate` — the dry-run finished; the verified bundle is kept at `<path>` for inspection (#123) |
| — | `lifecycle` | `.notice` | `update-install: replace ok target=<path>` | `UpdateInstaller` — the target `.app` was atomically replaced with the verified build (#124) |
| — | `lifecycle` | `.error` | `update-install: replace FAILED reason=<reason>` | `UpdateInstaller` — the atomic replace failed (permissions / I/O); old bundle intact, manual Download remains (#124) |
| — | `lifecycle` | `.notice` | `update-install: installed <tag>, relaunching` | `UpdateInstaller` — replace done; about to relaunch the new build (#124) |
| — | `lifecycle` | `.notice` | `update-install: relaunching from <path>` | `UpdateInstaller.relaunch` — launching the new bundle; this process then terminates (#124) |
| — | `lifecycle` | `.error` | `update-install: relaunch failed <error>` | `UpdateInstaller.relaunch` — couldn't launch the new bundle; this process stays alive, the new version is picked up on next manual launch (#124) |
| — | `lifecycle` | `.notice` | `update-install: what's new pending set tag=<tag>` | `startInstall` — the pending "what's new" is persisted **before** the install runs, so it survives the imminent relaunch (#130, ADR-0036) |
| — | `lifecycle` | `.notice` | `update-install: installed <tag>, app will relaunch` | `AppDelegate` — the real install succeeded; the installer is relaunching (#124) |
| — | `lifecycle` | `.notice` | `update-install: last failed install version set tag=<tag>` | `startInstall` — an install failed; this tag is recorded so it is not retried (a newer tag still is), driving the red `updateFailed` item (#130, ADR-0036) |
| — | `lifecycle` | `.error` | `update-install: did not complete (<outcome>) — signal item remains` | `AppDelegate` — the install ended in a failure outcome; the speculative "what's new" is cleared and the single dropdown item carries the signal (#123/#124/#130) |
| — | `archive` | `.notice` | `archive: sync starting (userInitiated=<bool>)` | `performArchiveSync` — an archive sync begins (daily heartbeat or "Archive now"); #110, ADR-0031 |
| — | `archive` | `.notice` | `archive: sync ok — <n> updated, <bytes> bytes, <total> files / <totalBytes> bytes in archive` | `performArchiveSync` — the sync finished; the `lastArchiveSync` marker is advanced (#110). `<total>`/`<totalBytes>` count the whole archive incl. source-pruned files |
| — | `archive` | `.error` | `archive: sync failed — <error>` | `performArchiveSync` — the sync threw (e.g. destination unwritable); marker not advanced, retried next heartbeat (#110) |
| — | `lifecycle` | `.info` | `back-to-work: suppressed by quiet hours` | `maybePostBackToWork` — a blocked→unblocked edge fired but the current time is outside the allowed-hours window or on a suppressed weekday, so nothing is posted (#160, ADR-0039) |

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
| — | `lifecycle` | `.notice` | `extra-usage-icon: menu-bar set <bool>` | user toggled the "Show extra-usage credits icon" checkbox (#146) |
| — | `lifecycle` | `.notice` | `hide-calm-7d: menu-bar set <bool>` | user toggled the "Hide 7-day bar when calm" checkbox (#94, ADR-0034) |
| — | `lifecycle` | `.notice` | `screen-lock-pause: setting set <bool>` | user toggled the "Pause polling while the screen is locked" checkbox (#114, ADR-0032) |
| 439 | `lifecycle` | `.notice` | `update: automatic checks set <bool>` | user toggled the "Check for updates automatically" checkbox (#37) |
| — | `lifecycle` | `.notice` | `archive: enabled set <bool>` | user toggled the "Archive session logs to a folder" checkbox (#110) |
| — | `lifecycle` | `.notice` | `archive: destination chosen` | user picked an archive folder via `NSOpenPanel` (#110); the path itself is not logged |
| — | `lifecycle` | `.notice` | `back-to-work: enabled set <bool>` | user toggled the "Back to work" notification switch (#160, ADR-0039) |
| — | `lifecycle` | `.notice` | `back-to-work: time window set <start>–<end>` | user changed the allowed-hours pickers; `<start>`/`<end>` are minute-of-day (#160) |
| — | `lifecycle` | `.notice` | `back-to-work: suppress set <raw>` | user picked a "Suppress notifications on" radio; `<raw>` is the raw `SuppressDays` (#160) |

## `Sources/TokenPace/BackToWorkNotifier.swift`

Thin `UserNotifications` glue for the "Back to work!" notification (#160, ADR-0039). No token/limit
values are ever logged.

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| — | `lifecycle` | `.info` | `back-to-work: authorization dev (no bundle)` | `requestAuthorizationIfNeeded` — running as a bare `swift run` binary; authorization is impossible, so it is skipped |
| — | `lifecycle` | `.info` | `back-to-work: authorization <granted/denied>` | `requestAuthorizationIfNeeded` — the system authorization prompt resolved |
| — | `lifecycle` | `.error` | `back-to-work: authorization error <error>` | `requestAuthorizationIfNeeded` — `requestAuthorization` returned an error |
| — | `lifecycle` | `.info` | `back-to-work: edge detected, posting notification` | `postBackToWork` — the request was added to `UNUserNotificationCenter` (the banner is delivered) |
| — | `lifecycle` | `.info` | `back-to-work: not authorized, skipping` | `postBackToWork` — the feature is on but notification authorization is not granted, so nothing is posted |
| — | `lifecycle` | `.error` | `back-to-work: post failed <error>` | `postBackToWork` — `UNUserNotificationCenter.add` returned an error |

## `Sources/TokenPace/GHReleaseFetcher.swift`

The `gh api` subprocess for the maintainer update-check path (#37, ADR-0025); the token never appears
(gh resolves it from keyring internally).

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 46 | `network` | `.notice` | `update: gh path, launching <binary>` | before spawning `gh api …/releases/latest` under `TOKENPACE_GH_AUTH` |

<!-- `Sources/TokenPace/UpdateNotifier.swift` removed in #130 (ADR-0036): no more system notifications;
the sole update signal is the single dropdown item logged as `update: menu item = …` above. -->

## `Sources/TokenPace/PollingShell.swift`

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 46 | `lifecycle` | `.notice` | `system will sleep, pausing polling` | `NSWorkspace.willSleepNotification` fired |
| 52 | `lifecycle` | `.notice` | `system did wake, polling immediately` | `NSWorkspace.didWakeNotification` fired (the loop still re-polls only if the cache is stale — ADR-0032 D6) |
| 133 | `lifecycle` | `.notice` | `screen-lock-pause: <reason>, pausing polling` | `ScreenLockObserver` — screen locked / screensaver started / display asleep, with `pausePollingWhenScreenLocked` on (#114). `<reason>` ∈ {`screen locked`, `screensaver started`, `display asleep`} |
| 140 | `lifecycle` | `.notice` | `screen-lock-pause: <reason>, polling immediately` | `ScreenLockObserver` — screen unlocked / screensaver stopped / display awake (resume; the loop re-polls only if the cache is stale). `<reason>` ∈ {`screen unlocked`, `screensaver stopped`, `display awake`} |
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
| 514 | `lifecycle` | `.notice` | `interval <from>→<to>: <phrase>` | the polling interval moved; emitted once per change |
| 520 | `network` | `.notice` | `five_hour idle — no active session (resets_at absent)` | the 5h window flipped to session-idle (`sessionIdleTransition`); emitted **once per transition**, not every poll (#100, ADR-0027) |
| 520 | `network` | `.notice` | `five_hour window active again` | the 5h window came back (idle → active); same call site, once per transition (#100, ADR-0027) |
| 526 | `network` | `.notice` | `five_hour idle suppressed — within reset grace` | the reset-boundary idle grace armed (`applyIdleGrace`, `idleSuppressedUntil` nil → non-nil); emitted **once per transition**, not every poll (ADR-0041) |
| 614 | `keychain` | `.notice` | `token expired, len=<count>` | `pollOnce` — the read credentials are expired (`isExpired` true); moved here from `TokenProvider` with the expiry decision (ADR-0020) |

`<from>`/`<to>` render as whole minutes (`3m`) or fall back to seconds (`90s`).
`<phrase>` is one of four, keyed by `IntervalDecision.Cause` (ADR-0032):

| `Cause` | Full example message | When |
|---------|----------------------|------|
| `.claudeInactive` | `interval 3m→15m: no Claude Code session — idle override` | no running Claude Code session → 15-min idle override |
| `.claudeActiveResumed` | `interval 15m→3m: Claude Code session active — resuming base cadence` | a Claude Code session reappeared → 3-min base |
| `.rateLimited` | `interval 3m→10m: rate-limited (HTTP 429) — honoring Retry-After` | HTTP 429 → hold at the server's Retry-After (overrides idle/base) |
| `.rateLimitCleared` | `interval 10m→3m: rate-limit cleared — resuming base cadence` | a 200 cleared an active 429 hold |

## Counts

| Category | Calls | Files |
|----------|-------|-------|
| `network` | 28 | `UsageClient` (6), `GitHubReleaseClient` (6), `StatusClient` (5), `UsageSnapshot` (3), `UpdateInstaller` (3), `PollingEngine` (2), `GitHubRelease` (1), `GHReleaseFetcher` (1), `App` (1) |
| `lifecycle` | 62 | `App` (29), `UpdateInstaller` (13), `SettingsWindowController` (10), `PollingShell` (7), `PollingEngine` (2), `ShellEnvironment` (1) |
| `keychain` | 11 | `ClaudeCLIRefresher` (6), `TokenProvider` (4), `PollingEngine` (1) |
| `ui` | 0 | — (category defined, unused) |
| `archive` | 5 | `App` (3), `LogArchiver` (2) |

**Total: 106 log statements** — `.error` ×33, `.notice` ×69, `.info` ×1, `.debug` ×3.

The `five_hour idle …` / `window active again` pair is one call site (`sessionIdleTransition`) that
emits one of two strings; it is counted once under `PollingEngine` network. The
`five_hour idle suppressed …` grace line (`applyIdleGrace`, ADR-0041) is a separate call site,
counted as the second `PollingEngine` network statement.
