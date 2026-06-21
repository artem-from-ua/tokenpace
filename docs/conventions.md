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

## Версіонування

- SemVer 2.0.0.
- **Єдине джерело істини для версії застосунку** — файл `VERSION` у корені репозиторію
  (`CFBundleShortVersionString`). Старт: `0.1.0`. Build-number = кількість git-комітів
  (`git rev-list --count HEAD`). `CCTimerKit.version` у коді дублює значення з `VERSION`
  і оновлюється разом із ним.

## Безпека

- **Ніколи не комітити токени/креденшали.** `.credentials.json`, `secrets/` — у `.gitignore`.
- Токен не логувати, не виводити в UI, не передавати за межі Mac.

## Документація як частина коду

- Зміна модуля → оновити `docs/architecture.md`.
- Рішення між двома підходами → новий ADR у `docs/adr/`.
- Нова конвенція/інструмент → оновити цей файл.
