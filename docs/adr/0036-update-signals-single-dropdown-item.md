---
status: accepted
date: 2026-07-25
---

# ADR-0036: Auto-update signals — a single dropdown item, no notifications; auto-install default-ON

> Complements [ADR-0025](0025-check-for-updates.md) (checking) and
> [ADR-0033](0033-automatic-update-install.md) (auto-install). **Supersedes the banner part of
> ADR-0025** (`UpdateNotifier` is removed) and **changes the default** of the
> `installUpdatesAutomatically` option (0033) from OFF to ON.

## Context

After implementing epic #125 (auto-install, #127/#128/#129), the feature works technically, but the
signal UX stayed **noisy**: three channels at once — a system macOS banner (`UpdateNotifier`), a blue
dot on the "New version available" menu item, and a row "Update available: vX.Y.Z — Download" in
Settings. The banner interrupted; the dot and the separate item multiplied signals about the same
thing.

The goal of #130 is to **interrupt and make noise as little as possible**. This is a **temporary**
solution pending the App Store (where updates are the store's concern), so no over-engineering (no
in-app rendering of release notes, no separate UI).

This raises decisions:

1. How many channels to keep and where.
2. How to show different contexts (a newer version exists / auto is OFF / deferred / already updated)
   with a single item.
3. What the auto-install default should be once the banner is removed.

## Decision

### 1. No system notifications

`UpdateNotifier` (the class + `UserNotifications` authorization + delegate) is **fully removed**.
This returns the project to the spirit of SPEC.md ("no macOS notifications"). The banner part of
ADR-0025 is superseded.

### 2. A single update item in the dropdown — a pure state machine

All non-critical signals are consolidated into a **single** item in the popup menu (above `Quit`,
behind its own separator). What changes is the **dot color**, the **text** — and, as of
[#415](https://github.com/artem-from-ua/tokenpace/pull/415), the **click target**: states 1–3
(something to do) open **Settings → About**
([#210](https://github.com/artem-from-ua/tokenpace/pull/210)), state 4 (`whatsNew`) opens
`GitHubReleaseClient.releaseNotesURL(tag:)` directly in a browser. The initial version of this ADR
sent **all** states to `releasesPageURL`; both changes left the item with no in-app markdown. The
priority table:

| Priority | Condition | Dot | Text |
|---|---|---|---|
| hidden | no newer version AND no unseen what's new | — | (absent) |
| 1 | newer version + auto-install failed on this tag | 🔴 | `New version available (update failed)…` |
| 2 | newer version + auto **OFF** | 🔵 | `New version available…` |
| 3 | newer version + auto **ON** + deferred (battery/metered/disk) | 🔵 | `Update pending…` |
| 4 | installed = latest, a successful update not yet seen | 🔵 | `What's new in the version…` |

**Preemption:** any version newer than the installed one (1–3) preempts "what's new" (4) — i.e., (4)
only applies when installed = latest. The case "didn't click what's new, and an even newer version
already shipped" → shows only `New version available`.

During an active download/verify (auto ON, newer, not deferred, not failed), the item is **hidden** —
the update happens quietly, and the item reappears as `whatsNew` after a restart (or as
`updateFailed`).

**The pure/shell split (ADR-0009):** choosing the winning state is a pure `UpdateMenuState.evaluate(...)`
in the kit (unit-tested), which returns a semantic `Item` enum. **Color and text live in the view**
(`AppDelegate`), like `ServiceStatus.word`/`dotColor`: the kit says *what* the item means, the view
says *how* it reads. The color is drawn from the existing `PopupViewController.dotColor` — so the
update dot uses the **same** colors as the service-status dots (🔴 = `.majorOutage`, 🔵 =
`.underMaintenance`).

### 3. Auto-install — default-ON (opt-out)

With the banner removed, **the least intrusive channel is a quiet background update with a restart**.
So `installUpdatesAutomatically` became **default-ON** (the `object(forKey:) as? Bool ?? true` idiom,
like `automaticUpdateChecks`). The full flow still requires a real `.app` in `/Applications` — in dev
the checkbox remains disabled+hint (0033). This changes 0033's default, but not the install mechanism.

Persistence (new in `PersistedConfig`):

- `pendingWhatsNewVersion: String?` — set **before the restart** in `startInstall` (a successful
  install ends with a relaunch+terminate *inside* `install()`, so the marker has to be on disk before
  the new build starts and shows state 4). Cleared: (a) by clicking the item, (b) when a version newer
  than the installed one appears (preemption).
- `lastFailedInstallVersion: String?` — set on an install failure; gates retrying for **this specific**
  tag (state 1, red). A newer version is still tried (the state machine only matches the current
  latest).

### 4. Dot alignment

The update dot in the menu **and** the service-status dots in the popup are raised to the optical
center of the text (cap-height), not the baseline — via the shared helper
`PopupViewController.dotAttachment(...)` through `NSTextAttachment.bounds`. Previously the symbol
attachment sat low; now both are aligned the same way, matching the menu-bar widget's own dot.

## Consequences

- **One channel in the menu** instead of three signals; no more banners. The Settings row "Update
  available — Download" remains as a separate channel in the settings window (not "noise" on screen).
- **Test boundary (ADR-0009):** `UpdateMenuState` (all 4 priorities + preemption + the retry gate) is
  covered by unit tests; rendering the item / alignment is verified by hand on a live build.
- **Verification stub** `TOKENPACE_UPDATE_STATE=failed|available|pending|whatsnew` forces the item's
  state without a real release/failure (writes only to memory, not `UserDefaults`) — joining the
  `TOKENPACE_STUB`/`TOKENPACE_FAKE_LATEST` family. Recorded in `CLAUDE.md`.
- **Limitation:** full auto-install (state 4 after a restart, state 1 after a failure) only works on a
  notarized `.app` from `/Applications`; on `swift run` it's a no-op, states are checked via the stub.

## Related

- [ADR-0025](0025-check-for-updates.md) — checking for updates; **the banner part is superseded** by
  this ADR (`UpdateNotifier` removed); the fetch path / `SemanticVersion` / cadence remain.
- [ADR-0033](0033-automatic-update-install.md) — the auto-install mechanism; this ADR **changes its
  default** (OFF → ON) and adds signal markers (`pendingWhatsNewVersion`/`lastFailedInstallVersion`).
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — pure core / thin shell, along which
  `UpdateMenuState` (kit) and rendering the item (view) are split.
- [ADR-0024](0024-configurable-logical-services.md) — `ServiceStatus`/`dotColor`, whose palette the
  update dot reuses.
