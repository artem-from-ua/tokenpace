# Architecture — overview

Product details are in [SPEC.md](../../../SPEC.md). Here — the compact architectural picture,
deployment topology, and cross-cutting principles. The data flow within Phase 1 is in
[data-flow.md](data-flow.md); the update system is in [update-system.md](update-system.md); service
status, config, and Settings are in [services-and-config.md](services-and-config.md).

## Principles

- **No backend of our own.** The Mac is the only component that touches the Anthropic API.
- **The token never leaves the Mac.** It lives in the macOS Keychain (`Claude Code-credentials`).
- **Redraw only on a data change** (use or a timer reset) — for energy efficiency.

## Phase 1 — menu bar app (no CloudKit)

Everything runs locally on one Mac: `PollingEngine` (a live async loop, a pure core + seams in
`TokenPaceKit`) reads the token from the Keychain, calls the usage API, and draws the
`NSStatusItem` only on change. A second, independent stream monitors Claude service status. The
detailed data flow is in [data-flow.md](data-flow.md).

## Phase 2 — devices (adds CloudKit)

The same Mac agent writes a usage snapshot to a private CloudKit DB (the same Apple ID); the
iPhone widgets and the Apple Watch complication read from there. This is planned, not implemented
(see SPEC.md, Phase 2).

## Deployment topology

```plantuml
@startuml
title TokenPace — Phase 1 (menu bar, no CloudKit) vs Phase 2 (devices)
skinparam componentStyle rectangle

node "Mac (agent, license TBD)" as mac {
  artifact "Keychain\nOAuth token" as kc
  component "TokenPace-agent\n(menu bar app)" as agent
  component "claude CLI\n(Claude Code)" as cli
  component "NSStatusItem\n2 pacing bars + reset time" as menubar
}

cloud "Anthropic" {
  component "OAuth token endpoint\n(refresh ~8h)" as oauth
  component "usage API\n/api/oauth/usage" as usage
}

cloud "Apple iCloud\n(Phase 2, same Apple ID)" as icloud {
  database "Private CloudKit DB\nusage snapshot" as ck
}

node "iPhone (Phase 2)" as iphone {
  component "Home-screen widgets" as iwidget
}
node "Apple Watch (Phase 2)" as watch {
  component "Complication\n5h+7d rings + reset" as compl
}

kc --> agent : read token\n(/usr/bin/security, ADR-0019)
agent --> cli : spawn on expiry\n(delegated refresh, ADR-0017)
cli --> oauth : refresh_token grant
cli --> kc : rotate credentials
agent --> usage : GET utilization + resets_at
agent --> menubar : draw (on change only)

agent ..> ck : Phase 2: write snapshot\n(on change / reset)
ck ..> iwidget : Phase 2: read
ck ..> compl : Phase 2: read

@enduml
```

