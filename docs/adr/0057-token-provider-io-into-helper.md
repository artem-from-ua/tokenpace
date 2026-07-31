---
status: draft
date: 2026-08-01
---

# ADR-0057 (draft): Перенос I/O-половини `TokenProvider` у helper

> **Чернетка (draft).** За гейтом #E0. Уточнює, як `TokenProvider` розколюється на межі
> [ADR-0056](0056-thin-helper-thick-app-build-flavors.md), і що механізм [ADR-0019](0019-token-read-via-security-cli.md)
> переноситься без змін.

## Контекст

`TokenProvider` читає **чужий** Keychain-айтем `Claude Code-credentials` (створений Claude Code CLI).
[ADR-0019](0019-token-read-via-security-cli.md) вимагає робити це **спавном `/usr/bin/security`**, а
не `SecItemCopyMatching`: Claude Code на кожному refresh переписує айтем через
`security add-generic-password -U`, що скидає ACL partition list на `apple-tool:` — прямий API-read
після цього промптить. Спавн `security` (сам у партиції `apple-tool:`) лишається тихим.

І спавн бінарника, і читання чужого Keychain-айтема **заборонені App Sandbox**. Отже ця робота
фізично не може бути в MAS-застосунку — вона мусить бути в не-sandboxed helper'і
([ADR-0054](0054-mas-present-if-installed-helper.md)).

Але `TokenProvider` **уже має purity split** (ADR-0019, ADR-0007): pure-частина (`decode`,
`parseSecretOutput`, `mapExitStatus`, `OAuthCredentials`, `TokenCredentials`) відділена від I/O
(`readRawData`, що спавнить `security`).

## Рішення

Розколоти `TokenProvider` по наявному purity-шву:

- **Pure-половина лишається в `TokenPaceKit`** — `decode`, `parseSecretOutput`, `mapExitStatus`,
  `OAuthCredentials`, `TokenCredentials`, `TokenError`. Юніт-тести не рухаються.
- **I/O-половина (`readRawData` + спавн `security`) переїжджає в `TokenPaceShellIO`** (лінкує лише
  helper/DevID — [ADR-0056](0056-thin-helper-thick-app-build-flavors.md)).

**Механізм ADR-0019 не змінюється** — той самий спавн `security find-generic-password -s
"Claude Code-credentials" -w`, та сама причина (ACL partition reset). Змінюється лише **host-процес**:
з застосунку на helper. Так само делегований refresh ([ADR-0017](0017-delegated-token-refresh.md)) —
спавн `claude` — тепер у helper'і.

```plantuml
@startuml
title ADR-0057: Цикл читання/refresh токена всередині helper'а
skinparam sequenceArrowThickness 1.5
skinparam LifeLineBorderColor #C0C0C0

participant "PollingEngine\n(helper)" as Engine #F3E8FD
participant "TokenProvider I/O\n(ShellIO)" as TP #FDE8E8
participant "/usr/bin/security" as Sec #F5F5F5
participant "claude CLI" as CLI #F5F5F5
participant "usage API" as API

Engine -> TP : currentCredentials()
TP -> Sec : spawn find-generic-password
Sec --> TP : сирий secret
TP -> TP : decode (pure, в киті)
TP --> Engine : TokenCredentials

alt токен прострочений
  Engine -> CLI : spawn claude --safe-mode -p /usage\n(делегований refresh, ADR-0017)
  CLI --> Engine : Claude Code переписав айтем
  Engine -> TP : currentCredentials() ще раз
  TP -> Sec : spawn (тихо: apple-tool: партиція)
  Sec --> TP : свіжий secret
  TP --> Engine : свіжий TokenCredentials
end

Engine -> API : authed запит (Bearer)
note right of Engine
  Похідні числа → status.json.
  accessToken/refreshToken
  НЕ покидають helper.
end note
@enduml
```

![PlantUML Diagram](https://www.plantuml.com/plantuml/svg/TLJHIXj157tVhxZeGoEuYL94oKDHOmH1C5GV-pBTJ9Afw-nsPhRIDoEe54g5GlDM-jRdnPeQQzLVcFc5VadFR5QQr9ObJ7Rdt7lElUVEh6h3bCaEui084tDQstWUBYmiBTV9VhKZ-yFUa3kp8tTiStjhRzrvJV6Euhf7-7I7_I4-vsGlNDyEtH5UBn5swmRKut7ArHER1tfVo9GfTa2QlywuZFYQKidXNaz4-v9hJOlLfGdGjkZmRI7vUgBQN3MIE54qsrZmJn00OaGaKYODpRIIE1QosvHTm5_8ofXoReQOfl57cjrysbpPt9YEsqlskMofv8q00MtLTX2xY-1uQsSSlDT2u4PpfRao7LZBjAgz5BAcUPGfOTuMw5qU0Rxadsbu5BEipQcnlLNWiFuRbsdMHUjROnZM82ZbXy-ybZg1JN5f6egtiGWMwyfSW1tiU_OwwPGTIke8sGwxN78beZ1bMX-YXu57X0-PuDC8FetiDTo853TbccAppQC4WYjfflWyJ2KO3E_TO4m6MAchJaKF9_G40OlDn52GlGVDdUiZtAzdnQI0DY3wKvnloOFuibjXg5c7XmTUI9XIhMWE3C9W3UqDVjz0SL6Ceo-Y7CVvSd8Nb-T0uDDEgMsKJlYazhwSr7lKraSYb9dRQqWVsfzJwlxRUdBlx92G9BTNY7XiH0NPHkx4tjM9fMdCGvCaSTrJv-wes3jr0tVkjVxjpeKRsE-J_eppJrOpXNfa19VjoVd1E264PQR7ssIl8DdNVKoLTSuKJaiW4yD9YMxFKD8fIK1gly2r4z1S5iUvk0NwC22dNwSV2TU6oNJrbKva5M0MHJZ8XPI72w9uyNa-sq--S3yN8oJBtGUCnFloVgXwkUGb1AluXuleDm00)

## Наслідки

- **ADR-0019 чинний** — його рішення й аргументація переносяться незмінними; змінюється лише, який
  процес виконує спавн. Post-scriptum до ADR-0019 не потрібен (механізм той самий).
- **Токен не перетинає межу** ([ADR-0055](0055-ipc-file-darwin-bookmark.md)) — наверх іде лише
  decoded `UsageSnapshot`, ніколи `accessToken`/`refreshToken`.
- **TCC-відповідальність за спавн `claude --safe-mode`** тепер на процесі helper'а, не застосунку —
  поведінка має бути еквівалентною, але треба пере-верифікувати (частина #E3).
- Пов'язано: [ADR-0056](0056-thin-helper-thick-app-build-flavors.md) (де саме проходить лінк-межа),
  [ADR-0017](0017-delegated-token-refresh.md) (delegated refresh), [ADR-0033](0033-automatic-update-install.md)
  / [ADR-0025](0025-check-for-updates.md) (updater/fetch — теж helper-side).
