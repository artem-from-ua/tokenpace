---
status: draft
date: 2026-08-01
---

# ADR-0056 (draft): Thin helper / thick app — розкол таргетів і build-флейвори

> **Чернетка (draft).** За гейтом #E0. Фіксує філософію розколу та компіляторну межу sandbox-безпеки.

## Контекст

Директива: **максимум логіки — у застосунку; helper — лише «інтерфейс доступу» + базовий лайфсайкл**
(ретраї опитування, backoff тощо). Helper робить **тільки** те, що фізично заборонено пісочниці, +
мінімальний лайфсайкл цього I/O. Уся *розумна* логіка (pacing, severity, blocked, детекція, рендер)
— у застосунку.

Перевірка кодом підтвердила, що це **майже наявний дизайн**: `PollOutput` уже несе сирий
`UsageSnapshot` (не обчислений pacing); декодування живе в `UsageClient`; pacing/severity/blocked —
у render-шляху застосунку. Тобто застосунок уже отримує сирі числа й рахує «мозок» сам.

Фізично прибите до helper'а (= «базовий лайфсайкл»): **429-backoff** (`Retry-After` у HTTP-хедері,
якого застосунок ніколи не бачить), **адаптивний темп через `sysctl`** (Claude-неактивний
override), **wake-rearm** (рішення поллити на sleep/wake). SPEC-івський content-diff темп ніколи не
був реалізований ([ADR-0032](0032-simplified-polling-cadence.md)), тож темп уже незалежний від
продуктової логіки.

Окремо: MAS забороняє власний auto-updater (2.4.5-vii — оновлення лише через App Store), тож
sandboxed-застосунок мусить **не лінкувати** `UpdateInstaller` взагалі.

## Рішення

Межу sandbox-безпеки зробити **властивістю лінкування**, яку гарантує компілятор, а не дисципліною з
розсипаних `#if`. Винести всю заборонену роботу в окремий таргет, який MAS-app **просто не
залінковує**:

- **`TokenPaceKit`** (наявний) — pure моделі, pacing, clock, layout, `StatusClient`, cadences +
  **нові `HelperPayload`/`IPCSchema`** (IPC-контракт). Лінкують **обидва** — MAS-app і helper.
- **`TokenPaceShellIO`** (новий) — заборонені shell-операції: спавн `security` (I/O-половина
  `TokenProvider`, [ADR-0057](0057-token-provider-io-into-helper.md)), `ClaudeCLIRefresher`,
  `ProcessClaudeActivityProbe`, `ShellEnvironment`, `LogArchiver`, `UpdateInstaller`,
  `GHReleaseFetcher` + `PollingEngine`/`UsageClient`. Лінкують **лише helper і DevID-app**, **НЕ**
  MAS.

Три build-флейвори з одного SPM-пакета, гейтовані `MAS_BUILD`:

```plantuml
@startuml
title ADR-0056: Розкол таргетів і хто що лінкує
skinparam componentStyle rectangle
skinparam packageStyle rectangle

package "SPM-пакет" {
  [TokenPaceKit\npure + IPC-контракт] as Kit #E8F5E9
  [TokenPaceShellIO\nзаборонений I/O + engine] as Shell #FDE8E8
}

package "Артефакти" {
  [MAS app (b)\nsandboxed] as MAS #E8F4FD
  [Helper (c)\nне-sandboxed] as Helper #F3E8FD
  [Developer ID app (a)\nнаявний] as DevID #F3E8FD
}

MAS --> Kit
MAS ..> Shell #line:red;text:red : НЕ лінкує\n(link-time гарантія)

Helper --> Kit
Helper --> Shell

DevID --> Kit
DevID --> Shell

note bottom of Shell
  security-спавн, sysctl,
  claude-refresh, ~/.claude,
  UpdateInstaller — усе тут.
  MAS-app не може це залінкувати.
end note

legend right
  Зелений — sandbox-clean (обидва)
  Червоний — заборонений I/O (лише helper/DevID)
  Синій — App Store
end legend
@enduml
```

