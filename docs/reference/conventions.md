# Конвенції розробки

## Мова

- **Документація — українська** (README, SPEC, docs/, ADR). Проєктне рішення (див.
  [ADR-0002](../adr/0002-ukrainian-documentation.md)).
- **Код** — англійською: ідентифікатори, коментарі, повідомлення комітів, рядки UI до
  локалізації.
- Ідентифікатори API (`five_hour`, `resets_at`, `client_id` тощо) — в оригіналі навіть в
  українському тексті.

## Стек

- **Swift** для всього проєкту (menu bar app, згодом iOS/watchOS). Див.
  [ADR-0001](../adr/0001-swift-stack.md).
- macOS: AppKit (`NSStatusItem`) + SwiftUI всередині (`NSHostingView`).
- **Мінімальний target: macOS 15 Sequoia.**
- **Збірка Фази 1:** Swift Package Manager + build-скрипт (bundle/sign/notarize). Xcode —
  у Фазі 2 для iOS/watchOS. Див. [ADR-0004](../adr/0004-build-system.md).
- **Тести:** `swift-testing` (`import Testing`, `@Test func`, `#expect(…)`) — `XCTest` недоступний
  на Command Line Tools без повного Xcode. `swift-testing` вбудований у Swift 6.1 CLT.

## Git

- Гілки: `<prefix>/<kebab-case>` (`feature/`, `bugfix/`, `docs/`, `refactor/` …).
- **Не комітити в `main` напряму.** PR проти `main` (не stacked).
- Повідомлення комітів — англійською.

### Git hooks

Хуки лежать у `.githooks/` (закомічені в репо). Увімкнути їх локально **одноразово** після клону:

```sh
git config core.hooksPath .githooks
```

`pre-commit` робить дві перевірки:

- **Swift build + test** — лише коли коміт торкається `*.swift` / `Package.swift`
  (docs-only коміти лишаються швидкими). Падіння збірки або тестів блокує коміт. Обійти
  навмисний WIP-коміт: `TOKENPACE_SKIP_SWIFT_HOOK=1 git commit …`.
- **PlantUML URL sync** — блокує коміт, якщо URL діаграм у `.md` розійшлися з джерелом
  (керується плагіном `plantuml`, між маркерами — не редагувати вручну).

## Версіонування

- SemVer 2.0.0.
- **Єдине джерело істини для версії застосунку** — файл `VERSION` у корені репозиторію
  (`CFBundleShortVersionString`). Старт: `0.1.0`. Build-number = кількість git-комітів
  (`git rev-list --count HEAD`). `TokenPaceKit.version` у коді дублює значення з `VERSION`
  і оновлюється разом із ним.

## UI-дизайн (AppKit + SwiftUI)

- **Мета: максимально слідувати дизайну рідних застосунків macOS** (System Settings передусім). Для
  стандартних системних елементів — **нуль захардкоджених** розмірів/шрифтів/відступів/кольорів;
  використовувати системні механізми (семантичні `NSColor`, `NSFont.systemFontSize`/text styles,
  `NSSwitch.controlSize`, `rowSizeStyle`/`NSTableViewDefaultSizeMode`, `NSStackView.firstBaseline`,
  `NSPathControl` тощо).
