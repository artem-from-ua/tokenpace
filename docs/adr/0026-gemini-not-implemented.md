---
status: accepted
date: 2026-07-24
---

# ADR-0026: Not implementing Gemini — no ToS-compliant path to the consumer metric

## Context

Epic #60 investigates extending TokenPace beyond Anthropic to other vendors with **usage windows**
(rolling N-hours / week). The first target chosen was **Gemini** (#93) — we have a tester with a
subscription (@kintecus), so the investigation was done on his Mac with his credentials.

The investigation question: can we read Gemini's limits **locally, read-only, without scraping**, the
same way we read them for Claude Code, and how to safely refresh the token.

The feature's premise **was confirmed**: consumer Gemini, as of 2026-05-20 (Google I/O), has a
**5-hour rolling + weekly** window, modeled after ChatGPT/Claude
([support.google.com/gemini/answer/16275805](https://support.google.com/gemini/answer/16275805) —
"Your limit refreshes every 5 hours until you reach your weekly limit"). The limits are
**compute-based** and dynamic: Google only publishes multipliers per tier (AI Plus 2×, Pro 4×,
Ultra 5×/20×), not absolute numbers, and they "may change without notice." Viewable only in the UI:
`gemini.google.com` → Settings → Usage Limits. **There is no official API to read your own consumer
usage.**

The investigation found **two independent planes** of access, and neither delivers "correct metric +
ToS-compliant + reliable" simultaneously.

### Plane A — OAuth / Code Assist (`retrieveUserQuota`)

The token-authorized path that **gemini-cli itself** uses
([google-gemini/gemini-cli](https://github.com/google-gemini/gemini-cli), verified against source):

- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
  (`packages/core/src/code_assist/server.ts`); the response is `buckets[]` with `remainingFraction`,
  `resetTime`, `modelId` (`types.ts`) — formally ideal for pacing.
- Authorization is a `Bearer` OAuth `access_token` from `~/.gemini/oauth_creds.json` (0600 plaintext)
  or the newer Keychain item `gemini-cli-oauth`/`main-account`. `expiry_date` is an epoch in ms.
- The `/stats` command (alias `/usage`) shows remaining/limit/reset per model.
- **Important: the `refresh_token` is NOT rotated** on refresh (google-auth-library's
  `oauth2client.ts:878` unconditionally writes the response back with the old token; gemini-cli also
  keeps the old one on save). That means an independent refresh from TokenPace's side **would not
  break** the gemini-cli session — this removes the main concern from the plan (step 5). A race is
  only possible on **write-back**; reading is safe.

**But plane A reads the "wrong" counter.** `retrieveUserQuota` returns the **Code Assist / CLI agent**
quota (per-model buckets + Google One credits), not the app's consumer counter. gemini-cli **never**
touches `gemini.google.com` (0 mentions in the repo). gemini-cli's maintainer states outright that
even inside the CLI itself "there's no way … to see your daily quota — at least, not yet." What's
more, `v1internal` is an **undocumented, unsupported** endpoint (in practice it returns
403/SERVICE_DISABLED), so even by itself "a documented means" isn't satisfied.

### Plane B — consumer cookie replay (`jSf9Qc` batchexecute)

The only path to the **correct** metric (web/app 5h + weekly). An end-to-end experiment
(@kintecus, on his Mac) confirmed it technically **works**: decrypt the Chrome cookie with the
`Chrome Safe Storage` key from the Keychain → extract `__Secure-1PSID`/`__Secure-1PSIDTS` → scrape
`SNlM0e`/`bl`/`f.sid` from the `gemini.google.com/usage` page → replay the internal RPC
`batchexecute?rpcids=jSf9Qc`. `fraction` matched the UI to the percentage point, `reset_epoch`
matched to the minute, separately for the 5h and weekly windows.

**But this path loses on every axis:**

- **ToS.** The Gemini Apps Help says outright: "The Google Terms of Service and the Generative AI
  Prohibited Use Policy apply to Gemini Apps." Google's ToS "Don't abuse our services" forbids
  "using automated means to access content," "bypassing our systems or protective measures,"
  "reverse engineering our services." The Google APIs ToS: "You will only access an API by the means
  described in the documentation of that API." Cookie-replaying an internal RPC falls under **all**
  of these clauses at once.
- **Risk of account suspension.** The maintainers of reverse-engineered clients
  (`dsdanielpark/Bard-API`, `dsdanielpark/Gemini-API`) **themselves** warn: "excessive or commercial
  usage may result in restrictions on your Google account." We found no documented primary-source
  case of a *permanent* ban purely for read-only cookie replay (only warnings + temporary
  rate-limit/CAPTCHA), but the absence of evidence isn't evidence of safety.
- **Fragility.** `__Secure-1PSIDTS` rotates every ~10–20 min (clients force-refresh it); Google
  rotates the RPC id (`jSf9Qc` etc.) without notice; running the client can **invalidate the user's
  own** browser session in Gemini. The Chrome cookie decryption mechanics are also "inherently
  brittle across Chromium changes" (comment in `SweetCookieKit`).
- **No prior art.** The closest analog to TokenPace, **CodexBar** (steipete, ~18.9k⭐, MIT), reads
  Gemini through **plane A** (OAuth/Code Assist), Antigravity through local `127.0.0.1` probing;
  its cookie mechanics (`SweetCookieKit`) apply **only to Claude and Cursor, never to Gemini**.
  Everyone who reads consumer cookies is a **full chat client**, none is a read-only usage reader.
  So the `jSf9Qc` usage path is **net-new reverse engineering** of an internal RPC, with no base to
  lean on.

## Decision

**We are NOT implementing Gemini for now.** The main argument is the **risk of our users' Google
accounts being suspended**: the only path to the correct (consumer) metric — plane B — directly
violates Google's ToS, and the maintainers of related tools themselves warn about possible account
restrictions. That risk is unacceptable for an app operating on real user accounts, all the more so
without an official API, a stable contract, or prior art.

We're also not taking plane A (OAuth/Code Assist): it **reads a different counter** (the CLI agent's
quota, not the app's), so it doesn't deliver the promised feature, and it itself relies on the
undocumented `v1internal`.

This decision is **about Gemini only**, not about multi-vendor support in general. Direction #60
stays alive — **the next candidate is OpenAI Codex** (5h + weekly window, local token in
`~/.codex/`), which needs to be investigated in a separate ticket following the same investigation
playbook.

## Consequences

- #93 closes as *not planned* with a summary verdict; #60 (the multi-vendor epic) stays **open** —
  Codex is still ahead.
- The vendor abstraction (provider = endpoint + auth source + usage decode + window model) sketched
  out in #60 is **not built now** — it will be introduced by whichever vendor actually clears the
  investigation (likely Codex).
- If Google ever **officially** opens an API for consumer usage, this decision gets revisited; until
  then the cookie-replay channel is closed by design.
- A positive technical takeaway for *any* future OAuth vendor: if its CLI doesn't rotate the
  `refresh_token` (like gemini-cli), a delegated refresh isn't mandatory — an independent, read-only
  refresh is possible and safe (compare the delegated approach for Claude,
  [ADR-0017](0017-delegated-token-refresh.md)).

## Related

- [ADR-0017](0017-delegated-token-refresh.md) — delegated token refresh (Claude); this ADR records
  that for gemini-cli, an independent refresh would have been safe (`refresh_token` isn't rotated).
- [ADR-0019](0019-token-read-via-security-cli.md) — reading secrets through the `security` CLI; a
  similar Keychain access would have been needed for gemini-cli credentials too, had we gone with
  plane A.
- #60 — the multi-vendor epic (stays open, next candidate is Codex).
- #93 — the Gemini investigation (closed by this decision).
