---
status: superseded
date: 2026-06-22
superseded_by: [0018]
---

# ADR-0012: Вікно «Configure…» та launch-at-login (SMAppService)

> **Частково superseded [ADR-0018](0018-launch-at-login-notfound-recovery.md):** Рішення §4 у частині
> «Недоступність — видима, не мовчазна» (трактування статусу `.notFound` як термінального → сірий
> дизейблений чекбокс) скасовано. `.notFound` повертається **і** після заміни бандла при оновленні,
> а не лише на `swift run`; тепер чекбокс завжди клікабельний і `register()` сам вирішує (#69). Решта
> цього ADR (окреме вікно, розкол pure-core / thin-shell, opt-out, best-effort на unsigned, меню-дії)
> лишається чинною; тіло збережено в історичному вигляді.

> **Примітка (пізніша зміна):** пункт меню та вікно пізніше перейменовано `Configure…` → `Settings…`
> (тип `ConfigureWindowController` → `SettingsWindowController`). Рішення лишається чинним — змінилася
> лише назва-мітка; тіло цього ADR збережено в історичному вигляді.

> **Примітка (2026-07-22, [ADR-0020](0020-troubleshoot-window-and-diagnostics-pipeline.md)):**
> §5/§7 у частині «пункти без шортката (`keyEquivalent=""`)» більше не так. «Settings…» отримало
> `⌘,`, «Quit TokenPace» — `⌘Q`: непорожній keyEquivalent — **обов'язкова** передумова нативного
> ⌥-alternate («Troubleshoot…»), тож видимий гліф тепер свідомий. Тіло цього ADR історичне.

## Контекст

Issue #14 («launch-at-login + Quit») — останній інфраструктурний пункт Фази 1. Потрібні мінімальні
налаштування: автозапуск при логіні через `SMAppService.mainApp` і пункт виходу. Користувач уточнив
обсяг ширше за початковий тікет: внизу детального popup-меню — два пункти `Configure…` та
`Quit cc-timer`, де `Configure…` відкриває **окреме вікно налаштувань** (toggle автозапуску, версія,
посилання на репозиторій).

Це породжує кілька рішень того ж класу, що в ADR-0009…0011 (де межа модуля, що тестується, що — ні),
плюс два, специфічні для цього тікета:

1. **Вікно налаштувань усупереч SPEC.** SPEC.md прямо каже «Без екрана налаштувань» (лише перемикач
   launch-at-login + Quit як «розумні дефолти»). Рішення користувача свідомо це перевизначає.
2. **Політика автозапуску** — реєструвати на старті (opt-out) чи лише за явним кліком (opt-in).
3. **Як показати дії** — окремі `NSMenuItem` під hosted-popup чи кнопки всередині hosted-view.
4. **Як відкрити вікно з accessory-app** (немає Dock, `.accessory` policy).
5. **`SMAppService` — системний синглтон**, який неможливо інжектувати/мокнути: де межа тестованого.

## Рішення

1. **Окреме вікно `Configure…` (попри SPEC «без екрана»).** Перемикач автозапуску потребує *якоїсь*
   афордансу; вікно виявніше за меню-checkbox і дає природне місце для версії та посилання на
   репозиторій. Це свідоме відхилення від SPEC.md, зафіксоване тут. Вміст Фази 1: toggle
   «Launch cc-timer at login», рядок `Version <CCTimerKit.version>`, GitHub-лінк.

2. **Чисте ядро `LaunchAtLogin` у `CCTimerKit` + glue `LaunchAtLoginController` у `cc-timer`** — той
   самий розкол pure-core / thin-shell, що `UsageHealth` (ADR-0010) і `AdaptiveCadence` (ADR-0011).
   `SMAppService` не інжектується, тож код, що *викликає* `register()`/`unregister()`/`status`, живе в
   executable і перевіряється вручну (як `PollingShell`). Тестується лише чиста семантика:
   - `LaunchAtLogin.Status` — framework-free дзеркало `SMAppService.Status`
     (`registered`/`notRegistered`/`requiresApproval`/`notFound`).
   - предикати `shouldRegisterOnFirstLaunch` / `toggleState(for:)` / `needsSystemSettings`
     (табличні тести `LaunchAtLoginTests`).

3. **Opt-out автозапуск на першому старті.** Якщо статус `.notRegistered` → `register()` автоматично;
   інші статуси не чіпати (користувач/система вже вирішили). Результат логується через
   `AppLogger.lifecycle` (`.notice` для подій, `.error` для збоїв, `privacy: .public` для деталей).

4. **Best-effort на unsigned — ключове обмеження.** `SMAppService.mainApp` надійний **лише на
   підписаному** `.app` bundle. Наслідки за типом білда:
   - `swift run` (bare-бінар без bundle) → статус `.notFound` → opt-out **не** реєструє (нема чого);
     toggle показується off. Це коректно, не баг.
   - unsigned `.app` (без Developer ID, як на особистому MVP) → `register()` ненадійний: може кинути
     помилку або не активувати login-item; toggle може лишатись off навіть після кліку.
   - підписаний `.app` (Developer ID) → автозапіс і toggle працюють надійно.

   Тому будь-який виклик `register()`/`unregister()` обгорнутий у `do/catch`: throw логуєтьсяй і
   **ніколи** не валить застосунок. Повна надійність очікується після підпису (SPEC §«Обсяг Фази 1»).

   **Недоступність — видима, не мовчазна.** Коли статус `.notFound` (немає реєстровного login item
   для цієї code identity — `swift run` або ad-hoc bundle), предикат `LaunchAtLogin.isAvailable`
   повертає `false`: вікно **дизейблить** чекбокс (сірий) і показує пояснення поряд — встановити
   `cc-timer.app` і запускати через Launchpad/Finder, не дев-білд. Так користувач не клікає
   перемикач, що нічого не робить. На доступних статусах hint чесно зазначає best-effort на unsigned.

5. **Окремі `NSMenuItem` під hosted-popup (рішення користувача, для оцінки на вигляд).** `separator`
   + `Configure…` + `Quit cc-timer` у тому ж `NSMenu`, обидва `keyEquivalent=""` (без шортката),
   `target=self`. Альтернатива — кнопки всередині hosted-view попапа (єдиний візуальний блок, але
   власна hover-підсвітка + `cancelTracking`) — лишається запасним варіантом, якщо вигляд окремих
   пунктів не влаштує.

6. **Без `setActivationPolicy(.regular)` для вікна.** Accessory-app виводить вікно на передній план
   через `NSApp.activate(ignoringOtherApps:)` + `window.level = .floating` + `makeKeyAndOrderFront`.
   Перемикання на `.regular` додало б миготливу Dock-іконку заради одного вікна. Вікно —
   single-instance (`isReleasedWhenClosed = false`, поле `configureWC`): повторний клік фокусує
   наявне, не створює друге.

7. **Quit через стандартний `NSApplication.shared.terminate(nil)`** — гарантує виклик
   `applicationWillTerminate` (cleanup pollTask/ageTimer/sleepWake/network, без змін). Дефолтного ⌘Q
   немає, бо немає головного меню (`.accessory` + жодного `setMainMenu`) — прибирати нічого не треба.

## Наслідки

- `CCTimerKit` лишається без AppKit/ServiceManagement: `LaunchAtLogin` оперує лише семантикою →
  реюз у Фазі 2 (iOS/watchOS можуть мати власну реєстрацію за тим самим enum/предикатами).
- Тестове покриття фічі — лише три предикати (`LaunchAtLoginTests`); усе SMAppService/NSWindow/NSMenu
  glue — manual verification, як домовлено конвенцією (ADR-0009 §8).
- Toggle при кожному показі вікна ре-синкається з `SMAppService.status` (`syncToggleFromSystem`), бо
  користувач міг змінити стан у System Settings. На `.requiresApproval` після `register()` вікно веде
  в System Settings → Login Items (`openSystemSettingsLoginItems`).
- **Відоме обмеження:** на unsigned білді автозапуск — best-effort (див. Рішення §4). Перевіряти
  реальну реєстрацію треба на підписаному `.app`; на dev-білді toggle off — очікувано.
- **Перевірено (2026-06-22):** на Developer ID-підписаному й **нотаризованому** `.app`, запущеному
  з `/Applications`, `SMAppService.status` → `.enabled`, toggle активний і ввімкнений; opt-out на
  першому старті спрацьовує. `swift run` / прямий запуск бінарника → `.notFound` (очікувано).
  Налаштування підпису+нотаризації — у `scripts/build-app.sh` (ADR-0004).
- Якщо у Фазі 2 з'являться додаткові налаштування (інтервал, теми) — розширюється те саме вікно;
  нове рішення про зміст/поведінку → нова секція тут або окремий ADR.

## Пов'язані

- [ADR-0002](0002-ukrainian-documentation.md) — мова документації (це вікно лишається без локалізації у Фазі 1).
- [ADR-0004](0004-build-system.md) — bundle/Info.plist/підпис; `SMAppService` залежить від валідного підписаного bundle.
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md), [ADR-0010](0010-usage-health-and-error-states.md), [ADR-0011](0011-polling-engine-adaptive-cadence-and-signal-seams.md) — той самий розкол pure-core / thin-shell і «glue не тестується».
