---
status: superseded
date: 2026-07-31
superseded_by: [0053]
---

> **Canceled by [ADR-0053](0053-devtools-flag-via-defaults.md).** `ProdEnvFlag` was removed: the
> dev-tools gate moved from an env var to a `UserDefaults` key `devToolsEnabled` (`defaults`), and
> `TOKENPACE_GH_AUTH` reverted to its standalone `resolveGHAuth` (ADR-0025). The text below is a
> historical record.

# ADR-0052: A shared resolver for prod-visible env flags (`ProdEnvFlag`)

## Context

Several `TOKENPACE_*` env flags need to be visible to the app even on **login/GUI launch** — via
`SMAppService`, Finder, Dock, Launchpad — when launchd starts the `.app` binary **without a
shell**, so `export TOKENPACE_FOO=1` in `~/.zshrc` does **not** reach
`ProcessInfo.processInfo.environment`.

The first such flag was `TOKENPACE_GH_AUTH` (ADR-0025): resolved first from `ProcessInfo` (a
launch from a terminal / `launchctl setenv`), then — as a fallback — from the login shell's rc
files via `ShellEnvironment` (`zsh -l -i -c`). That way the maintainer only needs an `export` in
`.zshrc`, with no `launchctl setenv`/LaunchAgent.

When `TOKENPACE_DEVTOOLS` (#185, unlocks the ⌥ "Development tools…" menu item and the color tuner)
was meant to get the same convenience, it turned out that its gate `ColorStore.devToolsEnabled`
read **only `ProcessInfo`**. So `export TOKENPACE_DEVTOOLS=1` in `.zshrc` worked for `swift run`
(a terminal inherits env), but **not** for the installed `.app`, launched from Finder/at login —
unlike `TOKENPACE_GH_AUTH`. Symptom: "the Dev Tools menu doesn't appear under ⌥ in the notarized
app".

Instead of duplicating the `resolveGHAuth` logic once more, we build **one shared resolver** for
all prod-visible flags, so future cases can be added with a single line.

Two questions for this ADR: (1) a **single** point of resolution, and (2) **how not to block**
launch and the hot draw path, since `ShellEnvironment` is a subprocess (typically <0.5 s, capped at
5 s).

## Decision

### A single resolver — `ProdEnvFlag`

`enum ProdEnvFlag: String, CaseIterable` — a catalog of prod-visible flags (`.ghAuth`,
`.devTools`), where `rawValue` is the env variable's name. Adding a future flag = **one case**; no
new resolver or plumbing. Both `ColorStore.devToolsEnabled` and `AppDelegate.ghAuthEnabled` are now
thin wrappers over `ProdEnvFlag.isEnabled(_:)`; the standalone `resolveGHAuth` was removed.

### Resolution — `ProcessInfo` synchronously, a shell fallback warmed once off-main

`isEnabled(_:)` is **non-blocking**, safe from any thread (draw path, poll):

1. **`ProcessInfo` first** — synchronously, on every read. A launch from a terminal /
   `launchctl setenv` is honored instantly, at zero cost at startup.
2. **A login-shell fallback** via `ShellEnvironment` — a subprocess, so **never** on the hot path.
   It runs **once, off-main, at startup** in `ProdEnvFlag.warmUp`, and the result is cached (under
   an `NSLock`, a `nonisolated(unsafe)` dictionary). Synchronous reads **before** the warm-up
   completes only see `ProcessInfo`.

### Warm-up (`warmUp`) — early in `applicationDidFinishLaunching`, with a re-render callback

`warmUp(then:)` tries the shell only for flags `ProcessInfo` didn't cover, in
`Task.detached(.utility)`, then calls the completion on `@MainActor`. Called once, right at the
start of launch — in parallel with the rest of startup. The completion calls
`reRenderForCurrentTime()`, so any override-dependent redraw lands as soon as the probe resolves
the flag.

### The consequence for the "Development tools…" menu

Previously the item was created conditionally (`if devToolsEnabled`) once at startup — with an
async warm-up it would not exist if the flag resolves later. Now the item is created **always**
(hidden), and the `TOKENPACE_DEVTOOLS` gate is checked in `updateTroubleshootVisibility` on
**every** menu opening (along with ⌥). So it appears as soon as the warm-up resolves the flag,
without rebuilding the menu.

### Why not a sync resolve before the first render

A synchronous shell probe before the first draw would give a correct state from the very first
frame, but would add up to ~5 s (typically <0.5 s) to the **cold GUI startup for everyone** —
because the probe always runs when `ProcessInfo` is empty, even for users who have no
`TOKENPACE_*` at all. That's a startup regression for the sake of a dev feature. An async warm-up,
by contrast, never blocks startup; the cost is that dev-menu/overrides become active a fraction of
a second after launch (no effect for a regular user — the flags are always `false`).

## Consequences

- `export TOKENPACE_DEVTOOLS=1` in `~/.zshrc` now unlocks dev-tools in the installed `.app` too
  (Finder/login launch), just like `TOKENPACE_GH_AUTH` — with no `launchctl setenv`/LaunchAgent.
- One resolution path for all prod-visible flags; a future one is added with a single case in
  `ProdEnvFlag.all`.
- `devToolsEnabled` became a `var` (a wrapper) instead of a `static let` (a memoized probe) — the
  cost of a read stays cheap (an env read + a locked lookup), safe on the draw path.
- The log `env: <TOKENPACE_VAR> found in login shell env` (`.notice`, `lifecycle`) from `warmUp`
  replaces the previous `update: TOKENPACE_GH_AUTH found in login shell env` — now shared across
  all flags.
- `ShellEnvironment` (ADR-0025) stays unchanged as a low-level primitive; `ProdEnvFlag` is the
  policy layer on top of it (which flags, when to warm up, how to cache).
