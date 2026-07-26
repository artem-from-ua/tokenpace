# Архітектура — огляд

Деталі продукту — у [SPEC.md](../../../SPEC.md). Тут — стисла архітектурна картина, топологія
розгортання та наскрізні принципи. Потік даних усередині Фази 1 — у
[data-flow.md](data-flow.md); система оновлень — у [update-system.md](update-system.md); статус
сервісів, конфіг і Settings — у [services-and-config.md](services-and-config.md).

## Принципи

- **Без власного бекенду.** Mac — єдиний компонент, що торкається Anthropic API.
- **Токен ніколи не покидає Mac.** Він лежить у macOS Keychain (`Claude Code-credentials`).
- **Перемальовування лише при зміні** даних (use або ресет таймера) — енергоефективність.

## Фаза 1 — menu bar app (без CloudKit)

Усе локально на одному Mac: `PollingEngine` (живий async-цикл, pure ядро + seam'и в
`TokenPaceKit`) читає токен із Keychain, ходить у usage API, і малює `NSStatusItem` лише при зміні.
Другий незалежний потік моніторить статус сервісів Claude. Детальний потік даних —
у [data-flow.md](data-flow.md).

## Фаза 2 — пристрої (додається CloudKit)

Той самий Mac-агент пише usage-snapshot у приватну CloudKit DB (той самий Apple ID); віджети iPhone
та комплікейшен Apple Watch читають звідти. Це заплановано, не реалізовано (див. SPEC.md, Фаза 2).

## Топологія розгортання

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

## Родина каденцій

Кожен фоновий потік має власну частоту. Усі — чисті `*Cadence` seam-и в `TokenPaceKit`; більшість
хантажиться з usage-tick, а не має власного таймера.

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

## SPM-розкладка

`TokenPaceKit` (library-таргет — вся логіка, що тестується і реюзується у Фазі 2) +
`TokenPace` (executable-таргет — AppKit entry point). Збірка `.app` bundle:
`scripts/build-app.sh` → `./build/TokenPace.app`.

Наскрізна обгортка логування — **AppLogger** (`os.Logger`, 4 категорії
`network`/`keychain`/`lifecycle`/`ui`, subsystem `com.artem-n.tokenpace`). Токен і секрети
**ніколи не логуються** (дефолтний `<private>` redaction; лише безпечні діагностичні поля —
`.public`). Повний каталог меседжів — [log-messages.md](../log-messages.md).

## Мапа компонентів

| Область | Сторінка |
|---|---|
| Полінг, токен, pacing, рендер menu bar, popup | [data-flow.md](data-flow.md) |
| Перевірка й авто-встановлення оновлень | [update-system.md](update-system.md) |
| Статус сервісів, monitored services, persist/migrate, Settings, архіватор | [services-and-config.md](services-and-config.md) |
