---
status: accepted
date: 2026-07-06
---

# ADR-0018: Recovering launch-at-login after an update — `.notFound` is not terminal

## Context

[ADR-0012](0012-configure-window-and-launch-at-login.md) §4 ("Best-effort on unsigned" →
"Unavailability is visible, not silent") treats the `SMAppService.mainApp.status == .notFound`
status as **terminal**: no login item is registered for this code identity, so the "Launch at
login" checkbox in the Settings window is disabled (grayed out) and shows the hint "Unavailable in
this build… (not a developer build)." The reference case was `swift run` (a bare binary with no
bundle), where registration truly is impossible.

In practice, `.notFound` turned out to be **overloaded** — macOS returns it in two semantically
different situations (issue #69):

1. **`swift run` / a bare binary with no bundle** — registration is impossible. Disabling is
   correct.
2. **A legitimately signed (Developer ID) and notarized install in `/Applications`, whose BTM
   login-item registration was dropped along with the old bundle during an in-place update** —
   registration is possible and needed.

The two predicates together produced a bug:

- `isAvailable(.notFound) == false` → `SettingsWindowController.syncToggleFromSystem()` disabled
  the checkbox and showed "Unavailable…".
- `shouldRegisterOnFirstLaunch` fires only on `.notRegistered` →
  `App.registerLaunchAtLoginIfNeeded()` logged `status=notFound, no auto-register` and returned.
  There was no recovery path from the UI either.

**Consequence:** every app update permanently killed launch-at-login — the checkbox stayed gray,
with no way to recover from the interface. Evidence from the unified log (both versions, right
after the 2026-07-06 installs):

```
02:12:22 TokenPace (0.13.0, PID 50659): launch-at-login: status=notFound, no auto-register
13:22:43 TokenPace (0.14.0, PID 41449): launch-at-login: status=notFound, no auto-register
```

Neither a restart nor `lsregister -f /Applications/TokenPace.app` helped. There's no quarantine or
translocation involved (the process runs from the real `/Applications/…`), and `spctl` reports
`accepted (Notarized Developer ID)`.

The key difficulty: **the status alone can't let code distinguish** a dev build from a post-update
install — both produce `.notFound`. The project has no detection (and never had one) for "a signed
bundle in /Applications": that's fully delegated to `SMAppService`.

## Decision

1. **`.notFound` is no longer terminal by status. The `isAvailable` predicate is removed from the
   kit; checkbox availability is gated on the `.app` bundle, not on the status.** Since the status
   itself cannot distinguish "dev `swift run`" from "`.app` after an update" (both are `.notFound`),
   keeping this discrimination in the pure core is impossible — `isAvailable` is removed from
   `TokenPaceKit/LaunchAtLogin.swift`. Instead, `SettingsWindowController` gates
   `launchToggle.isEnabled` on `LaunchAtLoginController.isAppBundle`:
   - **`swift run` (not an `.app`)** → the checkbox is **grayed out/disabled**, with the hint
     "Unavailable in this build…" — exactly as in ADR-0012 §4. We don't auto-launch a dev build,
     and we don't let it be enabled from the UI.
   - **An `.app` bundle** → the checkbox is **always enabled**, including on `.notFound` (for an
     installed bundle this means the login item was dropped by an update); clicking calls
     `register()`, which restores it (#69).

2. **`register()` is the sole arbiter of "can we register."** We don't build a heuristic of
   "signed + in /Applications" for *capability*: path/signature inspection is fragile
   (translocation, `/Applications` vs `~/Applications`, symlinks, future sandbox changes), and it
   duplicates a decision `SMAppService.register()` already makes authoritatively. We let the side
   effect decide: clicking the toggle calls `register()`, and it either registers or throws.

   **A refinement to ADR-0012 §4's assumption** (discovered while verifying #69):
   `SMAppService.register()` on current macOS also registers an **ad-hoc-signed** `swift run`
   binary (Swift ad-hoc-signs `swift build`'s output with a stable code identity,
   `TokenPace-<hash>`). So "`swift run` is always `.notFound`, registration is impossible" is an
   inaccurate generalization: the dev binary registers under its own ad-hoc identity, separate from
   the `.app`'s Developer ID identity. The real cause of #69 is not "registration is impossible,"
   but that for the `.app` there's **no active BTM entry under its Developer ID identity**
   (`SMAppService.status` → `.notFound`), and the old code refused on `.notFound` regardless.

3. **Auto-register fires on `.notRegistered` **and** `.notFound`, but only inside an `.app`
   bundle.** The kit's predicate was renamed from `shouldRegisterOnFirstLaunch` to `shouldAttemptRegister`
   (the old name lied twice: it's not "first launch" — the call happens on every start, and it's
   not `.notRegistered`-only). A post-update start of the `.app` now self-heals: `.notFound` →
   `register()` restores the registration. Idempotency comes from the same status guard
   (`.registered`/`.requiresApproval` are left alone). We do **not** add a "first launch"
   persistence flag — it would have blocked exactly this recovery on a post-update start.

4. **Opt-out auto-register is gated on the `.app` bundle**
   (`LaunchAtLoginController.isAppBundle` — `Bundle.main.bundleIdentifier != nil &&
   bundleURL.pathExtension == "app"`). Since the ad-hoc dev binary **is registrable** (Decision §2),
   without this gate every `swift run` would silently register a login item pointing at a path
   under `.build/…` and clutter the user's Login Items (#69). The gate is a decision about
   **auto-action policy** (opt-out without consent is appropriate only for the production bundle),
   not about *capability* (which remains `register()`'s call). This bundle detection lives in the
   shell (`LaunchAtLoginController.isAppBundle`, next to the `SMAppService` glue), not in the pure
   kit — the same predicate also gates checkbox availability (Decision §1) and the "(dev build)" tag
   in the popup (Decision §6). On a dev build the checkbox is grayed out, so a manual click is
   unavailable too — launch-at-login is fully disabled on `swift run` (we don't auto-launch it
   anyway). An auto-register failure inside an `.app` bundle is unexpected (installed but
   unregistrable), so it's logged at `.error`; a click failure is `.error` too.

5. **The hint has three states** (`hintText(inAppBundle:)`): (a) not an `.app` (dev) → "Unavailable
   in this build…"; (b) `.app` + the last click threw (`lastToggleFailed`) → a recovery string
   ("Reinstall… or add manually…"); (c) otherwise → the neutral "Launch TokenPace automatically when
   you log in." The `lastToggleFailed` flag resets on a successful toggle and on a fresh `show()`
   (a state fixed in System Settings shouldn't stay masked by a stale failure), and it only matters
   when the checkbox is enabled (i.e., inside an `.app`).

6. **A dev build is tagged "(dev build)" in the popup.** The popup's first (bold) detail line shows
   `TokenPace (dev build)` on a `swift run` binary and `TokenPace` inside an `.app` — the same
   `isAppBundle` gate. This removes confusion when a dev build and an installed `.app` run at the
   same time and look identical in the menu bar.

## Consequences

- **Dev UX (`swift run`):** launch-at-login is fully disabled — auto-register on startup does
  **not** fire (the `.app` gate, Decision §4), so `swift run` no longer registers a login item
  pointing at `.build/…`, and the checkbox is grayed out/disabled (Decision §1), as in ADR-0012 §4.
  The popup's first line is tagged "(dev build)" (Decision §6). The #69 fix applies exclusively to
  the `.app` bundle and doesn't change dev behavior.
- **Cleaning up old dev entries:** before the gate, earlier `swift run`s (and the old name
  `cc-timer`) could have left BTM login items pointing at paths under `.build/…` or `~/.Trash/…`.
  These are removed by hand via System Settings → General → Login Items (user-space, a targeted
  removal; `sfltool resetbtm` doesn't fit — it wipes the entire BTM database). After the gate, new
  `swift run`s no longer create such entries.
- **Edge case: `register()` → `.requiresApproval` on `.notFound`:** this is real and is already
  handled on the click path — `toggleLaunchAtLogin`, after `enable()`, checks
  `needsSystemSettings` and directs the user to System Settings → Login Items. We don't navigate
  there on a background start (correctly so); the state stays `.requiresApproval` until the window
  is opened next.
- **Tests:** `isAvailable` was removed along with the `unavailableOnlyWhenNotFound` test; the
  auto-register test now expects `true` on `.notFound` (a regression guard for #69).
  `toggleState`/`needsSystemSettings` are unchanged. The `SMAppService` glue and the stateful hint
  are manual-verify by convention
  ([ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) § "Consequences").
- **To verify (manual):**
  - `swift run`: startup logs `not an .app bundle (swift run), skipping opt-out auto-register` — and
    **no** entry pointing at `.build/…` appears in BTM. The checkbox in Settings is clickable.
  - A signed and notarized `.app` in `/Applications` **after an in-place update** (bundle
    replacement): status `.notFound` → auto-register on the next start **restores** registration;
    the checkbox is active/on. This is **exactly the scenario ADR-0012's verification did not
    cover**: its note tested a fresh install (`.enabled`) and `swift run` (`.notFound`), but not a
    bundle replacement. Confirmed from the unified log (#69): five consecutive `.app` starts
    produced `status=notFound, no auto-register` before the fix.

## Related

- [ADR-0012](0012-configure-window-and-launch-at-login.md) — superseded in part §4 (the
  terminality of `.notFound`); the rest still stands.
- [ADR-0002](0002-ukrainian-documentation.md) — the documentation language.
- Issues: #14 (the initial launch-at-login implementation), #21 (signed-bundle behavior), #69 (this
  bug).
