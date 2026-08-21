---
status: accepted
date: 2026-07-25
superseded_by: [0036]
---

# ADR-0033: Automatic update install — a custom minimal installer, not Sparkle

> **Partially superseded by [ADR-0036](0036-update-signals-single-dropdown-item.md).** The install
> mechanism (installer, verify, atomic replace, defer gates) still stands, but **the option's default
> changed from OFF to ON** (a quiet background update is the least intrusive channel once the banner
> is removed), and the signal UX (banner / menu item / "Download") is consolidated into a **single**
> dropdown item with a state machine (`pendingWhatsNewVersion`/`lastFailedInstallVersion`). Read about
> the signals and the default in 0036; mentions of "default-off" and "banner" below are historical.
>
> Complements [ADR-0025](0025-check-for-updates.md) (checking for updates), **not a replacement** for
> its fetch path.

## Context

ADR-0025 added a **check** for updates, but not installation: when a newer tag is found, TokenPace
shows a banner, a menu item with a blue dot, and a row "Update available: vX.Y.Z — Download" in
Settings, and a click opens the release page. Replacing the `.app` is done **manually** by the user —
downloading the notarized `.zip`, unpacking it, dragging it into `/Applications`.

Ostap (@kintecus) suggested adding an optional **auto-install** — an "Install updates automatically"
checkbox, behind which TokenPace carries the update through to completion itself. The epic is
[#125](https://github.com/artem-from-ua/tokenpace/issues/125), the phases are
[#122](https://github.com/artem-from-ua/tokenpace/issues/122),
[#123](https://github.com/artem-from-ua/tokenpace/issues/123),
[#124](https://github.com/artem-from-ua/tokenpace/issues/124).

The key decision is **how** to install. Replacing the running executable bundle is a privileged
operation with a significant attack surface, so this raises questions: write a custom installer or
adopt Sparkle (the de-facto standard for non-App-Store auto-update); how to guarantee the downloaded
bundle is really ours; how to make the replacement atomic; how to avoid breaking the existing
pure-core / thin-shell split and the zero-dependency policy.

## Decision

### 1. A custom minimal installer, not Sparkle

We chose a **custom** installer. Comparison:

| Criterion | Custom | Sparkle |
|---|---|---|
| Runtime dependency | none (only the system `codesign`/`spctl`/`ditto` + `URLSession`) | the first third-party dependency in `Package.swift` |
| Appcast | not needed — the source already exists (GitHub Releases API through `GitHubReleaseClient`, including the private-repo `gh` path) | needs an `appcast.xml` + its hosting |
| Update signing | uses the existing Apple chain (notarization + Developer ID) that already signs the release artifact | separate EdDSA keys, parallel to notarization |
| ADR compliance | keeps pure-core/thin-shell (ADR-0009/0023), the closed-agent boundary (ADR-0003) | pulls in external UI/logic, bypasses the decision-seam approach |
| UI | our own native banner/Settings row | Sparkle's own UI (conflicts with the existing one) |

Sparkle would deliver atomic replace / relaunch / delta updates "out of the box," but the price — the
first external dependency, separate appcast hosting, a second key system, and someone else's UI — is
excessive for a single menu-bar app that already has half the infrastructure in place
(`UpdateFetcher`, `GitHubReleaseClient`, `SemanticVersion`, cadence, a Settings section). A custom
installer reuses **Apple's chain of trust** instead of a custom PKI and adds no dependencies — that's
the deciding advantage.

### 2. The pure-core / thin-shell split

All branching logic lives in `TokenPaceKit` (pure, tested); all I/O lives in the thin shell:

- **Kit (pure):** `GitHubRelease.assets[]` (an extended decoder, `browser_download_url`);
  `UpdateAssetSelector.selectZIP(from:)` — selecting the version-named `.zip` asset with an
  HTTPS guard; `UpdateInstallPlan.decide(release:currentVersion:isAppBundle:autoInstallEnabled:)` —
  reducing all the "install now?" conditions to a single verdict (`.install` / `.skipNotNewer` /
  `.skipNoAsset` / `.skipNotAppBundle`).
- **Shell (I/O):** `UpdateInstaller` behind a protocol seam + a stub — `download` (two paths:
  `gh release download` under `TOKENPACE_GH_AUTH` for the private repo, otherwise an anonymous
  `URLSession`), `verify` (`codesign`/`spctl`/Team ID subprocesses, like `GHReleaseFetcher`), `unzip`
  (`ditto -x -k`), `replaceInstalled` (`FileManager.replaceItemAt`), `relaunch`
  (`NSWorkspace.openApplication` + `NSApp.terminate`).

This is the same split as `ArchiveSyncPlan` (pure) / `LogArchiver` (I/O) in ADR-0031.

### 3. Security invariants (mandatory)

1. **HTTPS-only** — a non-`https` `browser_download_url` is rejected already at the pure asset
   selection stage.
2. **Verification before replacement** — `codesign --verify --deep --strict` + checking the **Team ID
   `S5A4U9798Y`** (the main defense against tampering: even a validly signed but foreign bundle is
   rejected) + Gatekeeper `spctl --assess --type execute` (notarization/stapling).
3. **Downgrade/replay guard** — install only when `UpdateComparison.isNewer` == true; an equal/older
   version → a no-op (already the `checkForUpdate` contract, and the auto-install branch doesn't
   bypass it).
4. **Atomicity** — the new bundle is fully unpacked and verified in a tmp location *before* a single
   atomic `replaceItemAt` with a backup name. An interrupted download/unzip never touches
   `/Applications`; an interrupted swap leaves either the whole old or the whole new `.app`, never a
   broken one.
5. **Permissions on `/Applications`** — if writing isn't possible (bundle/folder owned by root) →
   error + fallback to a manual Download. A privileged helper (SMJobBless) is **deliberately out of
   scope for MVP**, a separate future ticket.
6. **Relaunch safely** — only after a successful replace; if launching the new bundle fails, the
   current process is **not** terminated (the new one is already on disk, the next launch will pick
   it up).
7. **Private repo → download via `gh`** — the repo is currently private, so an anonymous
   `browser_download_url` returns 404. When `TOKENPACE_GH_AUTH` is set, the asset is downloaded via
   `gh release download` (the maintainer's local credentials), the same as reading the release JSON
   in `GHReleaseFetcher`. A public repo → an anonymous `URLSession`.

### 3a. Environment defer gates (install only)

Three environment conditions defer **installation** (not the check — that runs on its own 12-hour
cadence regardless): **free space** (after download there must be ≥ 5 GB left,
`minFreeBytesAfterDownload`), **AC power** (don't download/replace on battery — risk of running out
of power mid-replace), **unmetered network** (don't spend ~MB on a capped connection). These are
`defer…` verdicts (not `skip`): the update is valid, it's just waiting for better conditions, and the
**next heartbeat re-evaluates it** — there's no state to persist. The facts (`DiskSpace`,
`PowerSource`, `NetworkMonitor.isMetered`) are read in the shell and injected into the pure
`UpdateInstallPlan.decide`. A **forced run** (dry-run) bypasses AC/metered — the maintainer explicitly
requested this — but **not** free-space (no intent makes filling up the disk safe).

### 4. Gate on a real `.app` + opt-in default-OFF

Every installer path is gated on `LaunchAtLoginController.isAppBundle` — the same real-`.app`
discriminator already used by `UpdateNotifier` and launch-at-login. `swift run` → a full no-op. The
`PersistedConfig.installUpdatesAutomatically` option is **opt-in, default-OFF** (the
`object(forKey:) as? Bool ?? false` idiom, like `archiveEnabled`); the Settings checkbox "Install
updates automatically" is **nested** under "Check for updates automatically" (auto-installing without
checking makes no sense) and enabled only when the parent is on **and** we're a real `.app` in
`/Applications`.

### 5. The asset name contract

The installer looks for a version-named notarized `.zip` — `TokenPace-<X.Y.Z>.zip` (the real release
artifact pattern; `build-app.sh` packages `TokenPace.zip`, and the version-named name is added in the
release process, see `docs/releasing.md`). This contract is pinned in `docs/releasing.md`, because the
pure `UpdateAssetSelector` relies on it.

### 6. Phasing (a strict order)

The trust surface grows gradually, each phase a separate PR after live verification:

- **Phase 1** (#122): the `assets[]` decoder + `UpdateAssetSelector` + `UpdateInstallPlan` + the
  opt-in key and the nested checkbox — **nothing is replaced**, only the verdict is logged.
- **Phase 2** (#123): `download`/`verify`/`unzip` under a **dry-run** gate
  (`TOKENPACE_UPDATE_DRYRUN`) — downloads and verifies without replacing.
- **Phase 3** (#124): `replaceInstalled` + `relaunch` + the auto-trigger in `handleUpdateFound`.

## Consequences

- **A fallback always exists**: any failure (download / verify / unzip / replace / permissions) is
  logged and falls back to the existing signal banner + "Download" row. The feature is never worse
  than the existing signal behavior from ADR-0025.
- **Verification env stubs**: `TOKENPACE_UPDATE_DRYRUN` (Phase 2) and `TOKENPACE_UPDATE_TARGET`
  (Phase 3, to target a test copy outside `/Applications`) are added — joining the
  `TOKENPACE_STUB`/`TOKENPACE_FAKE_LATEST` family. Recorded in `CLAUDE.md`.
- **Environment limitations**: the full flow only works on a **notarized `.app` from
  `/Applications`**; `swift run` is a no-op. The test is destructive (it replaces and relaunches the
  app), so it's verified at multiple levels — dry-run → a test copy outside `/Applications` → a real
  pair of releases (see the issues).
- **Test boundary** (ADR-0009): the pure core (`UpdateAssetSelector`, `UpdateInstallPlan` with all its
  gates, the extended decoder) is covered by unit tests; the shell (`UpdateInstaller`) is verified by
  hand on a live `.app`. The full chain has been **verified live end to end**: a notarized build vN,
  a real release vN+1 → gh-download → verify (Team ID + Gatekeeper) → **atomic replace** of a test
  copy (via `TOKENPACE_UPDATE_TARGET`, outside `/Applications`) → **relaunch** into the new version;
  the replaced bundle stayed valid (`codesign`/`spctl` accepted).
- **Non-`/Applications` placement** and privileged replacement are deliberately out of MVP scope — a
  future ADR about an SMJobBless helper, if needed.

## Related

- [ADR-0025](0025-check-for-updates.md) — checking for updates, which this ADR complements (its
  signal part remains as a fallback); reuses `UpdateFetcher`/`GitHubRelease`/`SemanticVersion`/
  `UpdateComparison`/`GitHubReleaseClient`.
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — pure core / thin shell, along which
  `UpdateInstallPlan`/`UpdateAssetSelector` (kit) and `UpdateInstaller` (shell) are split.
- [ADR-0031](0031-session-log-archiver.md) — the same pure/shell split
  (`ArchiveSyncPlan`/`LogArchiver`) and the opt-in default-OFF idiom in `PersistedConfig`.
- [ADR-0023](0023-persisted-config-version-marker.md) — `PersistedConfig`, extended with the
  `installUpdatesAutomatically` key.
- [ADR-0004](0004-build-system.md) — `build-app.sh` (the notarized version-named `.zip`), the source
  of trust that `verify` relies on.
