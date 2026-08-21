---
status: accepted
date: 2026-06-22
---

# ADR-0007: TokenProvider — `throws` plus an enum, a pure decoding layer, and splitting the scope of #8

> **Postscript (2026-07-06):** the **fallback refresh (PR 8b)** part — a standalone `refresh_token`
> grant plus a write-back into the Keychain through `SecItemUpdate` — has been replaced by a refresh
> delegated to the `claude` CLI. See [ADR-0017](0017-delegated-token-refresh.md). The rest of this
> ADR's decisions (the 8a/8b split, `throws` + `TokenError`, a pure `decode(from:)`, "an expired token
> never goes to the API") still stands — so the record as a whole is **not** obsolete and is not
> struck through in the index.

> **Postscript (2026-07-22):** §4, in the part about *where* the expiry decision is made, was refined
> by [ADR-0020](0020-troubleshoot-window-and-diagnostics-pipeline.md). The provider **no longer** throws
> `.expired`: `currentAccessToken(now:)` was replaced by `currentCredentials(now:) -> TokenCredentials`
> (the token plus `expiresAt`), and the expiry decision moved into `PollingEngine.pollOnce`. **The §4
> contract "an expired token never goes to the API" is preserved** — it is now the engine that
> guarantees it (one Keychain read per poll, with `expiresAt` available even for an expired token, for
> diagnostics). So the record is not obsolete and is not struck through in the index.

## Context

Issue #8 describes `TokenProvider` as "reading the OAuth token from the Keychain **plus a fallback
refresh**". Those are two pieces with very different risk profiles:

- **Reading, decoding and validity** — local, deterministic, touches no network and cannot harm a
  working token. The item's format is confirmed empirically (`security find-generic-password`):
  `class: genp`, `svce: "Claude Code-credentials"`, and a payload of JSON wrapped in `claudeAiOauth`
  (`accessToken`, `refreshToken`, `expiresAt` in **milliseconds**, `scopes`, `subscriptionType`,
  `rateLimitTier`); `acct` is the user name and is **system-dependent**.
- **The fallback refresh** — Phase 1's main technical risk (SPEC "Open questions", lines 270–273,
  287): `refreshToken` may be single-use and could **invalidate a live working token**, so it is only
  tested on a *test* Max account; the exact `client_id` / refresh endpoint / PKCE shape are **not
  confirmed**. Writing production code around unknown constants is premature.

Separately, the question of error style came up. The existing pure logic (`ResetClock.parse`,
`PacingModel`) returns optionals or clamped values, because there the **only** reason to fail is "it
does not parse". In `TokenProvider` there are several incompatible reasons (no item / ACL refused /
some other `OSStatus` / broken JSON / the token expired), and each leads to a **different reaction**
(explain "Always Allow" vs "launch Claude Code" vs wait for a fresh token).

This is the same class of module-boundary decision as
[ADR-0005](0005-pacing-fractions-not-blocks.md) and
[ADR-0006](0006-reset-time-absolute-vs-relative.md): we decide deliberately what the module does and
what belongs to the neighboring layer.

## Decision

1. **Split #8 into two PRs.** PR 8a (this one) — reading, decoding and validity; entirely pure,
   unit-tested, safe. PR 8b — the fallback refresh, after it is verified on the test account. 8a
   unblocks `UsageClient` (#9) immediately, without waiting for the risky network part.

2. **`throws` plus a typed `enum TokenError`** instead of an optional. The cases: `itemNotFound`,
   `accessDenied(OSStatus)`, `keychainError(OSStatus)`, `malformedData`, `expired`. `Result` was
   rejected: the project is asynchronous (UsageClient is async/await), and `throws` composes
   naturally with `async throws` without `.get()` wrappers.

3. **A pure `decode(from data:) throws` layer, separate from Keychain I/O.** All of the format
   parsing (the `claudeAiOauth` wrapper, `expiresAt` ms→`Date`, missing optional fields) is unit-tested
   without the Keychain — that is the core of the acceptance criteria. Keychain I/O
   (`SecItemCopyMatching`, matching **on the service only**) is a thin wrapper that maps `OSStatus` to
   `TokenError`; it is not unit-tested (manual verification).

4. **An expired token never goes to the API.** As long as there is no refresh (8a),
   `currentAccessToken(now:)` throws `.expired` and does **not** return the stale `accessToken` — that
   avoids a guaranteed 401 and pointlessly burning rate limit. The polling layer (#9/#13) treats
   `.expired` as "wait for a fresh token" and re-reads the Keychain periodically until Claude Code
   (once launched) overwrites the item. `TokenProvider` stays stateless and holds no timer.

## Consequences

- The safe part merges and unblocks #9 without being blocked by the risky refresh.
- The UI can tell the failure reasons apart (`accessDenied` → the "Always Allow" instruction;
  `itemNotFound` → "launch Claude Code"; `expired` → waiting) instead of a single faceless `nil`.
- `decode(from:)` is fully covered by unit tests (a valid payload, ms→Date, missing fields, no
  wrapper, garbage, empty data, `expiresAt` as a string); the "never hand back an expired token"
  contract is under test too, through `accessTokenIfValid(_:now:)`.
- The token is never logged: `AppLogger.keychain` carries only `.public` diagnostics (`OSStatus`, the
  token's length, the fact that it is `expired`).
- PR 8b will add `refreshAndStore` (async, with an injected transport), a pure `buildRefreshRequest`
  (testable: POST, `application/x-www-form-urlencoded`, `grant_type=refresh_token`) and a `writeBack`
  through `SecItemUpdate`, without rewriting 8a. If `refreshToken` turns out to be single-use, or the
  endpoint/client_id get pinned down — that is a new decision → a new section here or a separate ADR.
- Manually verifying the ACL dialog (on an unsigned build: does it appear once or repeat) stays
  outside the automated tests (acceptance for #8) and does not block merging the pure tests.
