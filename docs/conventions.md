# Конвенції розробки

## Мова

- **Документація — українська** (README, SPEC, docs/, ADR). Проєктне рішення (див.
  [ADR-0002](adr/0002-ukrainian-documentation.md)).
- **Код** — англійською: ідентифікатори, коментарі, повідомлення комітів, рядки UI до
  локалізації.
- Ідентифікатори API (`five_hour`, `resets_at`, `client_id` тощо) — в оригіналі навіть в
  українському тексті.

## Стек

- **Swift** для всього проєкту (menu bar app, згодом iOS/watchOS). Див.
  [ADR-0001](adr/0001-swift-stack.md).
- macOS: AppKit (`NSStatusItem`) + SwiftUI всередині (`NSHostingView`).
- **Мінімальний target: macOS 15 Sequoia.**
- **Збірка Фази 1:** Swift Package Manager + build-скрипт (bundle/sign/notarize). Xcode —
  у Фазі 2 для iOS/watchOS. Див. [ADR-0004](adr/0004-build-system.md).
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

## Документація як частина коду

- Зміна модуля → оновити `docs/architecture.md`.
- Зміна логування → оновити `docs/log-messages.md` (див. секцію «Логування»).
- Рішення між двома підходами → новий ADR у `docs/adr/`.
- Нова конвенція/інструмент → оновити цей файл.
