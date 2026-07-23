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

Watch them live:

```sh
log stream --predicate 'subsystem == "com.artem-n.tokenpace"' --level debug
```

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
| 192 | `lifecycle` | `.info` | `TokenPace status item attached (<version>); live polling started` | `applicationDidFinishLaunching` — after the status item is attached and polling starts |
| 223 | `lifecycle` | `.notice` | `manual refresh requested (Troubleshoot)` | `forceRefresh()` — the user clicked "Refresh now" in the Troubleshoot window; a `.manualRefresh` signal is sent and the status poll is marked due (ADR-0020) |
| 264 | `lifecycle` | `.notice` | `config: first run, no prior version (<version>)` | `runConfigMigrationsIfNeeded()` — no `lastRunVersion` stored (fresh install or a pre-persistence build); records the version, no migrations (#71, ADR-0023) |
| 267 | `lifecycle` | `.notice` | `config: version unchanged (<version>)` | stored `lastRunVersion` equals the running version — nothing to migrate |
| 269 | `lifecycle` | `.notice` | `config: version <old> → <new>, running migrations` | stored version differs from the running one — the `.upgraded` extension point (empty scaffold for now) |
| 288 | `lifecycle` | `.notice` | `launch-at-login: not an .app bundle (swift run), skipping opt-out auto-register` | `registerLaunchAtLoginIfNeeded()` — running as a bare `swift run` binary, so opt-out auto-register is skipped to avoid polluting Login Items (#69) |
| 294 | `lifecycle` | `.notice` | `launch-at-login: status=<status>, no auto-register` | status is `.registered`/`.requiresApproval`, so no auto-register is needed |
| 300 | `lifecycle` | `.notice` | `launch-at-login: auto-registered (opt-out)` | successful auto-registration (`.notRegistered`, or recovery from `.notFound` after an update — #69) |
| 304 | `lifecycle` | `.error` | `launch-at-login: auto-register failed: <error>` | `LaunchAtLoginController.enable()` threw on an installed `.app` bundle — an unexpected, registerable-but-refused case |

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
| 240 | `network` | `.notice` | `filled <key> sub-window resets_at from seven_day (was null)` | a per-model sub-window's `resets_at` was null; borrowed from the parent 7-day window |
| 281 | `network` | `.notice` | `synthesized <key> window on reset boundary (utilization=0, resets_at source=<source>)` | synthesized a zero-usage window on an API reset boundary; `source` is `limits[]` or `local-estimate` |

## `Sources/TokenPaceKit/PollingEngine.swift`

One log line per interval change. The format is built by
`IntervalDecision.logMessage` (line 170): `interval <from>→<to>: <phrase>`.

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 406 | `lifecycle` | `.notice` | `interval <from>→<to>: <phrase>` | the polling interval moved; emitted once per change |
| 470 | `keychain` | `.notice` | `token expired, len=<count>` | `pollOnce` — the read credentials are expired (`isExpired` true); moved here from `TokenProvider` with the expiry decision (ADR-0020) |

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
| `network` | 13 | `UsageClient` (6), `StatusClient` (5), `UsageSnapshot` (2) |
| `lifecycle` | 17 | `App` (9), `SettingsWindowController` (2), `PollingShell` (5), `PollingEngine` (1) |
| `keychain` | 10 | `TokenProvider` (3), `ClaudeCLIRefresher` (6), `PollingEngine` (1) |
| `ui` | 0 | — (category defined, unused) |

**Total: 40 log statements** — `.error` ×17, `.notice` ×21, `.info` ×1, `.debug` ×1.
