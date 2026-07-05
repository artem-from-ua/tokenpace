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
  - `keychain` — Keychain reads (`OSStatus`), token-expiry checks.
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
| 130 | `lifecycle` | `.info` | `TokenPace status item attached (<version>); live polling started` | `applicationDidFinishLaunching` — after the status item is attached and polling starts |
| 154 | `lifecycle` | `.notice` | `launch-at-login: status=<status>, no auto-register` | `registerLaunchAtLoginIfNeeded()` — status check shows no auto-register is needed |
| 160 | `lifecycle` | `.notice` | `launch-at-login: auto-registered on first launch (opt-out)` | successful auto-registration on first launch |
| 162 | `lifecycle` | `.error` | `launch-at-login: auto-register failed: <error>` | `LaunchAtLoginController.enable()` threw |

## `Sources/TokenPace/SettingsWindowController.swift`

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 148 | `lifecycle` | `.notice` | `launch-at-login: user set <true/false>` | user toggled the launch-at-login checkbox successfully |
| 151 | `lifecycle` | `.error` | `launch-at-login: toggle failed: <error>` | toggle threw (e.g. unsigned build) |

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
| 126 | `network` | `.error` | `usage request transport error: <error>` | `transport.data(for:)` threw (network error) |
| 132 | `network` | `.error` | `usage response not HTTP` | response was not `HTTPURLResponse` |
| 146 | `network` | `.notice` | `usage 200 ok body=<bodyText>` | HTTP 200; logs the full JSON body |
| 150 | `network` | `.error` | `usage rate-limited: HTTP 429 retryAfter=<n>` | HTTP 429 |
| 155 | `network` | `.error` | `usage request failed: HTTP <statusCode>` | other non-200/non-429 status |

## `Sources/TokenPaceKit/StatusClient.swift`

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 52 | `network` | `.error` | `status decode failed` | `decode(from:)` — JSON `DecodingError` |
| 72 | `network` | `.error` | `status request transport error: <error>` | `transport.data(for:)` threw |
| 78 | `network` | `.error` | `status response not HTTP` | response was not `HTTPURLResponse` |
| 85 | `network` | `.notice` | `status 200 ok components=<count>` | HTTP 200; logs component count |
| 91 | `network` | `.error` | `status request failed: HTTP <statusCode>` | non-200 status |

## `Sources/TokenPaceKit/TokenProvider.swift`

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 158 | `keychain` | `.notice` | `token expired, len=<count>` | `accessTokenIfValid(_:now:)` — `.isValid()` returned false |
| 228 | `keychain` | `.debug` | `SecItemCopyMatching status=<status>` | `readRawData()` — after every Keychain read; logs `OSStatus` |

## `Sources/TokenPaceKit/UsageSnapshot.swift`

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 216 | `network` | `.notice` | `filled <key> sub-window resets_at from seven_day (was null)` | a per-model sub-window's `resets_at` was null; borrowed from the parent 7-day window |
| 257 | `network` | `.notice` | `synthesized <key> window on reset boundary (utilization=0, resets_at source=<source>)` | synthesized a zero-usage window on an API reset boundary; `source` is `limits[]` or `local-estimate` |

## `Sources/TokenPaceKit/PollingEngine.swift`

One log line per interval change. The format is built by
`IntervalDecision.logMessage` (line 164): `interval <from>→<to>: <phrase>`.

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 368 | `lifecycle` | `.notice` | `interval <from>→<to>: <phrase>` | the polling interval moved; emitted once per change |

`<from>`/`<to>` render as whole minutes (`3m`) or fall back to seconds (`90s`).
`<phrase>` is one of six, keyed by `IntervalDecision.Cause` (lines 174–183):

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
| `lifecycle` | 12 | `App` (4), `SettingsWindowController` (2), `PollingShell` (5), `PollingEngine` (1) |
| `keychain` | 2 | `TokenProvider` (2) |
| `ui` | 0 | — (category defined, unused) |

**Total: 23 log statements** — `.error` ×11, `.notice` ×11, `.info` ×1, `.debug` ×1.
