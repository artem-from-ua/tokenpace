---
status: accepted
date: 2026-07-06
---

# ADR-0016: Перейменування проєкту cc-timer → TokenPace

## Контекст

Назва `cc-timer` («Claude Code timer») жорстко прив'язана до одного вендора, а продукт рухається до
vendor-neutral пейсингу token-вікон різних LLM-агентів (#60). Потрібна назва, що сигналізує «пейсинг
token/usage-вікон», не називаючи конкретного постачальника.

Шортлист (#60): `AgentPace`, `TokenPace`, `LLMeter`. Обрано **TokenPace** — «token» є спільною
одиницею для всіх LLM-вендорів. Доступність перевірено 2026-07-04: GitHub / npm / PyPI / App Store
вільні; домени `.io` / `.ai` / `.dev` вільні (`.com` / `.app` зайняті). Trademark-пошук не робився —
окремий крок перед публікацією в App Store.

Відкритим лишалося, як саме розкласти назву на ідентифікатори: bundle id (`dev.tokenpace.*` на базі
незареєстрованого домена чи наявний особистий префікс), регістр executable-таргета, доля локального
notarytool-профілю.

## Рішення

Повний ребрендинг у Фазі 1 (#61) з такими ідентифікаторами:

| Що | Було | Стало |
|---|---|---|
| Продукт / display name | cc-timer | **TokenPace** |
| SwiftPM package / executable-таргет | `cc-timer` | `TokenPace` (`swift run TokenPace`) |
| Бібліотека (таргет + namespace-enum) | `CCTimerKit` | `TokenPaceKit` |
| Тестовий таргет | `CCTimerKitTests` | `TokenPaceKitTests` |
| Bundle ID | `com.artem-n.cc-timer` | `com.artem-n.tokenpace` |
| os_log subsystem (= bundle id, інваріант) | `com.artem-n.cc-timer` | `com.artem-n.tokenpace` |
| Env var стаба транспорту | `CC_TIMER_STUB` | `TOKENPACE_STUB` |
| Env var обходу pre-commit hook | `CC_TIMER_SKIP_SWIFT_HOOK` | `TOKENPACE_SKIP_SWIFT_HOOK` |
| notarytool-профіль (локальний Keychain) | `cc-timer-notary` | `tokenpace-notary` |
| Репозиторій GitHub | `artem-from-ua/cc-timer` | `artem-from-ua/tokenpace` |
| Release-архів | `cc-timer-X.Y.Z.zip` | `TokenPace-X.Y.Z.zip` |

Ключові вибори:

- **Bundle id лишається на особистому префіксі** (`com.artem-n.tokenpace`), а не `dev.tokenpace.*`:
  домен `tokenpace.dev` не зареєстрований, тож reverse-DNS від нього був би фікцією. Поки продукту
  немає в App Store, змінити bundle id пізніше дешево; зробити це зараз на незакріплений домен —
  ризик без виграшу.
- **Executable-таргет — TitleCase `TokenPace`**: конвенція macOS-застосунків
  (`TokenPace.app/Contents/MacOS/TokenPace`), а не CLI-стиль lowercase.
- **Історія не переписується**: згадки `cc-timer`/`CCTimerKit` в ADR 0006–0015 (тіла
  Контекст/Рішення/Наслідки) лишаються як незмінний запис стану кодової бази на момент рішення.
  Перейменовуються лише живі доки (README, SPEC, architecture, building, conventions,
  log-messages, releasing).
- **Keychain-сервіс `"Claude Code-credentials"` не чіпається** — це ім'я айтема, який створює
  Claude Code CLI; воно не походить від назви нашого застосунку.

## Наслідки

- **Breaking для бібліотеки:** продукт `CCTimerKit` зникає — кожен `import CCTimerKit` міняється на
  `import TokenPaceKit`. Перейменування коду зроблено атомарно в одному PR, збірка не ламається
  посередині.
- **Осиротілий login item:** `SMAppService.mainApp` реєструється за bundle id, тож стара реєстрація
  `com.artem-n.cc-timer` лишається в System Settings → Login Items після встановлення TokenPace.app
  — прибирається вручну разом зі старим `.app`. Міграційного коду немає (свідомо: одноразовий
  ручний крок одного користувача). `UserDefaults` застосунок не використовує — інших втрат стану
  немає.
- **notarytool-профіль перестворюється вручну** (`xcrun notarytool store-credentials
  tokenpace-notary …` з новим app-specific password) — інакше нотаризація в `build-app.sh` тихо
  скіпається. Старий профіль `cc-timer-notary` нешкідливий, може лишатися.
- **Старі релізи не перейменовуються:** asset-и `cc-timer-*.zip` v0.11.0 і раніших лишаються як є;
  GitHub тримає редірект зі старого URL репозиторію.
- Згадки в тілах/коментарях GitHub-issues (відкритих і закритих) зачищаються окремим кроком після
  merge, крім історичних цитат (напр., naming-комент у #60).
