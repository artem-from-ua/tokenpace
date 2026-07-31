---
status: draft
date: 2026-08-01
---

# ADR-0055 (draft): IPC-канал app↔helper — файл + read-write bookmark + Darwin notification

> **Чернетка (draft).** За гейтом спайку #E0, який має наскрізно довести цей канал (насамперед —
> що read-write security-scoped bookmark переживає атомарний `rename()`, і що Darwin-нотифікації
> будять sandboxed-застосунок під App Nap). Драфт — центральне рішення розколу.

## Контекст

MAS-застосунок ([ADR-0054](0054-mas-present-if-installed-helper.md)) sandboxed; helper — ні. Їм
треба обмінюватися: helper віддає похідні usage-числа **вниз**, а застосунок (за вимогою «вся
конфігурація helper'а — з UI») пише конфіг і команди **вгору**. Отже канал **двобічний**.

Обмеження (перевірено проти Apple-доків + DTS):

- **XPC/mach до не-вкладеного helper'а** потребує `temporary-exception.mach-lookup.global-name` —
  App Review до нього ворожий. **Відкинуто.**
- **loopback `127.0.0.1`** під sandbox дає `EPERM`. **Відкинуто.**
- **App Group container** неможливий — сторони мають різні Team ID / provisioning (helper —
  Developer ID, застосунок — MAS). **Відкинуто.**
- Єдиний sandbox-легальний шлях застосунку читати/писати поза контейнером — **user-granted
  security-scoped bookmark** через `NSOpenPanel`.

Модель — **не** синхронний RPC. Це асинхронна файлова «поштова скринька» в обидва боки, і цього
**достатньо**, бо поточний код і так асинхронний push: UI не чекає на engine, а шле `.manualRefresh`
і окремо отримує результат через `apply(_:)`.

## Рішення

Дві JSON-скриньки в одній теці, якою володіє helper (не-sandboxed), а застосунок читає/пише через
**один folder-scoped read-write security-scoped bookmark**:

- `~/Library/Application Support/com.artem-n.tokenpace-helper/status.json` — **helper→app** (сирі
  usage-числа + health + версійність + liveness). **Токен, refresh-secret, вміст `~/.claude` —
  ніколи не серіалізуються.**
- `.../config.json` — **app→helper** (вузький конфіг: 5 полів + опційна разова команда).

Атомарність — `*.tmp` → `rename()`. Свіжість сигналиться **payload-free Darwin notification**
(`notify.h`): `com.artem-n.tokenpace.status-updated` (helper→app),
`com.artem-n.tokenpace.config-updated` (app→helper). Кожна сторона — `notify_register_dispatch` +
slow-timer fallback 30 с (Darwin coalesce'иться, не черга).

Версійність — двобічна: `schemaVersion` у `status.json`, `configSchemaVersion` у `config.json`;
єдине джерело — `IPCSchema.swift` у `TokenPaceKit`, проти якого компілюються **обидва** бінарники.
Команди — не RPC: застосунок пише `command.id`, helper виконує й відображає результат у наступному
`status.json` + квитує `ackedCommandId`.

```plantuml
@startuml
title ADR-0055: Двобічний IPC-обмін app↔helper
skinparam sequenceArrowThickness 1.5
skinparam LifeLineBorderColor #C0C0C0

actor Користувач as U
participant "MAS app\n(sandboxed)" as App #E8F4FD
participant "Тека helper'а\n(status.json / config.json)" as Dir #F5F5F5
participant "Helper\n(не-sandboxed)" as Helper #F3E8FD

== First-run: грант доступу ==
U -> App : «Connect helper»
App -> App : NSOpenPanel → folder-scoped\nread-write bookmark (зберегти)

== Конфіг вниз-у-теку (app→helper) ==
U -> App : змінює налаштування
App ->> Dir : пише config.json (atomic)
App ->> Helper : notify: config-updated
Helper -> Dir : читає config.json
Helper -> Helper : застосовує до polling-циклу

== Стан назад (helper→app) ==
Helper -> Helper : poll usage (токен НЕ виходить)
Helper ->> Dir : пише status.json (сирі числа, atomic)
Helper ->> App : notify: status-updated
App -> Dir : читає status.json
App -> App : рахує pacing/severity + рендерить

legend right
  ->> async fire-and-forget (notify/write)
  токен ніколи не перетинає межу
end legend
@enduml
```

![PlantUML Diagram](https://www.plantuml.com/plantuml/svg/RPJFJnD15CVl-rUymC4ske3H9gP92PNQQ89AH6vSXjrf6RkTMMUd8ZUWykDWD278mSI3NhrKOALI2Wb_mSo_m5_YczssBc0sQR8pxttVzttUsyv4YaZLQWQEOYgWKAwySgUc2eKYw7rzgC_rBtDWTdHVT_KVU3O_wzeZVMOET1z865vjxw_G8AJIYHgCXqII9aJqROjoZvQb5AklLvZNu3IAuFv48HCqnsfqZd7wM4YVobaH20dZirFsSHpYANpLN_MvMTTTis4sJHlDTCmEa0WM7PHGp6CXuGh6dfSNh9Cbdei8zvV5U-hdnsnSEGnX_CcZwiDgvNg6_g5ZVQexa5g_episMH7LYYRUH8B397Y2rrWzUKl5AWpzLGlskIxsDD500MGKkpSif9UO-01zL1odL88gav5oPOiZuIDihwFxPXFqCVQQzdbXsb0gEOlWJYSj5E7ovwpWd7fgOFYovzYBqVsBXPSXvVE4qm2kjlUW9W9awaQU2Ac_n2KblhigcQAmB4IZIMG3Sle4nnXZ_HXTREfkFZ5daQEV3pZU8q3YTkmdhccx68B8q5ak6VfUQYH_moYA9fjXFfbzmEIExk7GTeVZmvE--JpmFfqWnPmBdF2kZhF8iOeIJURbHx43a4NWGh7QMd4GxRP2doZgEuDxTwYAAzj5pntqaT7DX8q4qNF7ahVyiVb3qxRUSHmGYY1WlEwQRQHmgdkcdJBwReLn_PC6CLiVGoxbWM0GJqBbFvMi7hGYKgUGi_LGCxOot_GNoxfhjl3isFes7_F_16w1ocvg3artpRevI3lUiC3lmP1UHYCTq91UAZ6YDzYcM-WobQvldDrRivMW2ec7a2OZ-exYYgt1NKYMge-TnCdNYzquJa3hbFiWMNr5EP0u8j4Qzw3697Nnet5hGjQfWbngSJBPrpo6PadrSRbEyRMdkvP-R9aaEsmts8x3ZkuCOt_Zh6ozjAmpWp_u5_SN)

Liveness — застосунок не бачить процес helper'а через sandbox, тож свіжість файлу (`writtenAt` +
mtime) + наявність Darwin-нотифікацій = єдиний liveness-проксі:

```plantuml
@startuml
title ADR-0055: Liveness-стани стику app↔helper (очима застосунку)
[*] --> HelperНеВстановлено

state "Helper не встановлено" as HelperНеВстановлено #F5F5F5
state "Встановлено, не запущено" as НеЗапущено #FFF8E1
state "Запущено, дані застарілі" as Застарілі #FFF8E1
state "Healthy & fresh" as Fresh #E8F5E9

HelperНеВстановлено --> Fresh : bookmark виданий +\nсвіжий status.json
Fresh --> Застарілі : health.failingSince != null\n(helper поллить, API падає)
Fresh --> НеЗапущено : now − writtenAt > max(3×poll, 90с)\n+ нема notify
НеЗапущено --> Fresh : знову свіжий writtenAt
Застарілі --> Fresh : failingSince == null
НеЗапущено --> HelperНеВстановлено : bookmark втрачено
Застарілі --> HelperНеВстановлено : bookmark втрачено

Fresh : норма — повний UI з pacing
Застарілі : наявний stale-⚠️ + health.reason
НеЗапущено : amber «helper не запущено?»
HelperНеВстановлено : install-affordance (ADR-0058)
@enduml
```

![PlantUML Diagram](https://www.plantuml.com/plantuml/svg/fLJHQXD157sVhxYs88d9beW4qeNM1aoeu4En-6HycBOJitOo6tOtrhub3LWBGg6410J1Tr-MqDfeD8Nw0pE_a1_m5xmpcyOaRCY3B2opC_UUU-yvPtRB3wWNrAkS14x06UIVFBSocMpMXcVEMoQOxrkggKvaA7_9FfXbN_vGBQ2rskXzky9uZNcGa4DrYWS_PGZoMeOcReZl5gPXT9AyVF0AB6iJjas2_2olvCK4U2XxSe0xk2846meOh4I1W7jN87jneIj0_QLui5hCwkSEDZugFQw3hSiRrL9dKnKCTdVs056BnLpXuGHrxXpnBdKDrVb7HwWQgYC7gXEXTkUtvp6t6UL1vHZkGzbZViLa5VKALWkvOhQmJiZIuJNZKOuDUwvxMANU8RA9Ibr6Yihla2e9rKI6E_AR-TRbw_xQ6zyL9ChLA37zsb0nBQwLgSCTyNhN4ViCxcs0g7DU4ecnD-GDjZJ0fwzErCSqv7UUwhrGjw3QoUaQSKpR8DmZ67suW2FF2G8cyW5iGfM-IppwtQsvdATXFQEQoP986H6D1uKREELZ4WiupGcAOmX3FyzmC2b5OkQU1fWPVICQVN7PfNhDg8HqDR3iwVXYBEZalp39X0ZymXFDtQZHZZJhZGto0lMwXXhTnq7ZkZ3PeJgV9A23EBD6dxxywPz3wiub7gFQKWj4fjKzzChjryhqjP-xZezl1yijRuCZT0FSekMownrGhKnY_5lB9SaM4mVuk_iB)

## Наслідки

- **Токен не перетинає межу** — інваріант; назовні лише derived-числа. Приватність краща за поточну.
- **read-write bookmark** (не read-only) — застосунок пише конфіг у теку helper'а. Трейдоф: ширший
  дозвіл + **вищий ризик ревʼю**, ніж read-only Spark/iStat (треба чітко пояснити в submission: це
  конфіг користувача, не віддалене керування кодом).
- **folder-scoped** (не file-scoped) — щоб атомарний `rename()` не інвалідував bookmark. **Це саме
  те, що доводить спайк #E0.**
- **Асинхронність — не регрес**: семантика «команда → застосунок побачить новий стан» ідентична
  поточному async-push; різниця лише лаг (секунда-дві на watch/poll).
- Референси: [ADR-0019](0019-token-read-via-security-cli.md) (чому читання токена лишається на
  `security` CLI, отже helper-side), [ADR-0017](0017-delegated-token-refresh.md) (делегований
  refresh — helper-side). Пов'язано: [ADR-0056](0056-thin-helper-thick-app-build-flavors.md),
  [ADR-0057](0057-token-provider-io-into-helper.md).