![PlantUML Diagram](https://www.plantuml.com/plantuml/svg/VLDDRnCn4BtxLupQIogwQIKeAaMg6f54HAXgHE14EBYRQRAAurtjEgWLAah3X-1K3gMSaE34DIq4GaF2Nx3_0h-4iNTJKWuSOgrdtfjvCtxPIXIFLRSZc0gKG2WKxtkhgsitDq1_r5FzNL_GEGRJrmFJqr_qqFJDgJu7Smhc9KMdODxGeSSKdUWByzoSiAGTo8Z7l0D-s8b2YLBLr04LZz5NN3O5pa4YxhTv4_y5i2mE2xNgjgT_wG4feUOBy9G1F7eGjb5MkO_t0bMNKJT6k0QLwXtFwPsGo9vbcFvZu0aG21PBw-Mrqgqhv5eBXQZir2NDET1dUaeiOkiX_KRw1rHMTgWiocOWqHLo15Wi5qlhfNLsEATIlpKzMiVGl4Zxwb6cTBjG0nv5aDjTgik4oyPkk8yDLyschAmRvQ95taKHOGmvdu1MX7SLdQKNozU9uWX5V88YjC5ACUt1K-h07ElpT0P79I0XPaoIRJjxtgPTZFlEvpTdimcQTIF6ncs5-yf-05dXWtvtvOdhCaUujgU23WAvOk3MRTT-QewN6CkqpbhCNLqNnb95i_pVMvQMeKBO3PKAEn3kPL601Frk7AW3pnmvHz2Cov0S9BuIovJs1Uysq8jnByQajGpFLl9fo2OVHWski2B9xqAGcD-z4w1HZlIGp4qV_Jo1Q1UUNQHTF-YVP8PlDl_Atgn5BbT0hGVsaVCCPGEiNCO4Dkqb3fejHRNqU_BH-D9Bjb_se9ula4l8KVapodsrnPOiupFvfqUtwHpdFzRCKVcHUKtYMcx1AswFhj8d0ar8R5gZG2FLL1YZKvlgP5jqqF_-3m00)

`TokenProvider` **не переїжджає цілком**: pure-половина (`decode`, `parseSecretOutput`,
`mapExitStatus`, `OAuthCredentials`) лишається в киті; у `TokenPaceShellIO` їде лише спавн `security`
([ADR-0057](0057-token-provider-io-into-helper.md)). Так само `PollingShell`: pure engine у киті,
`ProcessClaudeActivityProbe` — у ShellIO.

## Наслідки

- **«MAS-app навіть не може залінкувати `security`-спавн» — link-time факт** (не дисципліна). Асерт:
  кит компілюється в sandboxed MAS-app з нуль `Process`/`sysctl`/foreign-Keychain — сильний
  аргумент на ревʼю.
- **Idle-grace / session-idle suppression** (`advance`/`applyIdleGrace`) — єдина продуктова логіка,
  що зараз у циклі poll'а (читає попередній snapshot + `sysctl`, несе крос-poll стан). **Відкрите
  питання (#E3/#E4):** лишити helper-side (helper віддає вже-скоригований `sessionIdle`) чи
  перенести в застосунок (проброс `claudeActive` + стану). Вирішується під час реалізації.
- **Розширює [ADR-0004](0004-build-system.md)** — Xcode-обгортка над SPM для MAS-пакування приходить
  тепер (0004 передбачив Xcode у Фазі 2 для iOS/watchOS; це — MAS-варіант тієї ж ідеї).
- Auto-updater ([ADR-0033](0033-automatic-update-install.md)) — лише в helper/DevID, скомпільований
  геть з MAS. Log archiver ([ADR-0031](0031-session-log-archiver.md)) — helper-side.
- **(a) і (c) лінкують той самий `TokenPaceShellIO`** — нуль дублювання engine-логіки, але окреме
  пакування/реліз → подвійні release-ops до конвергенції.