![PlantUML Diagram](https://www.plantuml.com/plantuml/svg/PLJBRjim4BphAnOwsOWT9m6Aj3aKSUoYDTA7KGVenK2mfXYBa4GIvCgkKxJeH_GB-oLTahBZf3U9dDcTsLdfsXCwQfiw8qMrX3jJIJr78U7lxpymBz5BE8TU8tKBAtG3q0OcjMcBMqLzsFWESW6zGcwKaBwV-KffYmuR4AQnHajD2zfnRIS5eLxNCikqAIJadr103zSC643DPCsLxcwc_HpGGyENFp80bgSUK13ajt8dIbHwgR-CMog1WjQ8hGG33zqWFxWOnkfBVJ00Q6sg7s-UqqIDBUkQV9mnOzAziD944BLw3l-yM11IwsSacwM-08j2wNNeuk64tNf9GAgHoGuBu9liPvQ9C3_8nvfAPwmIUVHvLFZ87aXTMAEY1oSVk6W9lrwNIP51nZsdjfvzmNZE3aPerIX2Hl4qKkBJiGXhEHaL8-KMNPe3yDXmcNWvwm9HYHAq5aYu2iXyxjG6IHvs0gOtIvr4U8tMbuRIyAhGDCMkvYMhXNsphhgDXoycyS4qSkY5apo9hIhMadn2fnUkcKecfT-GHFcYxZQUlIWxuKTUE2HbU9jUbIUN1JZExf1RqXnGGNObO3XycpO6hXY1HKg79yQpTQELqYClHUiKxGOmdduTdfsTl-bdYH6ul3pCz1Qt6Wod-jqgjsDw8MkvvW5o_vJkWNxPpm8fa6E8iN64tAVDM3la1TvZM2C338KmU5u5DrPO-oC9APKhUF_k3bfIjNgC_lUM_JtI4RhRLyON3hVGOo1_V9eh65tl-ba7FJrbRnMZkg5VmPQ7y1G-MtnYZb8dDbP5OfVYCJlCTdyTv__VPNRDdmJ_iFu1)

## The cadence family

Each background stream has its own frequency. All of them are pure `*Cadence` seams in
`TokenPaceKit`; most piggyback on the usage tick rather than running their own timer.

```plantuml
@startuml
title Cadence family — intervals & floors (Phase 1)
skinparam componentStyle rectangle

card "Usage polling\n(PollingEngine, ADR-0032)" as usage #E8F4FD
card "Status polling\n(StatusCadence, ADR-0013)" as status #E8F5E9
card "Update check\n(UpdateCheckCadence, ADR-0025)" as upd #FFF8E1
card "Log archive\n(ArchiveCadence, ADR-0031)" as arch #F3E8FD

note bottom of usage
  base 3 min; floor 60s
  429-hold = Retry-After (no escalation)
  claude idle → 15 min override
end note
note bottom of status
  max(floor, usageInterval)
  floor 5 min; problemFloor 60s
  piggybacks usage tick
end note
note bottom of upd
  fixed 12h + unconditional launch check
  marker advanced on every attempt
end note
note bottom of arch
  fixed 24h
  marker advanced only on success
end note
@enduml
```

![PlantUML Diagram](https://www.plantuml.com/plantuml/svg/TPF1Qjj048RlUeeXWMBJ62pP3Wcb41DRKEWX9EJMotXtB2rQxOhTbObkFVK1IfymJz9Phzm4qznsbvdl_-SVwSu7TA5lTHPKq0JtACa8WZssIW_m-lCFA1F87L1x-0HxRQtpC7ceqHFaqymtodJei0LXsyuQCk4f30no90AQIbEM2NGIBfuzLWITrLgPweUPFAJJrbJAq1MiDu-p-NnHJ2y0FVJ7uiljJRaiDoFWAM3e_Jj2UXWTdmZv8X5ygew8rVRsvA6J60X4JQ9XGBhUnziPfLYDFZe9bsLPtcpp4V7TLe1ErEf0J5Ydqrdt8a_TiOxR5-nXasN6ilJEXc1RiFiqOWQmYqake5NcIueNhkUUtvV5xQosMi9NUAJWXjbwptk0YR50Ng36eAoPSg7Gs4i29Jdrrr-_8Lz56DW3EQSaPMGaHErp0oaX1hJuCZagNoLJtyQ5HtXoj4hsEcTtcjhodSjELTMmGz6STXQKQ3wKv3WZKxsGXBoeuJFqHbWZLPm5DV0aXYCxxkTep3KyCie3SheIh07YgGR04AZjmeSwCVX_GiMo_Y-BFsy6-bu8yluDTSSd_X_-0W00)

## SPM layout

`TokenPaceKit` (library target — all the logic that's tested and reused in Phase 2) +
`TokenPace` (executable target — the AppKit entry point). Building the `.app` bundle:
`scripts/build-app.sh` → `./build/TokenPace.app`.

The cross-cutting logging wrapper is **AppLogger** (`os.Logger`, 4 categories —
`network`/`keychain`/`lifecycle`/`ui`, subsystem `com.artem-n.tokenpace`). The token and secrets
**are never logged** (default `<private>` redaction; only safe diagnostic fields use `.public`).
The full message catalog is in [log-messages.md](../log-messages.md).

## Component map

| Area | Page |
|---|---|
| Polling, token, pacing, menu bar render, popup | [data-flow.md](data-flow.md) |
| Update checking and auto-install | [update-system.md](update-system.md) |
| Service status, monitored services, persist/migrate, Settings, archiver | [services-and-config.md](services-and-config.md) |
