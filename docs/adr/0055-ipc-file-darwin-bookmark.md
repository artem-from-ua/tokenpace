---
status: draft
date: 2026-08-01
---

# ADR-0055 (draft): The app↔helper IPC channel — file + read-write bookmark + Darwin notification

> **Draft.** Gated on the #E0 spike, which must prove this channel end to end (chiefly — that a
> read-write security-scoped bookmark survives an atomic `rename()`, and that Darwin notifications
> wake a sandboxed app under App Nap). The draft is the central decision of the split.

## Context

The MAS app ([ADR-0054](0054-mas-present-if-installed-helper.md)) is sandboxed; the helper is not.
They need to exchange data: the helper hands derived usage numbers **down**, and the app (per the
requirement that "all helper configuration comes from the UI") writes config and commands **up**.
So the channel is **bidirectional**.

Constraints (verified against Apple docs + DTS):

- **XPC/mach to a non-embedded helper** requires `temporary-exception.mach-lookup.global-name` —
  App Review is hostile to it. **Rejected.**
- **Loopback `127.0.0.1`** under sandbox returns `EPERM`. **Rejected.**
- **An App Group container** is impossible — the two sides have different Team IDs / provisioning
  (the helper is Developer ID, the app is MAS). **Rejected.**
- The only sandbox-legal way for the app to read/write outside its container is a **user-granted
  security-scoped bookmark** via `NSOpenPanel`.

The model is **not** synchronous RPC. It's an asynchronous file "mailbox" in both directions, and
that is **sufficient**, because the existing code is already an async push: the UI doesn't wait on
the engine, it sends `.manualRefresh` and separately receives the result through `apply(_:)`.

## Decision

Two JSON mailboxes in one folder owned by the helper (non-sandboxed), which the app reads/writes
through **one folder-scoped read-write security-scoped bookmark**:

- `~/Library/Application Support/com.artem-n.tokenpace-helper/status.json` — **helper→app** (raw
  usage numbers + health + version info + liveness). **The token, the refresh secret, and the
  contents of `~/.claude` are never serialized.**
- `.../config.json` — **app→helper** (a narrow config: 5 fields + an optional one-shot command).

