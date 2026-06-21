# Архітектура

Деталі продукту — у [SPEC.md](../SPEC.md). Тут — стисла архітектурна картина та потік даних.

## Принципи

- **Без власного бекенду.** Mac — єдиний компонент, що торкається Anthropic API.
- **Токен ніколи не покидає Mac.** Він лежить у macOS Keychain (`Claude Code-credentials`).
- **Перемальовування лише при зміні** даних (use або ресет таймера) — енергоефективність.

## Фаза 1 — menu bar app (без CloudKit)

Усе локально на одному Mac:

```
Keychain (OAuth token)
  → cc-timer-agent (menu bar app)
      → GET https://api.anthropic.com/api/oauth/usage
        (headers: Authorization, anthropic-beta, User-Agent: claude-code/<version>)
      → малювання NSStatusItem (дві pacing-смужки + час ресету)
```

## Фаза 2 — пристрої (додається CloudKit)

```
cc-timer-agent → запис usage-snapshot у приватну CloudKit DB (той самий Apple ID)
CloudKit → віджети iPhone + комплікейшен Apple Watch (читання)
```

## Потік даних (Deployment)

```plantuml
@startuml
title cc-timer — Phase 1 (menu bar, no CloudKit) vs Phase 2 (devices)
skinparam componentStyle rectangle

node "Mac (agent, license TBD)" as mac {
  artifact "Keychain\nOAuth token" as kc
  component "cc-timer-agent\n(menu bar app)" as agent
  component "NSStatusItem\n2 pacing bars + reset time" as menubar
}

cloud "Anthropic" {
  component "OAuth token endpoint\n(refresh fallback ~8h)" as oauth
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

kc --> agent : read token
agent --> oauth : refresh (fallback)
agent --> usage : GET utilization + resets_at
agent --> menubar : draw (on change only)

agent ..> ck : Phase 2: write snapshot\n(on change / reset)
ck ..> iwidget : Phase 2: read
ck ..> compl : Phase 2: read

@enduml
```

![PlantUML Diagram](https://www.plantuml.com/plantuml/svg/PLJ1QXin4BthAuOzUKaSqq1fyI74IKfhGbk30xqOobWhUyNkIaAQjN5BIpyYNzWlwQoqTZRkJQjvxytJcs5l0w6djga5QQeLI3actIWFV_yymwB4eE0DZ1fbMbYZlmHZuRwsRV6eAOTTw27NC2hKJaiLSX4gRHnwR43QnbcZ32tfmD9UIKAphPKGnXOAiiyeOOHR1bn2pMJ3Iazt3ta66A3Xuay1mExq1YL1zgWEiaHjLkRhhAKIo5RAH6mb6NZg1jdn4UCelZ8d_u3E9VbOUStwibmIKXlcf9gLkGQ7KfjjHmjmmUw38kXaaprMv8hu9OJiye1iPgZqrccPHTy3uO5TKAPmLaTJNcrOj8GDrlKQPGM_tvV9d4KclDPe0pk6sMA-CXDqUX8XatWRAV4qTECSHwxZhBXNFwPB2DYmJ2pE-wHredIc2oHSTyXiuVKEIPs63GztAvDC18Ckb9OYMLPTqpHFlIZPBHoRzUekNfv5yiasQXoaLnp9NXTRHI6XqmTh9idaz1kIBCzqz_7kJFQUZxn9IDhochmjBzuLu7c8fm4cpnsgirr968zlqYx0b15Of369TDKLOz2ncAOrEeuh7u1IC5Fu-E49MjAr_X4j7Bk6xqW3TByxZ2yyxc74G5vimmhMr8TSzD2hgnkEbr7zkwUmzvfUykUnlZ0dgLCkcD4H-o27xEvvntACuB-YkENrv7_1Fm00)

[Двофазний deployment: Фаза 1 — самодостатній menu bar app, що читає Keychain і usage API; пунктирні шляхи Фази 2 додають CloudKit, віджети iPhone та комплікейшен Watch](https://www.plantuml.com/plantuml/svg/PLJ1ZjCm4BtdAqOvDTgcXKe8rCDgoow2QWLKAXANIcZgk8sLnBRiIQk2G7m4NyYNCB7JRhRS4izxRzxCStBd2HsrJPsGebg243cfHZhu-_iFh4hq4bx2g96wXIswCMW3zxLfYqT56Hny3vd1g9079QJF4byfRT5X0y8qrcYfQKqdbdPI4EfzBPD4cq92-X45Z8oLElUcTK82xXayXeL5KSfyDdcHfO0U6iRzI03OgDgX84WVvKcKgFH6VrwqL0APIkg0hGG3BuqXFS-J1-sDlem2Q6sK3vNdh4_hDI6rVacosUWPi26bzntDmmqFuYL19nljiI9Nafz98hhLGBhGL3fZbKY3xu7mm2v8NLYZWYadTonQmWxhUekYWbzlocZE81EUQxIU7SDYjTpeALer3P1fE0sKy3HqOorlNuNOk5UVs1WyDYmJYik7s4r5IcUwGC9jXqnNJXsGv2LtU7YxqT64rsXzQIYGHTKrZT6gLSbkuToiLxVXy6eb7qmZSo-Sv9KSLR6Nv2Cwlh1cb8nEloA9yaht6CwkPE_viLO2IHc-9g_AczS5E0xn4c3qtA4wsvM0FB-DTm7cZC0YnfJ4ewuO5XsACQtHEQvi08gBcSFxTr-W9LMhxy72kQl_XZH0ztU7yON38tyD6lXYQrOmkZvbIG-TJ6vvlOpgvvx3qIbwsZ_7-iISnavPmeoEs2zooEx6EvV32luh9dTyFVcty0y0)

## Компоненти (Фаза 1)

**SPM-розкладка:** `CCTimerKit` (library-таргет — вся логіка, що тестується і реюзується у Фазі 2)
+ `cc-timer` (executable-таргет — AppKit entry point). Збірка `.app` bundle: `scripts/build-app.sh`
→ `./build/cc-timer.app`.

| Компонент | Відповідальність |
|---|---|
| **AppLogger** | Наскрізна обгортка над `os.Logger` (3 категорії: `network`/`keychain`/`lifecycle`, subsystem `com.artem-n.cc-timer`). Токен і секрети **ніколи не логуються** — дефолтний `<private>` redaction; лише безпечні діагностичні поля позначаються `.public`. |
| **TokenProvider** | Читання токена з Keychain; fallback-refresh при протуханні (рідко) |
| **UsageClient** | Запити до usage API з обов'язковим `User-Agent`; backoff при 429 |
| **PacingModel** | Порт `calc_time_pct` / `build_progress_bar` / `get_limit_indicator` зі statusline |
| **StatusItemView** | Кастомна `NSView` (смужки + час); idle-режим; стани помилок |
| **Popup** | Деталі лімітів, розбивка по моделях, службовий рядок (останнє оновлення + інтервал) |
