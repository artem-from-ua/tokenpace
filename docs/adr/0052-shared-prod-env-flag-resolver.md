---
status: accepted
date: 2026-07-31
---

# ADR-0052: Спільний резолвер prod-visible env-прапорців (`ProdEnvFlag`)

## Контекст

Кілька `TOKENPACE_*` env-прапорців мають бути видимі застосунку навіть при **login/GUI-запуску** —
через `SMAppService`, Finder, Dock, Launchpad, — коли launchd стартує бінарник `.app` **без шелла**, тож
`export TOKENPACE_FOO=1` у `~/.zshrc` **не** потрапляє в `ProcessInfo.processInfo.environment`.

Перший такий прапорець — `TOKENPACE_GH_AUTH` (ADR-0025): резолвиться спершу з `ProcessInfo` (запуск із
термінала / `launchctl setenv`), потім — fallback — із rc-файлів login-шелла через `ShellEnvironment`
(`zsh -l -i -c`). Так мейнтейнеру достатньо `export` у `.zshrc`, без `launchctl setenv`/LaunchAgent.

Коли `TOKENPACE_DEVTOOLS` (#185, розблоковує ⌥-пункт «Development tools…» і колор-тюнер) мав отримати ту
саму зручність, виявилося, що його гейт `ColorStore.devToolsEnabled` читав **лише `ProcessInfo`**. Тому
`export TOKENPACE_DEVTOOLS=1` у `.zshrc` працював для `swift run` (термінал успадковує env), але **не** для
встановленого `.app`, запущеного з Finder/при логіні — на відміну від `TOKENPACE_GH_AUTH`. Симптом:
«меню Dev Tools не з'являється під ⌥ у нотаризованому застосунку».

Замість дублювати `resolveGHAuth`-логіку ще раз — робимо **один спільний резолвер** для всіх prod-visible
прапорців, щоб майбутні випадки додавалися одним рядком.

Два питання цього ADR: (1) **єдина точка** резолву, і (2) **як не заблокувати** запуск і hot draw-path,
адже `ShellEnvironment` — це subprocess (типово <0.5 с, cap 5 с).

## Рішення

### Єдиний резолвер — `ProdEnvFlag`

`enum ProdEnvFlag: String, CaseIterable` — каталог prod-visible прапорців (`.ghAuth`, `.devTools`), де
`rawValue` — ім'я env-змінної. Додати майбутній прапорець = **один case**; жодного нового резолвера чи
плюмбінгу. І `ColorStore.devToolsEnabled`, і `AppDelegate.ghAuthEnabled` тепер — тонкі обгортки над
`ProdEnvFlag.isEnabled(_:)`; окремий `resolveGHAuth` видалено.

### Резолв — `ProcessInfo` синхронно, shell-fallback прогрітий раз off-main

`isEnabled(_:)` — **не блокуючий**, безпечний з будь-якого потоку (draw-path, poll):

1. **`ProcessInfo` спершу** — синхронно, на кожному читанні. Запуск із термінала / `launchctl setenv`
   вшановується миттєво, з нульовою вартістю на старті.
2. **Login-shell fallback** через `ShellEnvironment` — subprocess, тож **ніколи** на hot-path. Він
   виконується **один раз, off-main, при старті** в `ProdEnvFlag.warmUp` і результат кешується (під
   `NSLock`, `nonisolated(unsafe)`-словник). Синхронні читання **до** завершення прогріву бачать лише
   `ProcessInfo`.

### Прогрів (`warmUp`) — рано в `applicationDidFinishLaunching`, з ре-рендер-callback

`warmUp(then:)` пробує shell лише для прапорців, яких `ProcessInfo` не покрив, у `Task.detached(.utility)`,
тоді викликає completion на `@MainActor`. Викликається раз, на самому початку launch — паралельно з рештою
запуску. Completion робить `reRenderForCurrentTime()`, щоб override-залежне перемалювання лягло, щойно
probe резолвить прапорець.

### Наслідок для меню «Development tools…»

Раніше пункт створювався умовно (`if devToolsEnabled`) один раз на старті — з асинхронним прогрівом його б
не існувало, якщо прапорець резолвиться пізніше. Тепер пункт створюється **завжди** (прихований), а гейт
`TOKENPACE_DEVTOOLS` перевіряється в `updateTroubleshootVisibility` на **кожному** відкритті меню (разом з
⌥). Тож він з'являється, щойно прогрів резолвить прапорець, без перебудови меню.

### Чому не sync-резолв до першого рендеру

Синхронний shell-probe до першого малювання дав би коректний стан із першого кадру, але додав би до ~5 с
(типово <0.5 с) до **холодного GUI-старту для всіх** користувачів — бо probe запускається завжди, коли
`ProcessInfo` порожній, навіть для тих, хто жодного `TOKENPACE_*` не має. Це регрес старту заради dev-фічі.
Async-прогрів натомість ніколи не блокує старт; ціна — dev-меню/override-и стають активними за частку
секунди після запуску (для звичайного користувача ефекту нема — прапорці завжди `false`).

## Наслідки

- `export TOKENPACE_DEVTOOLS=1` у `~/.zshrc` тепер розблоковує dev-tools і у встановленому `.app`
  (Finder/login-запуск), як і `TOKENPACE_GH_AUTH` — без `launchctl setenv`/LaunchAgent.
- Один шлях резолву для всіх prod-visible прапорців; майбутній додається одним case у `ProdEnvFlag.all`.
- `devToolsEnabled` став `var` (обгортка) замість `static let` (мемоізований probe) — вартість читання
  лишається дешевою (env-read + lookup під локом), безпечна на draw-path.
- Лог `env: <TOKENPACE_VAR> found in login shell env` (`.notice`, `lifecycle`) з `warmUp` заміняє
  попередній `update: TOKENPACE_GH_AUTH found in login shell env` — тепер спільний для всіх прапорців.
- `ShellEnvironment` (ADR-0025) лишається незмінним низькорівневим примітивом; `ProdEnvFlag` — політика
  поверх нього (які прапорці, коли прогрівати, як кешувати).
