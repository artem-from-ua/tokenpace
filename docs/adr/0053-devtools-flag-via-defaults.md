---
status: accepted
date: 2026-07-31
supersedes: [0052]
---

# ADR-0053: Гейт dev-tools через `UserDefaults` (`defaults`), а не env-var

## Контекст

`TOKENPACE_DEVTOOLS` (#185) розблоковує ⌥-пункт «Development tools…» і живий колор-тюнер. Прапорець
читався з оточення процесу, тож при запуску встановленого `.app` з Launchpad/Finder/при логіні пункт
**не з'являвся**: launchd стартує бінарник **без шелла**, тож `export TOKENPACE_DEVTOOLS=1` з `~/.zshrc`
не потрапляє в `ProcessInfo`.

[ADR-0052](0052-shared-prod-env-flag-resolver.md) намагався закрити це «спільним резолвером»
`ProdEnvFlag`, який робив fallback у login-шелл (`zsh -l -i -c`) через `ShellEnvironment` і кешував
результат асинхронно на старті. Механізм працював, але виявився крихким: асинхронний subprocess на
кожному launch, залежність від того, що GUI-процес успадкує коректний `SHELL`, і гонка «прапорець
резолвиться вже після перших відкриттів меню». Діагностика показала, що навіть за правильного
відтворення це складно тримати надійним.

## Рішення

Прибрати env-механізм для dev-tools і зберігати прапорець як звичайне налаштування в `UserDefaults`,
поряд з рештою конфігу застосунку (`PersistedConfig`, ADR-0023):

- **Новий ключ `devToolsEnabled`** у `PersistedConfig` (`UserDefaults.standard`, домен = bundle id
  `com.artem-n.tokenpace`). Дефолт **off** (opt-in): `object(forKey:) as? Bool ?? false` — відсутній
  ключ читається як `false`, відрізняється від явного `false`, за конвенцією решти opt-in тумблерів.
- **`ColorStore.devToolsEnabled`** тепер `{ PersistedConfig.devToolsEnabled }` — синхронне читання з
  defaults, без shell-probe і без warm-up. GUI/login-запуск вшановує ключ так само, як термінальний.
- Env `TOKENPACE_DEVTOOLS` **більше не читається взагалі**.
- Вмикання: `defaults write com.artem-n.tokenpace devToolsEnabled -bool true` на встановленому `.app`.
  Settings-перемикача немає — це maintainer/dev-switch (пункт меню лишається ⌥-gated поверх прапорця).

`ProdEnvFlag` видалено (обидва його споживачі зникли). `TOKENPACE_GH_AUTH` повертається до свого
самостійного `AppDelegate.resolveGHAuth()` (`ProcessInfo` → `ShellEnvironment` login-shell fallback),
рівно як було до ADR-0052 — тобто **ADR-0025 знову чинний і не змінюється**. `ShellEnvironment`
лишається як login-shell probe для `TOKENPACE_GH_AUTH`.

Це формально **скасовує ADR-0052** (#201).

## Наслідки

- **Надійно й просто.** Гейт — синхронне читання `UserDefaults`; жодного subprocess, гонки чи
  залежності від `SHELL` при GUI-запуску. Однаково працює для Launchpad/Finder/логіну й термінала.
- **`defaults write … devToolsEnabled` діє лише на встановлений `.app`.** Бінарник із `swift run`
  bundle id не має, тож його `UserDefaults.standard` — інший домен. Тобто **`TOKENPACE_DEVTOOLS=1
  swift run` більше не вмикає dev-tools** — свідомий компроміс: dev-tuner тепер перевіряється на
  встановленому бандлі (де він і потрібен вживу), а для швидких перевірок лишаються стуб-змінні
  (`TOKENPACE_STUB`, `TOKENPACE_OPEN_DEVTOOLS`), які самі по собі не є гейтом.
- **`TOKENPACE_GH_AUTH` без змін.** `export` у `~/.zshrc` і далі вшановується при login-запуску через
  `resolveGHAuth`/`ShellEnvironment` (ADR-0025).
- Прапорець тепер персистентний між запусками (лишається `true`, доки не прибрати ключ), на відміну
  від env-var, який задавали щоразу.