- **Вікно Settings — SwiftUI** `Form { Section }.formStyle(.grouped)` + `NavigationSplitView`, вбудований
  у `NSWindow` через `NSHostingController` (ADR-0042, #168) — як і сам System Settings. Grouped-inset
  картки, chip і time-picker більше **не** ручні AppKit-винятки: row height/padding/corner
  radius/dividers, grouped-фон, скруглений `DatePicker` дає система без жодної константи. Раніше тут були
  виміряні константи (`SettingsCard` тощо) — усунено. **Menu-bar-віджет і popup лишаються AppKit** (див.
  ADR-0009/0021/0022) — але **обидві поверхні тепер малюють системними semantic-кольорами**
  (`labelColor`-родина + `.system*`; menu-bar — ADR-0059, попап — ADR-0060), не фіксованим sRGB. Виняток —
  Claude-бренд-акцент попапа (`popupClaudeBrand`), який лишається sRGB.
- **Перед PR перевіряти в обох темах (light+dark) і всіх станах** (sidebar icon size, dev-білд/`.app`)
  скриншотами. Повний розбір, метод вимірювання й типові помилки —
  [system-settings-parity.md](system-settings-parity.md); рішення-принципи — ADR-0040 (нуль хардкоду),
  ADR-0042 (SwiftUI Form для Settings).
- **Перед комітом UI-зміни (menu bar popup, вікна, будь-який AppKit-екран) — звірити з актуальними
  Apple Human Interface Guidelines** (developer.apple.com/design/human-interface-guidelines).
  Не стверджувати деталі гайдлайну з пам'яті — HIG-сайт SPA-рендериться і часто не піддається
  прямому `WebFetch`; коли так, шукати через WebSearch офіційні сторінки/форуми Apple Developer, а
  не community-джерела, і чесно позначати межу впевненості, якщо точного офіційного числа не
  знайдено (див. ADR-0021 — приклад такого пошуку для типографії Troubleshoot-вікна).
- **Один кегль і одна гарнітура на весь дропдаун-попап**, вага (bold/regular) — єдина вісь, що
  розрізняє заголовки від звичайного тексту. Не підбирати розмір кастомного `NSTextField` "на око"
  проти нативного `NSMenuItem` — немає надійного способу *прочитати* реальний розмір, яким AppKit
  малює `NSMenuItem.title` (сайд-ефект Big Sur+ redesign; `NSFont.menuFont(ofSize:)` не збігається
  з рендером). Замість підбору — **один спільний конструктор** (`dropdownTextSize` у
  `PopupViewController.swift`), яким явно проставляється шрифт і кастомним лейблам, і нативним
  пунктам меню (через `NSMenuItem.attributedTitle`), щоб розбіжність була структурно неможливою.
  Див. ADR-0021.

## Безпека

- **Ніколи не комітити токени/креденшали.** `.credentials.json`, `secrets/` — у `.gitignore`.
- Токен не логувати, не виводити в UI, не передавати за межі Mac.

## Логування

- Усі логи йдуть через фасад `AppLogger` (`os.Logger`), subsystem `com.artem-n.tokenpace`,
  категорії `network`/`keychain`/`lifecycle`/`ui`. Не передформатовувати меседжі в `String` —
  лишати compile-time-інтерполяцію `os.Logger` із per-argument privacy.
- **Секрети ніколи не логувати** (OAuth-токени, payload Keychain). Лише безпечні діагностичні
  поля позначати `, privacy: .public`; решта redactиться як `<private>` за замовчуванням.
- **`docs/log-messages.md` — каталог усіх лог-меседжів.** Будь-яка зміна логування (новий
  виклик, видалення, зміна тексту меседжа чи рівня/категорії) **в тому самому коміті** оновлює
  відповідний рядок у `docs/log-messages.md` — включно з номерами рядків і підсумковими лічильниками.
- **Як дивитися логи (методи й пастки)** — див.
  [log-messages.md → Collecting logs](log-messages.md#collecting-logs--methods--gotchas). Головна
  пастка: `.notice`/`.info` **не** пишуться в store, тож `log show` їх не покаже — потрібен
  `log stream … --level debug` (без `--level debug` видно лише `.error`). Це стосується і підписаних
  release-білдів (вони логують так само).

## Верифікаційні env-змінні

Сімейство `TOKENPACE_*` перемикає застосунок у режими ручної верифікації. **Ніколи не встановлювати
в нормальному запуску** — усі вони лише для діагностики / скріншотів / прогонки UI-флоу.

- **`TOKENPACE_STUB`** = `1` / `screenshot` / `error` / … — підміняє живий `URLSession` канованим
  транспортом (`StubUsageTransport`), тож застосунок ганяється end-to-end без usage/status API й без
  Keychain (`1` — зростаюча утилізація; `screenshot` — застиглий кадр для README; `error` — 401 +
  деградовані сервіси). Повний перелік усіх стубів (idle, pacing-фрейми, calm-both тощо) — у
  [ui-verification.md](../guides/ui-verification.md).
- **`TOKENPACE_GH_AUTH`** (прапорець присутності, будь-яке непорожнє значення) — вмикає `gh`-шлях
  update-чеку (`GHReleaseFetcher`): `gh api …/releases/latest` як subprocess, `gh` бере токен із
  keyring. Для мейнтейнерів, поки репо приватне; без змінної — анонімний HTTPS (ADR-0025). Має власний
  login-shell-резолвер `AppDelegate.resolveGHAuth`: спершу `ProcessInfo` (термінал / `launchctl setenv`),
  а якщо там немає — з `~/.zshrc`/`~/.zprofile` через `ShellEnvironment` (`zsh -l -i`), бо застосунок
  часто стартує через launchd (login / Finder / Dock) **без шелла**, де `export …` невидимий через
  `ProcessInfo`. Тож достатньо `export TOKENPACE_GH_AUTH=1` у `~/.zshrc` — працює і в нотаризованому
  `.app`, запущеному з Finder/при логіні. Жодних `launchctl setenv`/LaunchAgent не потрібно.

> **Dev-tools вмикаються не через env-змінну.** ⌥-пункт «Development tools…» і live-колор-тюнер (#185)
> тепер гейтяться `UserDefaults`-ключем: `defaults write com.artem-n.tokenpace devToolsEnabled -bool true`.
> Ключ читається лише у **встановленому `.app`** (bundle id → правильний домен `UserDefaults`); у
> `swift run` бінарник без bundle id → інший домен, тож там ключ не діє (ADR-0053).
- **`TOKENPACE_FAKE_LATEST`** = `vX.Y.Z` — форсує канований «останній реліз» (`StubUpdateFetcher`)
  без мережі, щоб перевірити гілки «доступне оновлення» / «up to date». Пріоритетніший за
  `TOKENPACE_GH_AUTH` (ADR-0025).
- **`TOKENPACE_SKIP_SWIFT_HOOK`** = `1` — обходить Swift build/test у pre-commit-хуку (для навмисного
  WIP-коміту).

> **UserNotifications і запуск бандла.** Системний банер update-чеку працює лише в підписаному,
> встановленому `.app`, запущеному через LaunchServices (`open`), **не** прямим викликом бінарника
> `…/Contents/MacOS/TokenPace` — completion-хендлери `UNUserNotificationCenter` виконуються на
> не-main черзі, тож будь-який `@MainActor`-ізольований код у них падає `SIGTRAP`
> (`dispatch_assert_queue`). Логувати з таких хендлерів лише через `nonisolated`-хелпери (ADR-0025).

## Документація як частина коду

- Зміна модуля → оновити `docs/architecture.md`.
- Зміна логування → оновити `docs/log-messages.md` (див. секцію «Логування»).
- Рішення між двома підходами → новий ADR у `docs/adr/`.
- Нова конвенція/інструмент → оновити цей файл.