Atomicity — `*.tmp` → `rename()`. Freshness is signaled via a **payload-free Darwin notification**
(`notify.h`): `com.artem-n.tokenpace.status-updated` (helper→app),
`com.artem-n.tokenpace.config-updated` (app→helper). Each side uses
`notify_register_dispatch` + a slow-timer fallback of 30 s (Darwin coalesces, it's not a queue).

Versioning is bidirectional: `schemaVersion` in `status.json`, `configSchemaVersion` in
`config.json`; a single source of truth — `IPCSchema.swift` in `TokenPaceKit`, which **both**
binaries compile against. Commands are not RPC: the app writes `command.id`, the helper executes
it and reflects the result in the next `status.json` + acknowledges via `ackedCommandId`.

```plantuml
@startuml
title ADR-0055: Bidirectional app↔helper IPC exchange
skinparam sequenceArrowThickness 1.5
skinparam LifeLineBorderColor #C0C0C0

actor User as U
participant "MAS app\n(sandboxed)" as App #E8F4FD
participant "Helper's folder\n(status.json / config.json)" as Dir #F5F5F5
participant "Helper\n(non-sandboxed)" as Helper #F3E8FD

== First run: granting access ==
U -> App : "Connect helper"
App -> App : NSOpenPanel → folder-scoped\nread-write bookmark (save it)

== Config down into the folder (app→helper) ==
U -> App : changes a setting
App ->> Dir : writes config.json (atomic)
App ->> Helper : notify: config-updated
Helper -> Dir : reads config.json
Helper -> Helper : applies it to the polling loop

== State back (helper→app) ==
Helper -> Helper : polls usage (token does NOT leave)
Helper ->> Dir : writes status.json (raw numbers, atomic)
Helper ->> App : notify: status-updated
App -> Dir : reads status.json
App -> App : computes pacing/severity + renders

legend right
  ->> async fire-and-forget (notify/write)
  the token never crosses the boundary
end legend
@enduml
```

![PlantUML Diagram](https://www.plantuml.com/plantuml/svg/RLJlJjim4F_kfpYL3skr1PYsIbEb8agxQfCsG0E-ySLrhgdNzCwp7KfVW0T0UqAUPESaT06XI54St_t-dPFJ4BMFrQPKqSOIOJBxbHqV3uSZEBEvzMYYPT8bQEUU7lwki7JeuVlb5F3Uh3GLgCBQajDURo3Wdmh9uCHxtbwlh5aJXW0V3uUTeXzsYJyiuHdx7FsKI_PmC3rEbrBQH5dU1E7G0MwKj4HhhDCKeVTpSfLat58_QCeNV8_ve9Vg9ix1mTSlyy_psSkERxNSTm6MN0fPwemwLk7mTs228p1CIrlKgmPfPaNCV9Ykjv04W9YoL_JDdlHz4WqpfSPZc5iV8lYAHb1u0R1KW3OcfJ4Ugnl8JchH8-XDcKX2XYRPdaglzxldLnSEwL8Jbl3qyDZQo89XX_ajUTHvjlKs8YoOrnljro3Pt27OEAXrJ6k3aFEMm59aY2jiKQ1VZ_In8HwyqjNCDe2MeSOalnLsKaSqWferT0CKlCWRQmRxoZQN4H17kzoDskgiShcEcAjsFtl6J7PUG7OgzbWYkhJ2R2EqTXoNPSgtP7QrwIkPiIIYZQJHk1ERqbTxV0Co0GIeWYuG-f7NI1AOK9nVN4E94kVWVzSh_ztZrFTw2rHj5kZ31tWEezFP9FiSHjEw3wETUpU93lZBOs5uuwf4xxGHvqS1xr3qxE2zT9BCDYXLOY6Fu6snYWfgVXrsP60f7tKc1pXRiYymGhyHT5Gx6aXfohH9WH8k6CyX25bwl-2ASkrtAc4t5EfKRlB_-0S0)

Liveness — the app can't see the helper's process through the sandbox, so file freshness
(`writtenAt` + mtime) plus the presence of Darwin notifications is the only liveness proxy:

```plantuml
@startuml
title ADR-0055: Liveness states of the app↔helper seam (from the app's view)
[*] --> HelperNotInstalled

state "Helper not installed" as HelperNotInstalled #F5F5F5
state "Installed, not running" as NotRunning #FFF8E1
state "Running, data stale" as Stale #FFF8E1
state "Healthy & fresh" as Fresh #E8F5E9

HelperNotInstalled --> Fresh : bookmark granted +\nfresh status.json
Fresh --> Stale : health.failingSince != null\n(helper polls, API failing)
Fresh --> NotRunning : now − writtenAt > max(3×poll, 90s)\n+ no notify
NotRunning --> Fresh : writtenAt fresh again
Stale --> Fresh : failingSince == null
NotRunning --> HelperNotInstalled : bookmark lost
Stale --> HelperNotInstalled : bookmark lost

Fresh : normal — full UI with pacing
Stale : existing stale-⚠️ + health.reason
NotRunning : amber "helper not running?"
HelperNotInstalled : install affordance (ADR-0058)
@enduml
```

![PlantUML Diagram](https://www.plantuml.com/plantuml/svg/ZLF1QXin5BphAwOEj7Pj1vTYS1QInb0lCPHI4dggUtY9jLurMccHv3YvvLHwAvH0eQT-Hk_z4_z0Vw6IThVP11_ANhJxPkRDctqwjewCMnUIEU4an_JrwN0q6eyJl15NN75huH6EM-WCBkUWijn-likvBBc1vLIWcnbTDBLd5bU2Rthim_EF60wFS1AHRxMRAoya9Lyo5XNHgKfGsa4qnGx8xk1WBns7fw7-AmmYtQoL4ceLoPvsMhrwKffEPYyQKlrvW2Kv2cD97XbduVGOVC99klm6Jv4PRlC8JCC9UxD9EfuTCBR3PfYuGYKur_go87E9bI7bVB6_K54h9hgs-v-iLgn21rvb8q4UE-zd9AHtUoRK1SUJGwYrb0lLhPCljPHsWEcxEMfWhoNLoY3n0Msm_V8D6oESushgS8I2hhilVtyFAWCSZ6nleVeU6C8KsGrhyTiJtIjKSz2AX6ALxpRkWVN3olfZpHtXjIAJshgMy7-0MTDSQLEGnFRs3fdlY_TpR8JBKTA5xysQbFcri2wOYNimtFxu-UVNL_IRz0sdy7SU14d5kK--az-lRRrthpgxTY5fjXgKPTeiAQJHhI_OfCUEkLhwY_SN)

## Consequences

- **The token never crosses the boundary** — an invariant; only derived numbers go out. Better
  privacy than the current setup.
- **A read-write bookmark** (not read-only) — the app writes config into the helper's folder.
  Trade-off: a broader permission + **higher review risk** than read-only Spark/iStat (needs to be
  explained clearly in the submission: this is user config, not remote code control).
- **Folder-scoped** (not file-scoped) — so that an atomic `rename()` doesn't invalidate the
  bookmark. **This is exactly what the #E0 spike proves.**
- **Asynchrony is not a regression**: the semantics of "command → the app will see the new state"
  is identical to the current async push; the only difference is a lag (a second or two on
  watch/poll).
- References: [ADR-0019](0019-token-read-via-security-cli.md) (why reading the token stays on the
  `security` CLI, hence helper-side), [ADR-0017](0017-delegated-token-refresh.md) (delegated
  refresh — helper-side). Related: [ADR-0056](0056-thin-helper-thick-app-build-flavors.md),
  [ADR-0057](0057-token-provider-io-into-helper.md).
