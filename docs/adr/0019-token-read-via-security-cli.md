---
status: accepted
date: 2026-07-22
---

# ADR-0019: Reading the token through a `security` CLI subprocess (the partition list gets reset)

## Context

The symptom (July 2026, a notarized `.app` from /Applications): every time the token expires, macOS
shows the keychain prompts again (two per cycle), and "Always Allow" does not help — at the next
expiry the prompts are back. Between expiries, reading is silent.

Diagnosis against the live Keychain (a read-only ACL dump through `SecKeychainItemCopyAccess`):

- The `Claude Code-credentials` item is **not recreated**: `cdat` = 2026-01-21, while `mdat` updates
  on every refresh — Claude Code overwrites it in place. The "the name/object is different every
  time" hypothesis is false.
- The trusted-apps ACL holds **46 entries**, nearly all of them duplicates of TokenPace's dev and
  release binaries: every "Always Allow" click added an entry, and the entries persist — yet they do
  not help.
- The item's **partition list** contains only `apple-tool:`. Since macOS Sierra, silent access
  requires *two* conditions: the app in trusted apps **and** its code-signing partition
  (`teamid:S5A4U9798Y`) in the partition list. TokenPace's GUI builds never satisfy the second one
  for long:
- Claude Code reads and writes the item through `/usr/bin/security` (the CLI binary contains the
  strings `add-generic-password` / `find-generic-password` / `delete-generic-password`; the creating
  partition is `apple-tool:`; there is no node or claude in trusted apps at all). **A simulation
  confirmed the mechanism**: on a test item whose list was `apple-tool:,teamid:S5A4U9798Y`, calling
  `security add-generic-password -U` (exactly how CC updates the credentials) **resets the partition
  list to `apple-tool:`**. So every refresh (roughly every 8 hours) revokes the access the user
  granted.

Alternatives considered:

1. **A one-off `security set-generic-password-partition-list -S "apple-tool:,teamid:…"`** — works
   only until the next refresh (see the simulation above). Rejected.
2. **Caching the credentials in memory** — reduces the number of prompts, but the first read after
   each refresh still prompts. Rejected.
3. **Our own copy of the token in our own keychain item** — keeping the copy in sync means reading
   the original first → the prompt remains. Rejected.
4. **Reading through a `/usr/bin/security find-generic-password -w` subprocess** — the same channel
   Claude Code itself uses: `security` is an Apple tool, always inside the `apple-tool:` partition
   and (as the item's creator) in trusted apps, so it reads silently no matter how often CC
   overwrites the item, and regardless of how the TokenPace build is signed (ad-hoc `swift run`
   included). Chosen.

Where the change goes: `TokenProvider.readRawData()` (in the kit) — the single point of Keychain
reading, used by both polling (`KeychainTokenProvider`) and `ClaudeCLIRefresher` (its before/after
checks). The alternative, "a shell-side seam in the `TokenPace` target" (following
`ClaudeCLIRefresher`'s example), was rejected: it smears the change across two targets, requires
extending the `TokenProviding` protocol and injecting it into the refresher, and Phase 2 does not
reuse keychain reading anyway (iOS/watchOS get their data from CloudKit) — so "a kit free of
subprocesses" buys nothing practical.

## Decision

1. `TokenProvider.readRawData()` spawns `/usr/bin/security find-generic-password -s
   "Claude Code-credentials" -w` (a fixed binary path; matching on the service only) instead of
   `SecItemCopyMatching`. stdin → `/dev/null`, stdout/stderr into a pipe (stderr is never logged — it
   may contain the item's attributes). A hard 10 s timeout (`SIGTERM`).
2. Pure processing, unit-tested: `parseSecretOutput` (trimming a single trailing newline, plus a
   defensive hex decode — `-w` hex-encodes non-text secrets; the JSON wrapper starts with `{` and does
   not collide with hex) and `mapExitStatus` (exit 44 → `.itemNotFound`, verified empirically; other
   codes → `.keychainError(code)`).
3. `TokenError` does not change (it is a public enum with an exhaustive switch in `FailureReason`):
   `.accessDenied` is no longer produced by the new path but stays; `.keychainError` now carries the
   tool's exit code or the local sentinels `-1` (spawn failed) / `-2` (timeout).
4. ADR-0017's policy is unchanged: TokenPace **never writes** to the Keychain; the refresh is still
   delegated to the `claude` CLI.

## Consequences

- **(+) The prompts are gone for good** — for the notarized build, for dev builds and for any future
  build; no one-off partition-list rituals. Verified on an ad-hoc dev binary: reading is silent, with
  `usage 200 ok` about 300 ms after launch.
- **(+)** Issue #20 (a pre-auth UX dialog before the first keychain prompt) loses its subject — there
  is no prompt any more; #21 (checking the ACL on signed versus unsigned builds) is closed by this
  investigation.
- **(−)** A second subprocess spawn in the codebase, and this one in the kit (a departure from "spawn
  only shell-side", recorded in ADR-0017) — deliberately, see the Context.
- **(−)** A dependency on the output format of `security -w` (plaintext plus `\n`, hex for binary
  data) — covered by `parseSecretOutput` and its tests; a format change breaks reading demonstrably
  (`malformedData`), not silently.
- **(−)** A synchronous call with a 10 s timeout: in a pathological case (a locked keychain) the
  polling thread blocks until the timeout; normally it is tens of milliseconds.
- The secret travels through the subprocess's stdout pipe inside the TokenPace process — not in
  arguments, not in the environment, not in logs (only the exit status and a byte count are logged).
