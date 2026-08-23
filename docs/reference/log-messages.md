# Log message catalog

A complete, verbatim inventory of every log statement TokenPace emits, grouped by
source file. All logging goes through the `AppLogger` facade (`os.Logger` /
unified logging) — see [`Sources/TokenPaceKit/AppLogger.swift`](../../Sources/TokenPaceKit/AppLogger.swift).

> **Keep this in sync.** Whenever you add, remove, or change the text of a log
> statement, update the matching row here in the same change. See
> [conventions.md → Logging](conventions.md#logging).

## Facade

- **Subsystem:** `com.artem-n.tokenpace` (shared by the `.app` bundle and `swift run`).
- **Categories:**
  - `network` — Usage/Status API requests, HTTP result codes, decode failures, snapshot synthesis.
  - `keychain` — Keychain reads via the `security` CLI (exit status, ADR-0019), token-expiry checks, delegated token refresh (ADR-0017).
  - `lifecycle` — app launch, launch-at-login, sleep/wake, network up/down, polling-interval changes.
  - `ui` — menu-bar rendering diagnostics (defined, currently unused).
  - `archive` — session-log archiver: sync start/finish, file/byte counts, failures (ADR-0030). File paths only at `.debug` (they contain project names).
  - `journal` — usage journal (ADR-0067) and the dev status-payload JSONL (ADR-0071 §10): append-write failures, fixture generation. Percentages only, never a token.

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
| 313 | `lifecycle` | `.notice` | `manual refresh requested (Troubleshoot)` | `forceRefresh()` — user clicked "Refresh now" in Troubleshoot; a `.manualRefresh` signal is sent and the status poll is marked due (ADR-0020) |
| — | `lifecycle` | `.notice` | `dev: stub scenario → <id>` | `switchScenario(_:)` — the dev-tools live stub selector picked a new data source (`<id>` = the `TOKENPACE_STUB` value, `real` for the live network); the polling engine is rebuilt and an immediate poll forced. Dev-only (`devToolsEnabled` defaults key, ADR-0053) |
| — | `lifecycle` | `.notice` | `dev: unknown TOKENPACE_STUB "<value>" — running the frozen screenshot stub instead of the real network. Available: <ids>` | `applicationDidFinishLaunching` — `TOKENPACE_STUB` was set to something the registry doesn't know, so the run fell back to the frozen `screenshot` frame. `<ids>` is built from `StubScenario.allCases`. Silent when the variable is absent or valid |
| 358 | `lifecycle` | `.notice` | `optimistic reset applied, forcing refresh` | `fireOptimisticReset()` — a window's reset boundary passed; the retained snapshot is rolled forward locally (zero usage + next `resets_at`) and rendered immediately, then `.manualRefresh` forces the authoritative poll (ADR-0030) |
| 421 | `lifecycle` | `.notice` | `config: first run, no prior version (<version>)` | `runConfigMigrationsIfNeeded()` — no `lastRunVersion` stored; records the version, no migrations (ADR-0023) |
| 423 | `lifecycle` | `.notice` | `config: version unchanged (<version>)` | stored `lastRunVersion` equals the running version — nothing to migrate |
| 426 | `lifecycle` | `.notice` | `config: version <old> → <new>, running migrations` | stored version differs from the running one — the `.upgraded` extension point (empty scaffold for now) |
| 445 | `lifecycle` | `.notice` | `launch-at-login: not an .app bundle (swift run), skipping opt-out auto-register` | `registerLaunchAtLoginIfNeeded()` — running as a bare `swift run` binary, so opt-out auto-register is skipped to avoid polluting Login Items |
| 451 | `lifecycle` | `.notice` | `launch-at-login: status=<status>, no auto-register` | status is `.registered`/`.requiresApproval`, so no auto-register is needed |
| 456 | `lifecycle` | `.notice` | `launch-at-login: auto-registered (opt-out)` | successful auto-registration (`.notRegistered`, or recovery from `.notFound` after an update) |
| 461 | `lifecycle` | `.error` | `launch-at-login: auto-register failed: <error>` | `LaunchAtLoginController.enable()` threw on an installed `.app` bundle — an unexpected, registerable-but-refused case |
| 640 | `network` | `.notice` | `update: checking (userInitiated=<bool>)` | `performUpdateCheck` — an update check begins (launch, 12 h heartbeat, or "Check now") |
| — | `lifecycle` | `.notice` | `update: TOKENPACE_GH_AUTH found in login shell env` | `resolveGHAuth` — the flag was absent from `ProcessInfo` but found in the login shell's rc files via `ShellEnvironment` (`zsh -l -i`), so the `gh` update path is enabled for a login-launched app (ADR-0025) |
| — | `lifecycle` | `.notice` | `update: new version available tag=<tag> firstSeen=<bool>` | `handleUpdateFound` — a newer release was found; `firstSeen` = first time this tag is surfaced (`lastSeenLatestVersion`) |
| — | `lifecycle` | `.notice` | `update: cleared pending what's new (superseded by newer release)` | `handleUpdateFound` — a release newer than the installed build pre-empts an unseen "what's new" (ADR-0036) |
| — | `lifecycle` | `.notice` | `update: cleared stale install-failure record (superseded by newer release)` | `handleUpdateFound` — a newer release makes a stored `lastUpdateFailure` stale; the About-pane failure row is cleared |
| — | `lifecycle` | `.notice` | `update: menu item = <hidden\|updateFailed\|updateAvailable\|updatePending\|whatsNew>` | `refreshUpdateMenuItem` — the single update dropdown item's resolved state (ADR-0036) |
| — | `lifecycle` | `.notice` | `update: user opened About from update item (item=<state>)` | `openReleasesPage` — user clicked the update item in a pending-action state (`updateFailed`/`updateAvailable`/`updatePending`); opens Settings → About instead of a browser |
| — | `lifecycle` | `.notice` | `update: user opened release notes from update item (tag=<tag>)` | `openReleasesPage` — user clicked the `whatsNew` item; opens `…/releases/tag/<tag>` in the browser rather than About, since the update already landed |
| — | `lifecycle` | `.notice` | `update: cleared pending what's new (user opened it)` | `openReleasesPage` — opening the `whatsNew` item acknowledges it, clearing `pendingWhatsNewVersion` |
| — | `lifecycle` | `.notice` | `update-install: decision=install target=<tag> asset=<name>` | `evaluateAutoInstall` — all gates passed; this release would be auto-installed (ADR-0033). Phase 2 runs the installer only under `TOKENPACE_UPDATE_DRYRUN` (download/verify/unzip, no replace) |
| — | `lifecycle` | `.notice` | `update-install: decision=skip reason=<auto-install-off\|not-newer\|not-app-bundle\|no-asset>` | `evaluateAutoInstall` — why auto-install stood down; the single dropdown item still carries the signal |
| — | `lifecycle` | `.notice` | `update-install: decision=defer reason=insufficient-space target=<tag>` | `evaluateAutoInstall` — installable, but downloading would leave < 5 GB free; deferred until space frees up. Not bypassed by a forced install. Re-evaluated next heartbeat |
| — | `lifecycle` | `.notice` | `update-install: decision=defer reason=on-battery target=<tag>` | `evaluateAutoInstall` — installable, but on battery; deferred until AC power. Re-evaluated next heartbeat. Bypassed by a forced (dry-run) install |
| — | `lifecycle` | `.notice` | `update-install: decision=defer reason=metered-network target=<tag>` | `evaluateAutoInstall` — installable, but on a metered network; deferred until unmetered. The update *check* is unaffected. Re-evaluated next heartbeat |
| — | `lifecycle` | `.notice` | `update-install: auto set <bool>` | user toggled the "Install updates automatically" checkbox |
| — | `lifecycle` | `.notice` | `update-install: user requested an immediate install` | user clicked "Update Now" in Settings → About; the forced path follows |
| — | `lifecycle` | `.notice` | `update-install: decision=forced-install target=<tag> asset=<name>` | `installUpdateNow` — the explicit request passed every gate it must; installing now, bypassing the power/metered courtesy gates |
| — | `lifecycle` | `.notice` | `update-install: decision=forced-skip reason=insufficient-space target=<tag>` | `installUpdateNow` — the one gate an explicit request cannot open: installing would leave < 5 GB free |
| — | `lifecycle` | `.notice` | `update-install: decision=forced-skip reason=<no-known-release\|not-newer\|not-app-bundle\|no-asset>` | `installUpdateNow` — nothing to install however the user asks |
| — | `lifecycle` | `.error` | `update-install: forced install hit an environment gate — unexpected` | `installUpdateNow` — a power/metered gate closed despite favourable values being passed; indicates a logic error, not a user-facing condition |
| — | `lifecycle` | `.error` | `update-install: forced install reported auto-install-off — unexpected` | `installUpdateNow` — the opt-in gate closed despite the click being treated as consent; indicates a logic error |
| — | `lifecycle` | `.notice` | `update-install: skip (not an .app bundle)` | `UpdateInstaller.install` — gated out on a dev build before any I/O |
| — | `network` | `.notice` | `update-install: download started tag=<tag> asset=<name> via=<gh\|https>` | `UpdateInstaller` — the asset download began; `gh` path for the private repo (asset needs credentials), else anonymous HTTPS |
| — | `network` | `.notice` | `update-install: download ok bytes=<n>` | `UpdateInstaller` — the asset downloaded successfully |
| — | `network` | `.error` | `update-install: download failed <error>` | `UpdateInstaller` — network / HTTP-status / write failure; falls back to manual Download |
| — | `lifecycle` | `.notice` | `update-install: unzip ok path=<tmp>` | `UpdateInstaller` — `ditto -x -k` extracted the `.app` to a temp dir |
| — | `lifecycle` | `.error` | `update-install: unzip failed <reason>` | `UpdateInstaller` — extraction failed or the archive held no `.app` |
| — | `lifecycle` | `.notice` | `update-install: verify ok teamID=S5A4U9798Y gatekeeper=accepted` | `UpdateInstaller` — `codesign` + Team-ID + Gatekeeper (`spctl`) all passed |
| — | `lifecycle` | `.error` | `update-install: verify FAILED reason=<reason>` | `UpdateInstaller` — signature / Team-ID / notarization check failed; the bundle is discarded, nothing replaced |
| — | `lifecycle` | `.notice` | `update-install: dry-run — would replace <target> with <tag> (verified OK) [TOKENPACE_UPDATE_DRYRUN]` | `UpdateInstaller` — dry run stops here: verified but not installed |
| — | `lifecycle` | `.notice` | `update-install: dry-run complete, verified bundle at <path>` | `AppDelegate` — the dry-run finished; the verified bundle is kept at `<path>` for inspection |
| — | `lifecycle` | `.notice` | `update-install: replace ok target=<path>` | `UpdateInstaller` — the target `.app` was atomically replaced with the verified build |
| — | `lifecycle` | `.error` | `update-install: replace FAILED reason=<reason>` | `UpdateInstaller` — the atomic replace failed (permissions / I/O); old bundle intact, manual Download remains |
| — | `lifecycle` | `.notice` | `update-install: installed <tag>, relaunching` | `UpdateInstaller` — replace done; about to relaunch the new build |
| — | `lifecycle` | `.notice` | `update-install: relaunching from <path>` | `UpdateInstaller.relaunch` — launching the new bundle; this process then terminates |
| — | `lifecycle` | `.error` | `update-install: relaunch failed <error>` | `UpdateInstaller.relaunch` — couldn't launch the new bundle; this process stays alive, the new version is picked up on next manual launch |
| — | `lifecycle` | `.notice` | `update-install: what's new pending set tag=<tag>` | `startInstall` — the pending "what's new" is persisted **before** the install runs, so it survives the imminent relaunch (ADR-0036) |
| — | `lifecycle` | `.notice` | `update-install: installed <tag>, app will relaunch` | `AppDelegate` — the real install succeeded; the installer is relaunching |
| — | `lifecycle` | `.notice` | `update-install: last failed install set tag=<tag> stage=<download\|unzip\|verify\|replace>` | `startInstall` — an install failed; the tag + stage + reason are recorded (`lastUpdateFailure`) so the tag is not retried (a newer tag still is), driving the red `updateFailed` item and the About-pane failure row (ADR-0036) |
| — | `lifecycle` | `.error` | `update-install: did not complete (<outcome>) — signal item remains` | `AppDelegate` — the install ended in a failure outcome; the speculative "what's new" is cleared and the single dropdown item carries the signal |
| — | `archive` | `.notice` | `archive: sync starting (userInitiated=<bool>)` | `performArchiveSync` — an archive sync begins (daily heartbeat or "Archive now"); ADR-0031 |
| — | `archive` | `.notice` | `archive: sync ok — <n> updated, <bytes> bytes, <total> files / <totalBytes> bytes in archive` | `performArchiveSync` — the sync finished; the `lastArchiveSync` marker is advanced. `<total>`/`<totalBytes>` count the whole archive incl. source-pruned files |
| — | `archive` | `.error` | `archive: sync failed — <error>` | `performArchiveSync` — the sync threw (e.g. destination unwritable); marker not advanced, retried next heartbeat. Low disk space is handled by its own row below, not here |
| — | `archive` | `.notice` | `archive: deferred reason=on-battery` | `pollArchiveIfDue` — a sync was due but the Mac is unplugged; marker not advanced, re-evaluated next heartbeat. Logged only while a sync is genuinely due, not every heartbeat. Bypassed by "Archive Now" |
| — | `archive` | `.notice` | `archive: blocked reason=insufficient-space need=<bytes> free=<bytes>` | `performArchiveSync` — copying would leave < 5 GB free on the destination volume, so the run wrote nothing; marker not advanced, Settings shows a warning line. `.notice`, not `.error`: a designed refusal would otherwise be the one archive line visible to a plain `log show`, dressing a normal full disk up as a fault. Not bypassed by "Archive Now" |
| — | `lifecycle` | `.info` | `back-to-work: suppressed by quiet hours` | `maybePostBackToWork` — the subscription quota became available again (the 5h/7d edge; the user need not have been blocked — credits may have covered the gap) but the current time is outside the allowed-hours window or on a suppressed weekday, so nothing is posted (ADR-0039) |
| — | `lifecycle` | `.info` | `extra-usage: suppressed by quiet hours` | `maybePostExtraUsage` — a not-spending→spending-on-credits edge fired but the current time is outside the shared allowed-hours window or on a suppressed weekday, so nothing is posted |
| — | `lifecycle` | `.info` | `incident: suppressed by quiet hours` | `advanceEpisodeSubscription` — a followed episode produced an event but the current time is outside the shared allowed-hours window or on a suppressed weekday, so no banner is posted (ADR-0071 §8) |
| — | `lifecycle` | `.info` | `incident: followed the episode incidents=<n>` | `toggleEpisodeSubscription` — user clicked the popup's subscribe row; `<n>` is how many incidents the episode covered at that moment |
| — | `lifecycle` | `.info` | `incident: unfollowed the episode` | `toggleEpisodeSubscription` — user clicked the row again to stop following |
| — | `lifecycle` | `.notice` | `incident: preview (forced) notifications` | `previewIncidentBanners` — Settings "Preview" button; posts one of every incident banner at once, bypassing quiet hours |
| — | `journal` | `.info` | `status-payload-log: recorded a material change` | `pollStatusIfDue` (App) — the status payload differed from the last written line and was appended to the dev JSONL (ADR-0071 §10) |
| — | `network` | `.notice` | `status backoff holding for <seconds>s` | `pollStatusIfDue` (App) — a `429` armed **this status source's own** `PollingBackoff` (ADR-0119). `<seconds>` is the honoured `Retry-After`, or `180` when the server sent no usable hint. A repeat `429` re-logs the same line at the same value — the hold is re-set, never escalated |
| — | `network` | `.notice` | `status backoff cleared by a successful poll` | `pollStatusIfDue` (App) — the first `200` after a hold, releasing the source back to the ordinary politeness floor. Logged only when a hold was actually active |
| — | `network` | `.notice` | `github status backoff holding for <seconds>s` | `pollGitHubIfDue` (App) — a `429` from `githubstatus.com` armed the **GitHub source's own** `PollingBackoff` ([ADR-0121](../adr/0121-github-as-a-status-only-provider.md)). Deliberately a separate message rather than a shared one with a provider field, so a grep for one source never returns the other. `<seconds>` is the honoured `Retry-After`, or `180` without a usable hint; the hold is re-set, never escalated |
| — | `network` | `.notice` | `github status: 200 cleared the backoff hold` | `pollGitHubIfDue` (App) — the first `200` after a GitHub hold, releasing that source back to the politeness floor. Logged only when a hold was actually active |

## `Sources/TokenPace/LogArchiver.swift`

Accumulate-only mirror of Claude Code's session logs (ADR-0031). Per-file copy failures are
logged and skipped without aborting the sync; file paths stay `.private`/`.debug` (project names).

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| — | `archive` | `.debug` | `archive root <root>: <n> source files, <m> to copy` | `sync(to:)` — per allow-listed root (`projects`/`file-history`/`plans`), after the plan is computed |
| — | `archive` | `.error` | `archive copy failed for <path>: <error>` | `sync(to:)` — one file could not be copied (unreadable/locked); logged and skipped, sync continues. `<path>` is `.private` |

## `Sources/TokenPace/UsageJournal.swift`

Append-only usage-journal writer (ADR-0067). All write errors are swallowed (logged) so a
journal problem never fails a poll. No file paths at `.notice`. The two fixture-generation lines are
emitted from `App.swift` under the same `journal` category (the dev `TOKENPACE_GENERATE_JOURNAL` hook).

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| — | `journal` | `.error` | `journal write failed: <error>` | `writeLine` — the record could not be encoded or the directory/file could not be prepared; the line is dropped, the poll continues |
| — | `journal` | `.error` | `journal open failed: errno=<errno>` | `appendLocked` — `open()` on the journal file failed |
| — | `journal` | `.error` | `journal lock failed: errno=<errno>` | `appendLocked` — `flock(LOCK_EX)` failed; the line is dropped rather than risk an interleaved write |
| — | `journal` | `.error` | `journal write() failed: errno=<errno>` | `appendLocked` — a `write()` returned ≤ 0 mid-line |
| — | `journal` | `.notice` | `<file>: journal migrated: <n> rewritten, <m> unchanged[, <r> weekly resets repaired][, <s> severities recomputed][, <c> error runs collapsed (<f> lines folded)][, <k> unparseable][, <j> out of order]` | `migrateIfNeeded` — one journal file was rewritten into the current sample format. One line per file that actually changed; files already current are silent. The optional clauses appear only when non-zero: `weekly resets repaired` counts blackout dates rolled back onto the real grid (ADR-0107), `severities recomputed` counts **windows** whose colour bucket the current model judged differently (ADR-0115), `error runs collapsed` counts the collapsed records **written** and `lines folded` the attempts they replaced (ADR-0123) |
| — | `journal` | `.notice` | `journal migration complete: <n> file(s); originals kept as <suffixes>` | `migrateIfNeeded` — the pass finished and rewrote at least one file. Names the backup suffixes actually written (`.v1.bak`, `.v2.bak`, … one per generation touched) because those copies are the only remaining record of the API's own numbers and are **never** deleted by the app |
| — | `journal` | `.error` | `journal migration: cannot read <file>` | `migrateIfNeeded` — a journal file could not be read; it is left untouched and the pass continues with the next |
| — | `journal` | `.error` | `journal migration: cannot stage <file>` | `swapIn` — the rewritten contents could not be written beside the original; nothing is swapped |
| — | `journal` | `.error` | `journal migration: cannot back up <file>` | `swapIn` — the original could not be moved to `.v1.bak`; the staging file is removed and the original left in place |
| — | `journal` | `.error` | `journal migration: cannot swap in <file>` | `swapIn` — the final rename failed after the original was moved aside; the backup is moved back so the live path is never left empty |
| — | `journal` | `.notice` | `journal: generating fixture — <days> days, <n> records` | `generateJournalFixture` (App) — the dev `TOKENPACE_GENERATE_JOURNAL` hook started synthesizing a journal |
| — | `journal` | `.notice` | `journal: fixture written` | `generateJournalFixture` (App) — the fixture was written; the app then terminates |

## `Sources/TokenPace/StatusPayloadLog.swift`

Dev-only JSONL of raw `status.claude.com` payloads (ADR-0071 §10), written only when the material
content changes. Mirrors `UsageJournal`'s error discipline: every failure is logged and swallowed.
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

Routes taps on incident banners. Runs on `UNUserNotificationCenter`'s own queue, **not** the
main actor — see the type doc for why touching `@MainActor` state from here traps.

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| — | `lifecycle` | `.info` | `incident: unfollowed from a banner action` | `unfollow` — the user pressed the banner's "Unfollow" button; the subscription is cleared and the popup re-renders |

## `Sources/TokenPace/ShellEnvironment.swift`

Reads a variable from the login shell's rc files for a login-launched app (ADR-0025).

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
| — | `lifecycle` | `.notice` | `colors-tell: set <mode>` | user picked a **"Colors tell me"** segment; `<mode>` is the raw [`ColorAdvice`](../../Sources/TokenPaceKit/ColorAdvice.swift) — `slowDown`/`slowDownOrSpeedUp`/`howItsGoing`. Disabled (no line) while the menu bar is on Pressure, since the whole quiet side mutes unconditionally there; a preset/reset that changes the value still logs it |
| — | `lifecycle` | `.notice` | `menu-bar-style: set <style>` | user picked a **"Style"** tile on the **Menu bar** pane ([ADR-0080](../adr/0080-per-surface-bar-style.md)); `<style>` is the raw `BarStyle` (`progress`/`pressure`/`balance`) and governs that surface only |
| — | `lifecycle` | `.notice` | `dropdown-style: set <style>` | same, for the **Dropdown** pane's own **"Style"** row; the two surfaces are independent — picking one never emits the other |
| — | `lifecycle` | `.notice` | `bar-style: migrated <old> → menu-bar <style>, dropdown <style>` | launch-time split of the legacy single `barStyle` key across the two surfaces (`PersistedConfig.migrateBarStyleIfNeeded`, which then deletes the old key). Absent on a fresh install, on a user who never set the key, and on every launch after the first |
| — | `lifecycle` | `.notice` | ~~`show-ticks: popup set <bool>`~~ | **Retired** ([ADR-0098](../adr/0098-ruler-split-identify-always-explain-on-option.md)): the popup's under-bar ruler is now ⌥-on-demand; nothing left to toggle |
| — | `lifecycle` | `.notice` | ~~`reset-countdown: menu-bar mode set <mode>`~~ | **Retired** ([ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md)): the countdown lives only in the bars-less states, so the segment and `ResetCountdownMode` are gone |
| 442 | `lifecycle` | `.notice` | `service-status-dot: set <bool>` | user toggled the **"Show service status dot"** checkbox |
| — | `lifecycle` | `.notice` | ~~`extra-usage-icon: menu-bar set <bool>`~~ | **Retired** (ADR-0090): the credits icon follows the data, so there is no toggle left to log. Not to be confused with `extra-usage-section` below, which is the **dropdown** row and stays |
| — | `lifecycle` | `.notice` | `hide-top-5h-bar: set <mode>` | user picked a **"Hide the top 5h bar"** segment — the raw [`TopBarHiding`](../../Sources/TokenPaceKit/TopBarHiding.swift), `untilItNeedsAttention`/`never`. Fires on every pick, including a preset/reset that changes it |
| — | `lifecycle` | `.notice` | `hide-top-5h-bar: migrated <bool> → <mode>` | one-time upgrade of the legacy boolean `hideCalmSevenDayBar` onto the enum ([ADR-0086](../adr/0086-tri-state-calm-bar-hiding.md), `PersistedConfig.migrateTopBarHidingIfNeeded`): `true`→`untilItNeedsAttention`, `false`→`never`. Logged only when an explicit legacy value was found |
| — | `lifecycle` | `.notice` | ~~`pause-hides-bars: menu-bar set <bool>`~~ | **Retired** (ADR-0090): the toggle is gone — hiding the bars while blocked is the only behaviour |
| — | `lifecycle` | `.notice` | `show-per-model-limits: set <mode>` | user picked a **"Show per-model and per-service limits"** segment — gates the popup's per-model/per-service rows; `<mode>` is the raw [`PopupSectionVisibility`](../../Sources/TokenPaceKit/PopupSectionVisibility.swift): `whenItNeedsAttention`/`onceUsed`/`always` ([ADR-0087](../adr/0087-above-zero-section-visibility.md)) |
| — | `lifecycle` | `.notice` | `show-extra-usage: set <mode>` | user picked a **"Show *Extra usage*"** segment — gates the popup's paid-credits section; `<mode>` is `PopupSectionVisibility.creditsOffered`, one of `onceUsed`/`always` (no `whenItNeedsAttention`: an unlimited money cap has no bar and hence no severity, [ADR-0087](../adr/0087-above-zero-section-visibility.md)) |
| — | `lifecycle` | `.notice` | `<label>: migrated <old> → <new>` | one-time move of an Appearance key onto its surface-prefixed name (`menuBar.*`/`dropdown.*`, [ADR-0104](../adr/0104-appearance-named-for-behaviour-on-three-layers.md)), carrying the stored value through `legacyRawValues`. Emitted per key by `PersistedConfig.migrateRawKey`; `<label>` is one of `menu-bar-style`, `dropdown-style`, `colors-tell`, `hide-top-5h-bar`, `show-per-model-limits`, `show-extra-usage`. Zero to six lines per launch, once per upgraded install, idempotent without a marker key |
| — | `lifecycle` | `.notice` | `<label>: dropped unrecognised legacy value <raw>` | same pass, when the stored raw resolves to no case this build knows. Dropped rather than copied — an absent key means the getter's preset default |
| — | `lifecycle` | `.notice` | `<label>: rewrote stored <old> → <new>` | the value-level half of the same pass (`PersistedConfig.refreshRawValue`): a raw renamed after an install already moved its key gets rewritten to the current raw. Idempotent without a marker — the lookup answers only for raws that are not current |
| — | `lifecycle` | `.notice` | `service-status-dot: migrated key → menuBar.showServiceStatusDot` | the one `Bool` in the same pass — the key moves, the value needs no mapping |
| — | `lifecycle` | `.notice` | ~~`extra-usage-section: migrated nonCalm → aboveZero`~~ | **Gone.** Folded into the key migration above via `legacyRawValues` + `foldedForCredits` |
| — | `lifecycle` | `.notice` | ~~`model-limits-section: migrated optionOnly → aboveZero`~~, ~~`extra-usage-section: migrated optionOnly → aboveZero`~~ | **Gone**, same reason: `optionOnly` → `.onceUsed` moved into `legacyRawValues` |
| — | `lifecycle` | `.notice` | ~~`appearance settings reset to defaults`~~ | **Gone** ([ADR-0112](../adr/0112-appearance-presets-preview-apply-commits.md)) — was dead code, removed with the preview rework. `PersistedConfig.resetAppearanceToDefaults()` survives but logs nothing |
| — | `lifecycle` | `.notice` | `appearance preset applied: <preset>` | user pressed **`Apply`** on a previewed preset ([ADR-0112](../adr/0112-appearance-presets-preview-apply-commits.md)); `<preset>` is the raw `AppearancePreset` (`chill`/`workHarder`/`controlFreak`), writing all seven Appearance keys at once. Preceded by an `appearance preview:` line for the same preset |
| — | `lifecycle` | `.notice` | `appearance preview: <preset>` | user clicked a preset row, which previews it — values go into `PersistedConfig`'s overlay and both surfaces redraw, but nothing is written ([ADR-0112](../adr/0112-appearance-presets-preview-apply-commits.md)). Fires on every click, including switching between previews |
| — | `lifecycle` | `.notice` | `appearance preview: ended` | the overlay was dropped and the stored config is live again — on closing Settings, on clicking `My setup`, or before an individual option is written from a child page. Not emitted by `Apply`, which logs `appearance preset applied:` instead |
| — | `lifecycle` | `.notice` | `screen-lock-pause: setting set <bool>` | user toggled the "Pause polling while the screen is locked" checkbox (ADR-0032) |
| 439 | `lifecycle` | `.notice` | `update: automatic checks set <bool>` | user toggled the "Check for updates automatically" checkbox |
| — | `lifecycle` | `.notice` | `archive: enabled set <bool>` | user toggled the "Archive session logs to a folder" checkbox |
| — | `lifecycle` | `.notice` | `archive: destination chosen` | user picked an archive folder via `NSOpenPanel`; the path itself is not logged |
| — | `lifecycle` | `.notice` | `journal: enabled set <bool>` | user toggled the "Record usage history" checkbox in Settings → General → Usage history (ADR-0067) |
| — | `lifecycle` | `.notice` | `dropdown: option hint set <bool>` | user toggled "Show «hold ⌥ Option» hint" in Settings → Appearance › Dropdown. The menu re-reads the key on every open, so the line is the only record of *when* it changed |
| — | `lifecycle` | `.notice` | `back-to-work: enabled set <bool>` | user toggled the "Back to work" notification switch (ADR-0039) |
| — | `lifecycle` | `.notice` | `back-to-work: time window set <start>–<end>` | user changed the allowed-hours pickers; `<start>`/`<end>` are minute-of-day |
| — | `lifecycle` | `.notice` | `back-to-work: suppress set <raw>` | user picked a "Suppress notifications on" radio; `<raw>` is the raw `SuppressDays` |
| — | `lifecycle` | `.notice` | `back-to-work: try (forced) notification` | user pressed the Settings "Try" button, forcing a `postBackToWork` that bypasses edge-detection and quiet hours |
| — | `lifecycle` | `.notice` | `extra-usage: notify enabled set <bool>` | user toggled the "Switching to Extra usage" notification switch |
| — | `lifecycle` | `.notice` | `incident: max age set <n>h` | user changed "Hide incidents older than" in Providers → Incidents; `0` means no limit (ADR-0071 §9) |
| — | `lifecycle` | `.notice` | `settings hook: unknown section <raw> — ignored` | `TOKENPACE_SETTINGS_SECTION` carried a value that resolves to no pane (ADR-0084). Logged rather than silently ignored: a no-op hook looks exactly like one that worked and landed on the default pane |
| — | `lifecycle` | `.notice` | `settings hook: unknown child <raw> — opening the section` | the dotted form named a child index the section does not have; the window still opens on the section (ADR-0084) |
| — | `lifecycle` | `.notice` | `extra-usage: try (forced) notification` | user pressed the "Switching to Extra Usage" Settings "Try" button, forcing a `postExtraUsage` that bypasses edge-detection and quiet hours |

## `Sources/TokenPace/Settings/AppearancePanes.swift`

The first — and so far only — user of the `ui` category. The Settings *toggle* lines above are
`lifecycle` because they change persisted state; this one changes nothing, it only reports that a
UI affordance ran, which is what `ui` is for.

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| — | `ui` | `.notice` | `appearance config copied to clipboard` | user clicked the copy button in the "Change appearance preset" row; the JSON body itself is **not** logged — it is on the clipboard |

## `Sources/TokenPace/BackToWorkNotifier.swift`

Thin `UserNotifications` glue for the local notifications — "Back to work!" (ADR-0039) and
the "Extra usage" onset banner ([ADR-0114](../adr/0114-extra-usage-is-one-name.md) settled that name
across every surface). No token/limit values and no money amounts are ever logged (the amount
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

The `gh api` subprocess for the maintainer update-check path (ADR-0025); the token never appears
(gh resolves it from keyring internally).

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 46 | `network` | `.notice` | `update: gh path, launching <binary>` | before spawning `gh api …/releases/latest` under `TOKENPACE_GH_AUTH` |

## `Sources/TokenPace/AwaitingInputWatcher.swift`

The "N sessions awaiting input" watcher (ADR-0066). Deliberately quiet: nothing is logged per
FSEvents batch or per safety tick on the steady-state path — only gate transitions, a real change in
the count, and an error the user could act on.

`park`/`resume` carry the gate term that moved. `feature off` also destroys the watcher and
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
| 133 | `lifecycle` | `.notice` | `screen-lock-pause: <reason>, pausing polling` | `ScreenLockObserver` — screen locked / screensaver started / display asleep, with `pausePollingWhenScreenLocked` on. `<reason>` ∈ {`screen locked`, `screensaver started`, `display asleep`}. **Absent when the preference is off** — the awaiting-input watcher still parks then (it rides the ungated availability callback), so its `awaiting-input: parked` line can appear with no `screen-lock-pause` line beside it |
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
| 75 | `network` | `.error` | `status decode failed` | `decode(from:)` — JSON `DecodingError` |
| 116 | `network` | `.error` | `status request transport error: <error>` | `transport.data(for:)` threw |
| 122 | `network` | `.error` | `status response not HTTP` | response was not `HTTPURLResponse` |
| 129 | `network` | `.notice` | `status 200 ok components=<count> incidents=<n>` | HTTP 200; logs the component count and the number of incidents the payload carried |
| 137 | `network` | `.error` | `status rate-limited: HTTP 429 retryAfter=<n>` | HTTP 429 (ADR-0119). `<n>` is the parsed `Retry-After` in seconds, or **`-1`** when the server sent none / an unparseable one (the same `-1` sentinel the usage client uses) — `-1` means "no hint", not "retry in −1 s". Arms that source's own `PollingBackoff` |
| 144 | `network` | `.error` | `status request failed: HTTP <statusCode>` | any other non-200 status |

## `Sources/TokenPaceKit/GitHubRelease.swift`

Update-check release decode (ADR-0025).

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 55 | `network` | `.error` | `update: release decode failed` | `GitHubReleaseDecoder.decode(from:)` — JSON `DecodingError` |

## `Sources/TokenPaceKit/GitHubReleaseClient.swift`

Update-check orchestration (ADR-0025); every branch of a fetch outcome logs once. `.notFound`
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

> The `token expired, len=<count>` line lives in `PollingEngine.pollOnce` (ADR-0020) — see the
> `PollingEngine.swift` table below.

## `Sources/TokenPaceKit/UsageSnapshot.swift`

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 538 | `network` | `.notice` | `filled <key> sub-window resets_at from seven_day (was null)` | a per-model sub-window's `resets_at` was null; borrowed from the parent 7-day window |
| 594 | `network` | `.notice` | `synthesized <key> window on reset boundary (utilization=0, resets_at source=limits[])` | a core window's `resets_at` was null but a matching `limits[]` entry supplied one — a reset-boundary blip |
| 611 | `network` | `.notice` | `reconstructed <key> reset from the last known one (utilization=0, resets_at source=reconstructed)` | **`seven_day` only** — neither the window nor `limits[]` carried a `resets_at`, so the last server-supplied reset was rolled forward by whole weeks (ADR-0107). Fires on every poll of the 4–6 h weekly blackout, ~80–100 times per episode |
| 619 | `network` | `.notice` | `<key> reset unknown — no server value and no anchor to reconstruct from` | **`seven_day` only** — same exhausted chain, but no persisted anchor either (a cold start that has never spent a token). Nothing is invented: `resets_at` stays empty and both surfaces say the reset time is unknown |

## `Sources/TokenPaceKit/PollingEngine.swift`

One log line per interval change. The format is built by
`IntervalDecision.logMessage` (line 170): `interval <from>→<to>: <phrase>`.

| Line | Category | Level | Message | When |
|------|----------|-------|---------|------|
| 514 | `lifecycle` | `.notice` | `interval <from>→<to>: <phrase>` | the polling interval moved; emitted once per change |
| 520 | `network` | `.notice` | `five_hour idle — no active session (resets_at absent)` | the 5h window flipped to session-idle (`sessionIdleTransition`); emitted **once per transition**, not every poll (ADR-0027) |
| 520 | `network` | `.notice` | `five_hour window active again` | the 5h window came back (idle → active); same call site, once per transition (ADR-0027) |
| — | `lifecycle` | `.notice` | `usage poll off — service status only` | the user turned the usage API off (ADR-0085); emitted **once per transition**, not every tick. From here the heartbeat still runs, but it carries only the status poll — no Keychain read, no usage request |
| — | `lifecycle` | `.notice` | `usage poll on` | the usage API was switched back on; same call site, once per transition (ADR-0085) |
| 526 | `network` | `.notice` | `five_hour idle suppressed — within reset grace` | the reset-boundary idle grace armed (`applyIdleGrace`, `idleSuppressedUntil` nil → non-nil); emitted **once per transition**, not every poll. Arms only when the previous window was active **and** the user was recently working (`claudeActive && utilFresh`, ADR-0045) — a genuine pause does not arm it |
| 526 | `network` | `.notice` | `weekly ratio N=<value> (<count> samples)` | the 5h↔7d exchange rate behind the weekly reconstruction moved materially. Emitted **only on change** — on the first real estimate and thereafter when the rolling median shifts by ≥ 5 %. A shifted N is the only observable trace of a changed plan or an Anthropic promotion, since the payload announces neither |
| 526 | `network` | `.notice` | `weekly interpolation degraded — polling gap` / `weekly interpolation recovered` | the reconstruction lost trust in its accumulation because a poll gap exceeded twice the observed cadence, or regained it on the next healthy poll; one call site emitting one of two strings, **once per transition** |
| 614 | `keychain` | `.notice` | `token expired, len=<count>` | `pollOnce` — the read credentials are expired (`isExpired` true) (ADR-0020) |

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
| `network` | 31 | `UsageClient` (6), `GitHubReleaseClient` (6), `StatusClient` (5), `PollingEngine` (4), `UsageSnapshot` (3), `UpdateInstaller` (3), `GitHubRelease` (1), `GHReleaseFetcher` (1), `App` (1) |
| `keychain` | 12 | `ClaudeCLIRefresher` (6), `TokenProvider` (3), `PollingEngine` (1) |
| `lifecycle` | 118 | `App` (48), `SettingsModel` (27), `UpdateInstaller` (13), `PollingShell` (7), `PersistedConfig` (6), `BackToWorkNotifier` (6), `AwaitingInputWatcher` (5), `SettingsWindowController` (2), `PollingEngine` (2), `ShellEnvironment` (1), `IncidentNotificationDelegate` (1) |
| `ui` | 1 | `AppearancePane` (1) |
| `archive` | 7 | `App` (5), `LogArchiver` (2) |
| `journal` | 18 | `UsageJournal` (10), `StatusPayloadLog` (4), `App` (3), `DevToolsWindowController` (1) |

**Total: 188 log statements** — `.error` ×50, `.notice` ×120, `.info` ×13, `.debug` ×5.

> Regenerate with: `grep -rho 'AppLogger\.[a-z]*\.' Sources/ | sort | uniq -c`. The per-file column
> is a straight readout of that command, not arithmetic on a previous count — recounting by delta has
> repeatedly drifted from the source.

The `journal: enabled set <bool>` toggle line (`SettingsModel`) is a `lifecycle` statement, counted
under `lifecycle`. The `five_hour idle …` / `window active again` pair and the `usage poll off/on`
pair are each one call site emitting one of two strings, counted once. The weekly-reconstruction
lines log only on change, not per poll (~341/day at the observed cadence) — the per-poll value goes
to the usage journal instead, where it's a series to analyse rather than a line to scroll past.
