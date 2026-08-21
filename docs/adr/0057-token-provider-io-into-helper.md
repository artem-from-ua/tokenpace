---
status: draft
date: 2026-08-01
---

# ADR-0057 (draft): Moving `TokenProvider`'s I/O half into the helper

> **Draft.** Gated on #E0. Clarifies how `TokenProvider` splits at the boundary from
> [ADR-0056](0056-thin-helper-thick-app-build-flavors.md), and that the
> [ADR-0019](0019-token-read-via-security-cli.md) mechanism carries over unchanged.

## Context

`TokenProvider` reads **someone else's** Keychain item `Claude Code-credentials` (created by the
Claude Code CLI). [ADR-0019](0019-token-read-via-security-cli.md) requires doing this by
**spawning `/usr/bin/security`**, not `SecItemCopyMatching`: on every refresh, Claude Code rewrites
the item via `security add-generic-password -U`, which resets the ACL partition list to
`apple-tool:` — a direct API read after that prompts. Spawning `security` (itself in the
`apple-tool:` partition) stays silent.

Both spawning a binary and reading someone else's Keychain item are **forbidden by App Sandbox**.
So this work physically cannot live in the MAS app — it has to live in the non-sandboxed helper
([ADR-0054](0054-mas-present-if-installed-helper.md)).

But `TokenProvider` **already has a purity split** (ADR-0019, ADR-0007): the pure part (`decode`,
`parseSecretOutput`, `mapExitStatus`, `OAuthCredentials`, `TokenCredentials`) is separated from I/O
(`readRawData`, which spawns `security`).

## Decision

Split `TokenProvider` along its existing purity seam:

- **The pure half stays in `TokenPaceKit`** — `decode`, `parseSecretOutput`, `mapExitStatus`,
  `OAuthCredentials`, `TokenCredentials`, `TokenError`. Unit tests don't move.
- **The I/O half (`readRawData` + the `security` spawn) moves into `TokenPaceShellIO`** (linked
  only by the helper/DevID — [ADR-0056](0056-thin-helper-thick-app-build-flavors.md)).

**The ADR-0019 mechanism doesn't change** — the same spawn of
`security find-generic-password -s "Claude Code-credentials" -w`, the same reason (the ACL
partition reset). Only the **host process** changes: from the app to the helper. Likewise,
delegated refresh ([ADR-0017](0017-delegated-token-refresh.md)) — the `claude` spawn — now lives in
the helper.

```plantuml
@startuml
title ADR-0057: The token read/refresh cycle inside the helper
skinparam sequenceArrowThickness 1.5
skinparam LifeLineBorderColor #C0C0C0

participant "PollingEngine\n(helper)" as Engine #F3E8FD
participant "TokenProvider I/O\n(ShellIO)" as TP #FDE8E8
participant "/usr/bin/security" as Sec #F5F5F5
participant "claude CLI" as CLI #F5F5F5
participant "usage API" as API

Engine -> TP : currentCredentials()
TP -> Sec : spawn find-generic-password
Sec --> TP : raw secret
TP -> TP : decode (pure, in the kit)
TP --> Engine : TokenCredentials

alt token expired
  Engine -> CLI : spawn claude --safe-mode -p /usage\n(delegated refresh, ADR-0017)
  CLI --> Engine : Claude Code rewrote the item
  Engine -> TP : currentCredentials() again
  TP -> Sec : spawn (silent: apple-tool: partition)
  Sec --> TP : fresh secret
  TP --> Engine : fresh TokenCredentials
end

Engine -> API : authed request (Bearer)
note right of Engine
  Derived numbers → status.json.
  accessToken/refreshToken
  do NOT leave the helper.
end note
@enduml
```

![PlantUML Diagram](https://www.plantuml.com/plantuml/svg/TLJ1Rjf04BtlLuoI2qWn9ggY80vL4Y0I4YgeuPZBP3sOBSkkExk6vWVw0Vt4VabdRQE2qig71S-RcRVlpVWXHEHOxwsA9bg2n-dNR3Yykn_3UaiG_OuSC66HCssOmXRqknQOSS4K4XVCbcn5hCBEk0ePzn3eUqrEqoEpFwwtHkySXG2tWxipqC9iQ64SFNakY2VUUeRhoJ0zIWaa6cqgT16kLjvQuygPAmN-wdfjl_uLO83s9Lm_VvgDdgUNUUl4VSN-84GPvlbISbyasSwNRV9w9OdJsMWskapCwy3vct5v85spYUyD-eMqmE_ISmdN5ckHOhAODpWv_ush0vQYxwg5oQbKHp_xdBYCGRenkJXXAkGmQ4ElhoGYyTHz3A72euEDSKLMaYCsEgimXADeg18YErLYF8eDcYbs-StRWhGNfhsgPheH2nlxTYQsJGJLyH7latPdF9H26xjfe1-LaOW2-4i_NVf4hzCZom9kADkdZba5UNDziQ0WIoL6Ag2Rg9jkvcxl-r8pLRgWCkdaJNMOZknZEtOcqlw2mtyb12pHEC5-bB8NZ1NS6B2gB6NHUpk6nhLel4jyBcHjDw0JjgrtJhKDVz2EN75kjJWlMApb4aa3sPKGeVT4o3BLogNxiIct4VocAosjfcBsGV2kthyH1_ZzynV8viOw3Bu5xmO2GQrbpPhkfsLj_aYeyF1bkGPBU3ZVsK6Y1gcZUf1VyX7u0m00)

## Consequences

- **ADR-0019 still stands** — its decision and reasoning carry over unchanged; only which process
  performs the spawn changes. No postscript to ADR-0019 is needed (the mechanism is the same).
- **The token never crosses the boundary** ([ADR-0055](0055-ipc-file-darwin-bookmark.md)) — only
  the decoded `UsageSnapshot` goes upward, never `accessToken`/`refreshToken`.
- **TCC responsibility for spawning `claude --safe-mode`** now sits with the helper's process, not
  the app — behavior should be equivalent, but needs re-verification (part of #E3).
- Related: [ADR-0056](0056-thin-helper-thick-app-build-flavors.md) (exactly where the link boundary
  falls), [ADR-0017](0017-delegated-token-refresh.md) (delegated refresh),
  [ADR-0033](0033-automatic-update-install.md) / [ADR-0025](0025-check-for-updates.md)
  (updater/fetch — also helper-side).
