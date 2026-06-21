# CLAUDE.md

Інструкції для Claude Code (та інших AI-агентів) під час роботи в цьому репозиторії.

## Що це за проєкт

`cc-timer` — мінівіджет для menu bar macOS, що показує використання лімітів підписки Claude Code
(5-годинного та 7-денного вікон) з *pacing* і часом до найближчого ресету. Згодом — віджети
iPhone та комплікейшен Apple Watch.

**Джерела істини (читати перед роботою):**

- [SPEC.md](SPEC.md) — повний продуктовий спек: архітектура, UI, поведінка, обсяг Фази 1, план робіт.
- [docs/architecture.md](docs/architecture.md) — архітектура та потік даних.
- [docs/conventions.md](docs/conventions.md) — конвенції розробки.
- [docs/adr/](docs/adr/) — архітектурні рішення (Swift, українська дока, закритий агент, збірка).

## Мова

- **Документація — українська** (README, SPEC, docs/, ADR, GitHub issues). Див.
  [ADR-0002](docs/adr/0002-ukrainian-documentation.md).
- **Код, ідентифікатори, повідомлення комітів, PR — англійська.**
- Ідентифікатори API (`five_hour`, `resets_at`, `client_id`) — в оригіналі навіть в укр. тексті.

## Стек і збірка

- **Swift 6.1+**, мінімальний target **macOS 15 Sequoia**.
- Фаза 1: **Swift Package Manager** + build-скрипт (`.app` bundle, опційний підпис/notarization).
  Повний Xcode не потрібен — `swift build` / `swift run` працюють із Command Line Tools.
- macOS UI: AppKit `NSStatusItem` з кастомним малюванням (не `MenuBarExtra`).
- Фаза 2 (iOS/watchOS): додається Xcode project. Див. [ADR-0004](docs/adr/0004-build-system.md).

## Команди

```sh
swift build        # збірка
swift test         # unit-тести (PacingModel, парсинг/формат часу, backoff)
swift run          # запуск
```

## Критичні правила

- **Ніколи не комітити токени/креденшали.** Токен лежить у macOS Keychain
  (`Claude Code-credentials`); він **не покидає Mac**. Не логувати, не виводити в UI.
- **Обов'язковий заголовок `User-Agent: claude-code/<version>`** на кожному запиті до
  `GET /api/oauth/usage` — інакше агресивний rate-limit (429).
- **Не комітити в `main` напряму.** Робота — через feature-гілки (`<prefix>/<kebab>`) і PR проти
  `main` (не stacked).
- **Доки — частина коду.** Зміна модуля → оновити `docs/architecture.md`; нове рішення між
  підходами → новий ADR.
- **Не стверджувати з пам'яті** факти про зовнішні API/інструменти — перевіряти (curl/--help/docs).

## Робочий процес

Робота Фази 1 розбита на тікети (Epic + дочірні issues, GitHub Project). Виконання — **по одному
тікету в окремих сесіях**, у рекомендованому порядку (див. Epic / план у `SPEC.md`).
