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
  - `journal` — usage journal (#242, ADR-0067) and the dev status-payload JSONL (#279, ADR-0071 §10): append-write failures, fixture generation. Percentages only, never a token.

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
| — | `lifecycle` | `.notice` | `dev: stub scenario → <id>` | `switchScenario(_:)` — the dev-tools live stub selector picked a new data source (`<id>` = the `TOKENPACE_STUB` value, `real` for the live network); the polling engine is rebuilt and an immediate poll forced (#187). Dev-only (`devToolsEnabled` defaults key, ADR-0053) |
| — | `lifecycle` | `.notice` | `dev: unknown TOKENPACE_STUB "<value>" — running the frozen screenshot stub instead of the real network. Available: <ids>` | `applicationDidFinishLaunching` — `TOKENPACE_STUB` was set to something the registry doesn't know, so the run fell back to the frozen `screenshot` frame rather than the live network (#267). `<ids>` is built from `StubScenario.allCases`, so it can't drift. Silent when the variable is absent or valid |
| 358 | `lifecycle` | `.notice` | `optimistic reset applied, forcing refresh` | `fireOptimisticReset()` — a window's reset boundary passed; the retained snapshot is rolled forward locally (zero usage + next `resets_at`) and rendered immediately (no ⏰), then `.manualRefresh` forces the authoritative poll (#36, ADR-0030) |
| 421 | `lifecycle` | `.notice` | `config: first run, no prior version (<version>)` | `runConfigMigrationsIfNeeded()` — no `lastRunVersion` stored (fresh install or a pre-persistence build); records the version, no migrations (#71, ADR-0023) |
| 423 | `lifecycle` | `.notice` | `config: version unchanged (<version>)` | stored `lastRunVersion` equals the running version — nothing to migrate |
| 426 | `lifecycle` | `.notice` | `config: version <old> → <new>, running migrations` | stored version differs from the running one — the `.upgraded` extension point (empty scaffold for now) |
| 445 | `lifecycle` | `.notice` | `launch-at-login: not an .app bundle (swift run), skipping opt-out auto-register` | `registerLaunchAtLoginIfNeeded()` — running as a bare `swift run` binary, so opt-out auto-register is skipped to avoid polluting Login Items (#69) |
| 451 | `lifecycle` | `.notice` | `launch-at-login: status=<status>, no auto-register` | status is `.registered`/`.requiresApproval`, so no auto-register is needed |
| 456 | `lifecycle` | `.notice` | `launch-at-login: auto-registered (opt-out)` | successful auto-registration (`.notRegistered`, or recovery from `.notFound` after an update — #69) |
| 461 | `lifecycle` | `.error` | `launch-at-login: auto-register failed: <error>` | `LaunchAtLoginController.enable()` threw on an installed `.app` bundle — an unexpected, registerable-but-refused case |
| 640 | `network` | `.notice` | `update: checking (userInitiated=<bool>)` | `performUpdateCheck` — an update check begins (launch, 12 h heartbeat, or "Check now"); #37 |
| — | `lifecycle` | `.notice` | `update: TOKENPACE_GH_AUTH found in login shell env` | `resolveGHAuth` — the flag was absent from `ProcessInfo` but found in the login shell's rc files via `ShellEnvironment` (`zsh -l -i`), so the `gh` update path is enabled for a login-launched app (#37, ADR-0025) |
| — | `lifecycle` | `.notice` | `update: new version available tag=<tag> firstSeen=<bool>` | `handleUpdateFound` — a newer release was found; `firstSeen` = first time this tag is surfaced (`lastSeenLatestVersion`), #37 |
| — | `lifecycle` | `.notice` | `update: cleared pending what's new (superseded by newer release)` | `handleUpdateFound` — a release newer than the installed build pre-empts an unseen "what's new" (#130, ADR-0036) |
| — | `lifecycle` | `.notice` | `update: cleared stale install-failure record (superseded by newer release)` | `handleUpdateFound` — a newer release makes a stored `lastUpdateFailure` stale; the About-pane failure row is cleared (#210) |
| — | `lifecycle` | `.notice` | `update: menu item = <hidden\|updateFailed\|updateAvailable\|updatePending\|whatsNew>` | `refreshUpdateMenuItem` — the single update dropdown item's resolved state (#130, ADR-0036) |
| — | `lifecycle` | `.notice` | `update: user opened About from update item (item=<state>)` | `openReleasesPage` — the user clicked the update item; opens Settings → About instead of a browser (#210, was the releases page pre-#210) |
| — | `lifecycle` | `.notice` | `update: cleared pending what's new (user opened it)` | `openReleasesPage` — opening the `whatsNew` item acknowledges it, clearing `pendingWhatsNewVersion` (#130) |
| — | `lifecycle` | `.notice` | `update-install: decision=install target=<tag> asset=<name>` | `evaluateAutoInstall` — all gates passed; this release would be auto-installed (#122, ADR-0033). Phase 2 runs the installer only under `TOKENPACE_UPDATE_DRYRUN` (download/verify/unzip, no replace) |
| — | `lifecycle` | `.notice` | `update-install: decision=skip reason=<auto-install-off\|not-newer\|not-app-bundle\|no-asset>` | `evaluateAutoInstall` — why auto-install stood down (opt-out off / not newer / dev build / no version-named `.zip` asset); the single dropdown item still carries the signal (#122/#130) |
| — | `lifecycle` | `.notice` | `update-install: decision=defer reason=insufficient-space target=<tag>` | `evaluateAutoInstall` — installable, but downloading would leave < 5 GB free; deferred until space frees up. Not bypassed by a forced install. Re-evaluated next heartbeat (#124) |
| — | `lifecycle` | `.notice` | `update-install: decision=defer reason=on-battery target=<tag>` | `evaluateAutoInstall` — installable, but on battery; deferred until AC power. Re-evaluated next heartbeat. Bypassed by a forced (dry-run) install (#123) |
| — | `lifecycle` | `.notice` | `update-install: decision=defer reason=metered-network target=<tag>` | `evaluateAutoInstall` — installable, but on a metered (expensive/constrained) network; deferred until unmetered. The update *check* is unaffected. Re-evaluated next heartbeat (#123) |
| — | `lifecycle` | `.notice` | `update-install: auto set <bool>` | user toggled the "Install updates automatically" checkbox (#122; default-on since #130) |
| — | `lifecycle` | `.notice` | `update-install: user requested an immediate install` | user clicked "Update Now" in Settings → About (#221); the forced path follows |
| — | `lifecycle` | `.notice` | `update-install: decision=forced-install target=<tag> asset=<name>` | `installUpdateNow` — the explicit request passed every gate it must; installing now, bypassing the power/metered courtesy gates (#221) |
| — | `lifecycle` | `.notice` | `update-install: decision=forced-skip reason=insufficient-space target=<tag>` | `installUpdateNow` — the one gate an explicit request cannot open: installing would leave < 5 GB free (#221) |
| — | `lifecycle` | `.notice` | `update-install: decision=forced-skip reason=<no-known-release\|not-newer\|not-app-bundle\|no-asset>` | `installUpdateNow` — nothing to install however the user asks: no release known yet / already current / dev build / no version-named `.zip` (#221) |
| — | `lifecycle` | `.error` | `update-install: forced install hit an environment gate — unexpected` | `installUpdateNow` — a power/metered gate closed despite favourable values being passed; indicates a logic error, not a user-facing condition (#221) |
| — | `lifecycle` | `.error` | `update-install: forced install reported auto-install-off — unexpected` | `installUpdateNow` — the opt-in gate closed despite the click being treated as consent; indicates a logic error (#221) |
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
| — | `lifecycle` | `.notice` | `update-install: last failed install set tag=<tag> stage=<download\|unzip\|verify\|replace>` | `startInstall` — an install failed; the tag + stage + reason are recorded (`lastUpdateFailure`) so the tag is not retried (a newer tag still is), driving the red `updateFailed` item and the About-pane failure row (#130/#210, ADR-0036) |
| — | `lifecycle` | `.error` | `update-install: did not complete (<outcome>) — signal item remains` | `AppDelegate` — the install ended in a failure outcome; the speculative "what's new" is cleared and the single dropdown item carries the signal (#123/#124/#130) |
| — | `archive` | `.notice` | `archive: sync starting (userInitiated=<bool>)` | `performArchiveSync` — an archive sync begins (daily heartbeat or "Archive now"); #110, ADR-0031 |
| — | `archive` | `.notice` | `archive: sync ok — <n> updated, <bytes> bytes, <total> files / <totalBytes> bytes in archive` | `performArchiveSync` — the sync finished; the `lastArchiveSync` marker is advanced (#110). `<total>`/`<totalBytes>` count the whole archive incl. source-pruned files |
| — | `archive` | `.error` | `archive: sync failed — <error>` | `performArchiveSync` — the sync threw (e.g. destination unwritable); marker not advanced, retried next heartbeat (#110). Low disk space is handled by its own row below, not here |
| — | `archive` | `.notice` | `archive: deferred reason=on-battery` | `pollArchiveIfDue` — a sync was due but the Mac is unplugged; marker not advanced, re-evaluated next heartbeat. Logged only while a sync is genuinely due, not every heartbeat. Bypassed by "Archive Now" (#306) |
| — | `archive` | `.notice` | `archive: blocked reason=insufficient-space need=<bytes> free=<bytes>` | `performArchiveSync` — copying would leave < 5 GB free on the destination volume, so the run wrote nothing; marker not advanced, and Settings shows a ⚠️ line. `.notice`, not `.error`: a designed refusal would otherwise be the one archive line visible to a plain `log show`, dressing a normal full disk up as a fault. Not bypassed by "Archive Now" (#306) |
| — | `lifecycle` | `.info` | `back-to-work: suppressed by quiet hours` | `maybePostBackToWork` — a blocked→unblocked edge fired but the current time is outside the allowed-hours window or on a suppressed weekday, so nothing is posted (#160, ADR-0039) |
| — | `lifecycle` | `.info` | `extra-usage: suppressed by quiet hours` | `maybePostExtraUsage` — a not-spending→spending-on-credits edge fired but the current time is outside the shared allowed-hours window or on a suppressed weekday, so nothing is posted |
| — | `lifecycle` | `.info` | `incident: suppressed by quiet hours` | `advanceEpisodeSubscription` — a followed episode produced an event but the current time is outside the shared allowed-hours window or on a suppressed weekday, so no banner is posted (#279, ADR-0071 §8) |
| — | `lifecycle` | `.info` | `incident: followed the episode incidents=<n>` | `toggleEpisodeSubscription` — the user clicked the popup's subscribe row; `<n>` is how many incidents the episode covered at that moment (#279) |
| — | `lifecycle` | `.info` | `incident: unfollowed the episode` | `toggleEpisodeSubscription` — the user clicked the row again to stop following |
| — | `lifecycle` | `.notice` | `incident: preview (forced) notifications` | `previewIncidentBanners` — the Settings "Preview" button; posts one of every incident banner at once, bypassing quiet hours (#279) |
| — | `journal` | `.info` | `status-payload-log: recorded a material change` | `pollStatusIfDue` (App) — the status payload differed from the last written line and was appended to the dev JSONL (#279, ADR-0071 §10) |

## `Sources/TokenPace/LogArchiver.swift`

Accumulate-only mirror of Claude Code's session logs (#110, ADR-0031). Per-file copy failures are
logged and skipped without aborting the sync; file paths stay `.private`/`.debug` (project names).

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| — | `archive` | `.debug` | `archive root <root>: <n> source files, <m> to copy` | `sync(to:)` — per allow-listed root (`projects`/`file-history`/`plans`), after the plan is computed |
| — | `archive` | `.error` | `archive copy failed for <path>: <error>` | `sync(to:)` — one file could not be copied (unreadable/locked); logged and skipped, sync continues. `<path>` is `.private` |

## `Sources/TokenPace/UsageJournal.swift`

Append-only usage-journal writer (#242, ADR-0067). All write errors are swallowed (logged) so a
journal problem never fails a poll. No file paths at `.notice` (Application Support, but keep the
discipline). The two fixture-generation lines are emitted from `App.swift` under the same `journal`
category (the dev `TOKENPACE_GENERATE_JOURNAL` hook).

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| — | `journal` | `.error` | `journal write failed: <error>` | `writeLine` — the record could not be encoded or the directory/file could not be prepared; the line is dropped, the poll continues |
| — | `journal` | `.error` | `journal open failed: errno=<errno>` | `appendLocked` — `open()` on the journal file failed |
| — | `journal` | `.error` | `journal lock failed: errno=<errno>` | `appendLocked` — `flock(LOCK_EX)` failed; the line is dropped rather than risk an interleaved write |
| — | `journal` | `.error` | `journal write() failed: errno=<errno>` | `appendLocked` — a `write()` returned ≤ 0 mid-line |
| — | `journal` | `.notice` | `journal: generating fixture — <days> days, <n> records` | `generateJournalFixture` (App) — the dev `TOKENPACE_GENERATE_JOURNAL` hook started synthesizing a journal |
| — | `journal` | `.notice` | `journal: fixture written` | `generateJournalFixture` (App) — the fixture was written; the app then terminates |

## `Sources/TokenPace/StatusPayloadLog.swift`

Dev-only JSONL of raw `status.claude.com` payloads (#279, ADR-0071 §10), written only when the
material content changes. Mirrors `UsageJournal`'s error discipline exactly — every failure is
logged and swallowed, because a diagnostic log that can break the app it diagnoses is worth nothing.
The "recorded a material change" line is emitted from `App.swift` under the same `journal` category,
and the enable/disable line from `DevToolsWindowController.swift`.

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| — | `journal` | `.error` | `status-payload-log: write failed <error>` | `writeLine` — the line could not be serialised or the directory could not be prepared; the sample is dropped, the poll continues |
| — | `journal` | `.error` | `status-payload-log: open failed errno=<errno>` | `appendLocked` — `open()` on the payload file failed |
| — | `journal` | `.error` | `status-payload-log: lock failed errno=<errno>` | `appendLocked` — `flock(LOCK_EX)` failed; the line is dropped rather than risk an interleaved write |
| — | `journal` | `.error` | `status-payload-log: write() failed errno=<errno>` | `appendLocked` — a `write()` returned ≤ 0 mid-line |
| — | `journal` | `.info` | `status-payload-log: enabled set <bool>` | `payloadLogToggled` (DevTools) — the Development-tools checkbox was flipped; takes effect on the next status poll |

## `Sources/TokenPace/IncidentNotificationDelegate.swift`

Routes taps on incident banners (#279). Runs on `UNUserNotificationCenter`'s own queue, **not** the
main actor — see the type doc for why touching `@MainActor` state from here traps.

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| — | `lifecycle` | `.info` | `incident: unfollowed from a banner action` | `unfollow` — the user pressed the banner's "Unfollow" button; the subscription is cleared and the popup re-renders |

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
| — | `lifecycle` | `.notice` | `calm-color-mode: set <mode>` | user picked a "Calm non-critical colors" segment (#105, #224); `<mode>` is the raw `CalmColorMode` (`off`/`yellowGreen`/`yellowGreenBlue`) — replaces the old `calm-colors` + `work-harder-colors` toggles |
| — | `lifecycle` | `.notice` | `menu-bar-style: set <style>` | user picked a "Bar style" segment on the **Menu bar** pane (#224, per-surface since #329 [ADR-0080](../adr/0080-per-surface-bar-style.md)); `<style>` is the raw `BarStyle` (`progress`/`pressure`/`gauge`) and governs that surface only. Renamed with the UI in #307 ([ADR-0076](../adr/0076-pressure-scale-for-marker-less-bar.md)) — `pacing` → `progress`, `simple` → `pressure`; `gauge` joined in #326 ([ADR-0079](../adr/0079-centred-zero-gauge-scale.md)). `mixed` can no longer be written: it named a *pair* of styles, and #329 gave each surface its own key |
| — | `lifecycle` | `.notice` | `dropdown-style: set <style>` | same, for the **Dropdown** pane's own "Bar style" row (#329). The two rows are independent — picking one never emits the other |
| — | `lifecycle` | `.notice` | `bar-style: migrated <old> → menu-bar <style>, dropdown <style>` | launch-time split of the pre-#329 single `barStyle` key across the two surfaces, emitted once per upgraded install by `PersistedConfig.migrateBarStyleIfNeeded` (which then deletes the old key). `<old>` also covers the pre-#307 raws, so one line can carry both migrations: `mixed` → `menu-bar pressure, dropdown progress` (what that value actually drew), `simple` → both `pressure`, `pacing` → both `progress`, `gauge` → both `gauge`. Absent on a fresh install, on a user who never set the key, and on every launch after the first |
| — | `lifecycle` | `.notice` | `show-ticks: popup set <bool>` | user toggled the "Show ticks on bars" checkbox (#224) — popup-only tick ruler |
| 434 | `lifecycle` | `.notice` | `reset-countdown: menu-bar mode set <mode>` | user picked a "Show reset countdown" segment (#103); `<mode>` is the raw `ResetCountdownMode` |
| 442 | `lifecycle` | `.notice` | `service-status-dot: menu-bar set <bool>` | user toggled the "Show service status dot on issues" checkbox (#31) |
| — | `lifecycle` | `.notice` | `extra-usage-icon: menu-bar set <bool>` | user toggled the "Show extra-usage credits icon" checkbox (#146) |
| — | `lifecycle` | `.notice` | `hide-calm-7d: menu-bar set <bool>` | user toggled the "Hide 7-day bar when calm" checkbox (#94, ADR-0034) |
| — | `lifecycle` | `.notice` | `pause-hides-bars: menu-bar set <bool>` | user toggled the "Pause icon hides bars" checkbox — stored as `pauseHidesBars`; when fully blocked the red pause icon is always shown, this only gates whether the pacing bars are hidden beside it (#194, #199, #227; ADR-0063) |
| — | `lifecycle` | `.notice` | `model-specific-limits: popup set <mode>` | user picked a "Show model & service limits" segment — gates the popup's per-model/per-service rows (Opus/Sonnet/scoped); `<mode>` is the raw `PopupSectionVisibility` (`always`/`nonCalm`/`optionOnly`) (#211) |
| — | `lifecycle` | `.notice` | `extra-usage-section: popup set <mode>` | user picked a "Show extra usage" segment — gates the popup's paid-credits section; `<mode>` is the raw `PopupSectionVisibility`. Distinct from `extra-usage-icon`, which is the menu-bar glyph (#211) |
| — | `lifecycle` | `.notice` | `appearance settings reset to defaults` | user cleared the Appearance keys (#214); all thirteen Appearance keys cleared to their defaults, plus the legacy pre-#329 `barStyle` key — swept too so a stale value can't re-seed the per-surface pair on a later launch |
| — | `lifecycle` | `.notice` | `appearance preset applied: <preset>` | user picked an Appearance-pane preset segment (#215, #224); `<preset>` is the raw `AppearancePreset` (`chill`/`workHarder`/`controlFreak`) — sets all thirteen Appearance keys at once (twelve before #329 split `barStyle` in two) |
| — | `lifecycle` | `.notice` | `screen-lock-pause: setting set <bool>` | user toggled the "Pause polling while the screen is locked" checkbox (#114, ADR-0032) |
| 439 | `lifecycle` | `.notice` | `update: automatic checks set <bool>` | user toggled the "Check for updates automatically" checkbox (#37) |
| — | `lifecycle` | `.notice` | `archive: enabled set <bool>` | user toggled the "Archive session logs to a folder" checkbox (#110) |
| — | `lifecycle` | `.notice` | `archive: destination chosen` | user picked an archive folder via `NSOpenPanel` (#110); the path itself is not logged |
| — | `lifecycle` | `.notice` | `journal: enabled set <bool>` | user toggled the "Record usage history" checkbox in Settings → Extra features → Usage history (#242, ADR-0067) |
| — | `lifecycle` | `.notice` | `back-to-work: enabled set <bool>` | user toggled the "Back to work" notification switch (#160, ADR-0039) |
| — | `lifecycle` | `.notice` | `back-to-work: time window set <start>–<end>` | user changed the allowed-hours pickers; `<start>`/`<end>` are minute-of-day (#160) |
| — | `lifecycle` | `.notice` | `back-to-work: suppress set <raw>` | user picked a "Suppress notifications on" radio; `<raw>` is the raw `SuppressDays` (#160) |
| — | `lifecycle` | `.notice` | `back-to-work: try (forced) notification` | user pressed the Settings "Try" button, forcing a `postBackToWork` that bypasses edge-detection and quiet hours (#193) |
| — | `lifecycle` | `.notice` | `extra-usage: notify enabled set <bool>` | user toggled the "Switching to Extra Usage" notification switch |
| — | `lifecycle` | `.notice` | `incident: max age set <n>h` | user changed "Hide incidents older than" in Extra features; `0` means no limit (#279, ADR-0071 §9) |
| — | `lifecycle` | `.notice` | `extra-usage: try (forced) notification` | user pressed the "Switching to Extra Usage" Settings "Try" button, forcing a `postExtraUsage` that bypasses edge-detection and quiet hours |

## `Sources/TokenPace/Settings/UIPanes.swift`

The first — and so far only — user of the `ui` category. The Settings *toggle* lines above are
`lifecycle` because they change persisted state; this one changes nothing, it only reports that a
UI affordance ran, which is what `ui` is for.

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| — | `ui` | `.notice` | `appearance config copied to clipboard` | user clicked the copy button in the "Change UI preset" row (#257); the JSON body itself is **not** logged — it is on the clipboard, and the log line only needs to establish that the click was handled |

## `Sources/TokenPace/BackToWorkNotifier.swift`

Thin `UserNotifications` glue for the local notifications — "Back to work!" (#160, ADR-0039) and
"Now using Extra Usage Credit". No token/limit values and no money amounts are ever logged (the amount
lives only in the delivered banner body). The `<kind>` in the shared post path is `back-to-work` or
`extra-usage`.

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| — | `lifecycle` | `.info` | `back-to-work: authorization dev (no bundle)` | `requestAuthorizationIfNeeded` — running as a bare `swift run` binary; authorization is impossible, so it is skipped |
| — | `lifecycle` | `.info` | `back-to-work: authorization <granted/denied>` | `requestAuthorizationIfNeeded` — the system authorization prompt resolved |
| — | `lifecycle` | `.error` | `back-to-work: authorization error <error>` | `requestAuthorizationIfNeeded` — `requestAuthorization` returned an error |
| — | `lifecycle` | `.info` | `<kind>: edge detected, posting notification` | `post` — the request was added to `UNUserNotificationCenter` (the banner is delivered); `<kind>` is `back-to-work` or `extra-usage` |
| — | `lifecycle` | `.info` | `<kind>: not authorized, skipping` | `post` — the feature is on but notification authorization is not granted, so nothing is posted |
| — | `lifecycle` | `.error` | `<kind>: post failed <error>` | `post` — `UNUserNotificationCenter.add` returned an error |

## `Sources/TokenPace/GHReleaseFetcher.swift`

The `gh api` subprocess for the maintainer update-check path (#37, ADR-0025); the token never appears
(gh resolves it from keyring internally).

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 46 | `network` | `.notice` | `update: gh path, launching <binary>` | before spawning `gh api …/releases/latest` under `TOKENPACE_GH_AUTH` |

<!-- `Sources/TokenPace/UpdateNotifier.swift` removed in #130 (ADR-0036): no more system notifications;
the sole update signal is the single dropdown item logged as `update: menu item = …` above. -->

## `Sources/TokenPace/AwaitingInputWatcher.swift`

The "N sessions awaiting input" watcher (#233, ADR-0066). Deliberately quiet: nothing is logged per
FSEvents batch or per safety tick on the steady-state path — only gate transitions, a real change in
the count, and an error the user could act on.

`park`/`resume` carry the gate term that moved (#275). `feature off` also destroys the watcher and
clears the indicator; the screen reasons only park it, keeping the last count for the unlock.

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 92 | `lifecycle` | `.notice` | `awaiting-input: resumed (<reason>)` | `setActive(true, reason:)` — FSEvents stream started, safety timer armed, catch-up scan queued. `<reason>` ∈ {`screen available`} |
| 102 | `lifecycle` | `.notice` | `awaiting-input: parked (<reason>)` | `setActive(false, reason:)` — stream stopped and timer disarmed. `<reason>` ∈ {`screen locked`, `system sleep`, `feature off`} |
| 134 | `lifecycle` | `.error` | `awaiting-input: FSEventStreamCreate failed; safety poll only` | watched dirs unresolvable — degrades to the 45 s safety timer alone |
| 155 | `lifecycle` | `.debug` | `awaiting-input: FSEvents batch of <n> path(s)` | per-batch detail, only under `TOKENPACE_DEVTOOLS` |
| 191 | `lifecycle` | `.notice` | `awaiting-input <old> → <new> (urgency <u>)` | the scan result changed (count, urgency, or per-project breakdown). `<old>` is `—` on the first scan after a start |

## `Sources/TokenPace/PollingShell.swift`

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 46 | `lifecycle` | `.notice` | `system will sleep, pausing polling` | `NSWorkspace.willSleepNotification` fired |
| 52 | `lifecycle` | `.notice` | `system did wake, polling immediately` | `NSWorkspace.didWakeNotification` fired (the loop still re-polls only if the cache is stale — ADR-0032 D6) |
| 133 | `lifecycle` | `.notice` | `screen-lock-pause: <reason>, pausing polling` | `ScreenLockObserver` — screen locked / screensaver started / display asleep, with `pausePollingWhenScreenLocked` on (#114). `<reason>` ∈ {`screen locked`, `screensaver started`, `display asleep`}. **Absent when the preference is off** — the awaiting-input watcher still parks then (it rides the ungated availability callback, #275), so its `awaiting-input: parked` line can appear with no `screen-lock-pause` line beside it |
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
| 84 | `network` | `.error` | `status request transport error: <error>` | `transport.data(for:)` threw |
| 90 | `network` | `.error` | `status response not HTTP` | response was not `HTTPURLResponse` |
| 97 | `network` | `.notice` | `status 200 ok components=<count> incidents=<n>` | HTTP 200; logs the component count and, since #279, the number of incidents the payload carried |
| 104 | `network` | `.error` | `status request failed: HTTP <statusCode>` | non-200 status |

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
| 526 | `network` | `.notice` | `five_hour idle suppressed — within reset grace` | the reset-boundary idle grace armed (`applyIdleGrace`, `idleSuppressedUntil` nil → non-nil); emitted **once per transition**, not every poll. Now arms only when the previous window was active **and** the user was recently working (`claudeActive && utilFresh`, ADR-0045) — a genuine pause no longer arms it |
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
| `network` | 29 | `UsageClient` (6), `GitHubReleaseClient` (6), `StatusClient` (5), `UsageSnapshot` (3), `UpdateInstaller` (3), `PollingEngine` (2), `GitHubRelease` (1), `GHReleaseFetcher` (1), `App` (1) |
| `keychain` | 12 | `ClaudeCLIRefresher` (6), `TokenProvider` (3), `PollingEngine` (1) |
| `lifecycle` | 110 | `App` (47), `SettingsModel` (29), `UpdateInstaller` (13), `PollingShell` (7), `BackToWorkNotifier` (6), `AwaitingInputWatcher` (5), `ShellEnvironment` (1), `PollingEngine` (1), `IncidentNotificationDelegate` (1) |
| `ui` | 1 | `UIPresetsPane` (1) |
| `archive` | 7 | `App` (5), `LogArchiver` (2) |
| `journal` | 12 | `UsageJournal` (4), `StatusPayloadLog` (4), `App` (3), `DevToolsWindowController` (1) |

**Total: 173 log statements** — `.error` ×46, `.notice` ×109, `.info` ×13, `.debug` ×5.

> Counts recomputed from the source in #275 (the previous figures had drifted over several releases —
> `SettingsModel` and `BackToWorkNotifier` were missing entirely). Regenerate with:
> `grep -rn 'AppLogger\.<category>\.' Sources/ | grep -v AppLogger.swift`.

The `journal: enabled set <bool>` toggle line (`SettingsModel`) is a `lifecycle` statement (like the
other Settings-toggle lines), counted under `lifecycle`. The twelve `journal`-category statements are
the four `UsageJournal` write-failure lines, the four `StatusPayloadLog` ones that mirror them, the
three in `App` (two fixture-generation lines plus the payload-log "recorded a material change"), and
the Development-tools toggle in `DevToolsWindowController` — the first `journal` statement at
`.info` rather than `.error`/`.notice`.

The `five_hour idle …` / `window active again` pair is one call site (`sessionIdleTransition`) that
emits one of two strings; it is counted once under `PollingEngine` network. The
`five_hour idle suppressed …` grace line (`applyIdleGrace`, ADR-0041) is a separate call site,
counted as the second `PollingEngine` network statement.
