# Збірка з джерел

Для контриб'юторів. Кінцевим користувачам збирати не треба — є готовий нотаризований `.app`
у [релізах](https://github.com/artem-from-ua/cc-timer/releases) (див. README).

## Передумова

Swift 6.1+ і Command Line Tools. Повний Xcode **не потрібен** у Фазі 1.

## Розробка

```sh
swift build        # збірка
swift test         # unit-тести
swift run          # запуск агента (без вікна; зупинити — Ctrl-C)
```

## Зібрати `.app` bundle

```sh
./scripts/build-app.sh    # → ./build/cc-timer.app
open ./build/cc-timer.app # запуск (іконки в Dock немає — LSUIElement)
```

Скрипт збирає **universal binary** (arm64 + x86_64), тож `.app` запускається нативно і на Apple
Silicon, і на Intel-Mac (SwiftPM не має єдиного `--arch`, тож кожна арка збирається окремо за
`--triple` і зливається через `lipo`).

Застосунок запускається як **accessory-агент** без іконки в Dock (`LSUIElement = true`):
дві pacing-смужки в menu bar, клік відкриває popup із деталями, а внизу — `Settings…` (toggle
автозапуску, версія, GitHub-лінк) і `Quit cc-timer`.

## Підпис і нотаризація

`build-app.sh` автоматично підписує bundle Developer ID identity (якщо є) з `--options runtime` і,
якщо налаштовано notarytool-профіль `cc-timer-notary`, нотаризує та прикріплює (staple) квиток.
Перевірити: `spctl -a -t exec ./build/cc-timer.app` → `accepted (Notarized Developer ID)`. Без
Developer ID identity збірка лишається непідписаною — Gatekeeper може заблокувати при першому
запуску (`права кнопка → Відкрити`, або `xattr -dr com.apple.quarantine ./build/cc-timer.app`).

Повна процедура релізу — [docs/releasing.md](releasing.md).

## Launch-at-login

`SMAppService` реєструє автозапуск надійно лише для **підписаного** `.app`, **запущеного з
`/Applications`** (через Finder/Launchpad). На `swift run` чи прямому запуску бінарника статус буде
`.notFound` і toggle у `Settings…` — неактивний (з поясненням).

## Перегляд логів

```sh
log stream --predicate 'subsystem == "com.artem-n.cc-timer"' --info
```

або Console.app з фільтром `com.artem-n.cc-timer`.
