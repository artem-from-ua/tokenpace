---
status: accepted
date: 2026-07-06
---

# ADR-0017: Delegated token refresh via the claude CLI

> **Clarified in #183 (2026-07-29):** isolating the spawned `claude` from the user's own hooks is
> provided by the `--safe-mode` flag, not by an empty working directory. An empty cwd only cuts off
> *project-local* context; global hooks/plugins/MCP from `~/.claude` still fired despite it — and
> raised a TCC prompt under the GUI app's identity (see Consequences). The body of this ADR remains
> as a historical record.

## Context

ADR-0007 split issue #8 into 8a (reading the Keychain, in `main`) and 8b (fallback refresh of a
stale token), and explicitly deferred 8b's mechanics: "if `refreshToken` turns out to be single-use,
or the endpoint/client_id get pinned down — that's a new decision → a separate ADR." The initial
plan for 8b — a standalone `refresh_token` grant plus overwriting the Keychain via `SecItemUpdate` —
was blocked by the main risk: it was unknown whether the refresh token rotates, and testing without
a spare Max account could have logged the working Claude Code session out.

Researching 11 comparable projects (recorded in comments on issue #8, 2026-07-06) resolved the
uncertainty:

- **Refresh-token rotation is a fact.** Both comparable projects doing self-refresh
  (victor-shammas, akitaonrails) write the rotated pair back into Claude Code's own storage as a
  hard requirement; two others (steipete/CodexBar, hunaczech) explicitly document avoiding
  self-refresh precisely because of the risk of desyncing the CLI.
- **A working alternative — delegation:** CodexBar, on a stale token, spawns `claude` in a PTY and
  waits for the Keychain item to change; victor-shammas spawns a bare `claude` as a fallback. The
  rotation itself is performed by Claude Code in its own Keychain — a third-party app doesn't need
  write-back.
- **A TokenPace spike** confirmed the `claude --model haiku -p '/usage'` command: `/usage` is
  handled by the CLI's local handler (zero calls to the model in the session transcript; an isolated
  utilization measurement before/after showed no change), exiting 0 in ~1.5 s. `--bare` doesn't
  work — with it the CLI never reads OAuth/Keychain at all. A bare `claude` without a TTY fails
  immediately (the auto-`--print` mode).

## Decision

1. **Refresh is delegated to Claude Code.** On `TokenError.expired` the polling loop spawns
   `claude --model haiku -p '/usage'` (stdin/stdout/stderr → `/dev/null`, an empty tmp directory, a
   30 s timeout with SIGTERM→SIGKILL escalation); CC itself rotates the pair in its own Keychain;
   success is measured by `expiresAt` having moved forward. After success, the token is re-read and
   the usage request runs **within the same** polling cycle.
2. **TokenPace stays strictly read-only with respect to credentials:** no `refresh_token` grant, no
   Keychain write, `refreshToken` is unused. The 8b scaffolding (`refreshAndStore`/
   `buildRefreshRequest`/`writeBack`) was removed.
3. **Seam and purity:** the kit gets a `DelegatedRefresher` protocol (fail-safe, never throws) and a
   pure `RefreshGate` — an anti-flap gate with cooldown escalation `1→5→30→60 min` after failures
   (in the style of `PollingBackoff`, table-tested). The production implementation,
   `ClaudeCLIRefresher`, lives in the shell (the first and only subprocess spawn in the codebase),
   locating the binary via fixed paths (launchd has a minimal PATH).
4. **UI:** `.expired` is no longer disguised as a synthetic HTTP 401 — it gets its own
   `FailureReason.tokenExpired` with an honest message ("Refreshing via the claude CLI — open Claude
   Code if this persists").

## Consequences

- A test Max account for 8b is **no longer needed** — the ticket's main blocker is lifted; the
  SPEC's open question, "is `refreshToken` single-use," is closed (no, it rotates).
- The write-back risk disappears (racing CC for the Keychain item, an ACL write-consent dialog from
  a signed bundle — part of #21's scope becomes moot for refresh).
- A new dependency: the `claude` binary being present at known paths. No binary → `.cliNotFound`, a
  warning in the popup, the gate throttles retries; the user is left to open Claude Code themselves.
- The spawned `claude` is visible to `ProcessClaudeActivityProbe` for a few seconds (an exact name
  match) — an acceptable blip: the probe is polled at the start of an iteration, and the subprocess
  finishes within it.
- `-p '/usage'`'s behavior is a contract with the CLI, not with the API: if a future CLI version
  changes the handling (say, stops refreshing on startup), only the fallback path breaks, and the
  `expiresAt` check honestly returns `.unchanged`; diagnosis happens via logs in the `keychain`
  category.
- End-to-end confirmation of refreshing a genuinely *stale* token happened on a natural expiration
  (overnight with CC closed); a spike against a fresh token can't confirm this (CC refreshes
  lazily).
- **The spawn is isolated by the `--safe-mode` flag** (added in #183): it disables the user's own
  hooks, plugins, MCP servers, and CLAUDE.md, while leaving auth, Keychain, built-in tools, and
  permissions intact — so refresh still works. Without it, the spawned `claude` runs the **user's
  global SessionStart hooks**; if a hook reads a file from a File Provider domain (iCloud/Dropbox/
  GDrive), TCC raises a prompt whose chain of responsibility points to the GUI app and displays it
  **under TokenPace's name** — which looks like the token counter spying on the user. An empty cwd
  doesn't save this (it only cuts off project-local context). `--bare` doesn't work (it skips
  Keychain reads). The minimum recommended CLI version is one that has `--safe-mode` (verified on
  v2.1.212, 2026-07-16); on an older CLI, the flag produces a non-zero exit → `.failed`, and refresh
  self-heals with the next `claude` update (no separate version fallback).
