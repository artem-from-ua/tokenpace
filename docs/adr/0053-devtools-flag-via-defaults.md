---
status: accepted
date: 2026-07-31
supersedes: [0052]
---

# ADR-0053: Gate dev-tools via `UserDefaults` (`defaults`), not an env var

## Context

`TOKENPACE_DEVTOOLS` (#185) unlocks the ⌥ "Development tools…" menu item and the live color tuner.
The flag was read from the process environment, so launching the installed `.app` from
Launchpad/Finder/at login made the item **not appear**: launchd starts the binary **without a
shell**, so `export TOKENPACE_DEVTOOLS=1` from `~/.zshrc` never reaches `ProcessInfo`.

[ADR-0052](0052-shared-prod-env-flag-resolver.md) tried to close this with a "shared resolver"
`ProdEnvFlag`, which fell back to the login shell (`zsh -l -i -c`) via `ShellEnvironment` and
cached the result asynchronously at startup. The mechanism worked, but turned out fragile: an
async subprocess on every launch, a dependency on the GUI process inheriting the correct `SHELL`,
and a race where "the flag resolves only after the first menu openings". Diagnosis showed that
even with correct reproduction, this was hard to keep reliable.

## Decision

Remove the env-based mechanism for dev-tools and store the flag as an ordinary setting in
`UserDefaults`, alongside the rest of the app's config (`PersistedConfig`, ADR-0023):

- **A new key `devToolsEnabled`** in `PersistedConfig` (`UserDefaults.standard`, domain = the
  bundle id `com.artem-n.tokenpace`). Default **off** (opt-in): `object(forKey:) as? Bool ?? false`
  — a missing key reads as `false`, distinct from an explicit `false`, following the convention of
  the rest of the opt-in toggles.
- **`ColorStore.devToolsEnabled`** is now `{ PersistedConfig.devToolsEnabled }` — a synchronous
  read from defaults, no shell probe, no warm-up. GUI/login launch honors the key the same way a
  terminal launch does.
- The env var `TOKENPACE_DEVTOOLS` is **no longer read at all**.
- Enabling: `defaults write com.artem-n.tokenpace devToolsEnabled -bool true` on the installed
  `.app`. There is no Settings toggle — this is a maintainer/dev switch (the menu item stays
  ⌥-gated on top of the flag).

`ProdEnvFlag` was removed (both of its consumers are gone). `TOKENPACE_GH_AUTH` reverts to its
standalone `AppDelegate.resolveGHAuth()` (`ProcessInfo` → `ShellEnvironment` login-shell fallback),
exactly as before ADR-0052 — that is, **ADR-0025 still stands unchanged**. `ShellEnvironment`
remains as the login-shell probe for `TOKENPACE_GH_AUTH`.

This formally **cancels ADR-0052** (#201).

## Consequences

- **Reliable and simple.** The gate is a synchronous `UserDefaults` read; no subprocess, race, or
  dependency on `SHELL` at GUI launch. Works the same for Launchpad/Finder/login and a terminal.
- **`defaults write … devToolsEnabled` only affects the installed `.app`.** The binary from
  `swift run` has no bundle id, so its `UserDefaults.standard` is a different domain. So
  **`TOKENPACE_DEVTOOLS=1 swift run` no longer enables dev-tools** — a deliberate trade-off: the
  dev tuner is now verified on the installed bundle (where it's actually needed live), while quick
  checks keep the stub variables (`TOKENPACE_STUB`, `TOKENPACE_OPEN_DEVTOOLS`), which are not
  themselves a gate.
- **`TOKENPACE_GH_AUTH` unchanged.** An `export` in `~/.zshrc` is still honored at login launch via
  `resolveGHAuth`/`ShellEnvironment` (ADR-0025).
- The flag is now persistent across launches (stays `true` until the key is removed), unlike the
  env var, which had to be set every time.
