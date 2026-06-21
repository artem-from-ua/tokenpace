---
status: accepted
date: 2026-06-22
---

# ADR-0008: UsageClient — чистий backoff, інжекція токена і transport-seam

## Контекст

Issue #9 описує `UsageClient` як HTTP-клієнт для `GET /api/oauth/usage` з обов'язковим
`User-Agent` і backoff при 429. Дві деталі обсягу неочевидні й вимагають свідомого рішення про
межі модуля — той самий клас рішень, що й [ADR-0005](0005-pacing-fractions-not-blocks.md),
[ADR-0006](0006-reset-time-absolute-vs-relative.md) і
[ADR-0007](0007-token-provider-throws-and-scope-split.md).

1. **Де живе backoff.** SPEC «Частота оновлення» віддає *таймер* опитування тікету #13
   (sleep/wake + мережа): саме polling-шар планує наступне пробудження, реагує на сон/прокидання
   й мережу. Але acceptance-критерій #9 явно вимагає «Backoff працює (unit-тест на логіку
   інтервалів)». Якщо backoff жив би всередині асинхронного `fetch` (який спить і ретраїть),
   протестувати інтервали без живого годинника й мережі було б важко.

2. **Звідки `UsageClient` бере токен і як тестувати мережу.** `UsageClient` залежить від
   `TokenProvider` (#8), але за архітектурою *оркеструє* саме polling-шар. Якщо `fetch` сам читає
   Keychain, мережевий шар зчіплюється з Keychain-I/O і `Security`, а unit-тести вимагають мокати
   Keychain. Окремо постає питання, як проганяти `fetch` без походу на `api.anthropic.com`.

## Рішення

1. **Backoff — чиста value-type стейт-машина `PollingBackoff`, без таймера й сну.** Модель стану
   — один `level: Int?` (`nil` == healthy → 180 с; інакше індекс у `steps`). Переходи
   детерміновані й без побічних ефектів: `escalated()` піднімає крок (`nil→0→1→2→3`, тримати 3),
   `reset()` повертає на 180 с, `interval` — похідна. Кроки 429 зберігаються **в секундах**
   (`[3, 6, 12, 15] × 60 = [180, 360, 720, 900]`) — кодування хвилини-vs-секунди load-bearing і
   стережеться тестом `stepsAreInSeconds`. `fetch` **не спить і не ретраїть** — повертає снапшот
   або кидає `UsageError`; просуває backoff і планує наступне пробудження polling-шар (#13). Так
   уся логіка інтервалів юніт-тестована в ізоляції, як `PacingModel`.

2. **Токен інжектиться ззовні як `String`.** `fetch(accessToken:now:transport:)` приймає готовий
   bearer-токен; polling-шар (#13) сам викликає `TokenProvider.currentAccessToken(now:)`, обробляє
   `.expired` (періодично перечитує Keychain, поки Claude Code не перезапише айтем) і передає
   свіжий токен. `UsageClient` не імпортує `Security`/Keychain і тестується з літеральним токеном.

3. **Чисті seam'и `buildRequest`/`decode` окремо від мережевого `fetch`** — той самий поділ
   pure/I/O, що в `TokenProvider` (`decode` окремо від `readRawData`). `buildRequest` несе
   конструкцію всіх чотирьох заголовків і guard «без `User-Agent` не ходити» (кидає
   `.missingUserAgent` перед будь-якою мережею); `decode` — розбір JSON у `UsageSnapshot`. Обидва
   тестуються без мережі. Internal-overload `buildRequest(…, userAgent:)` дає змогу негативного
   тесту guard'а порожнім рядком — публічний шлях завжди передає непорожню константу версії.

4. **`URLSession` інжектиться через мінімальний протокол `UsageTransport`** (одна async-функція;
   `URLSession` уже має цю сигнатуру), а не через сабкласинг `URLProtocol`. Дефолт —
   `URLSession.shared` (ідіома проєкту «інжекція залежності з дефолтом»). Тести підставляють
   `StubTransport`, що повертає канонізований `(Data, HTTPURLResponse)` — гермечно, без живого HTTP.

## Наслідки

- Уся логіка backoff покрита unit-тестами (`PollingBackoff`: прогресія, hold-стелі, reset,
  кодування в секундах), не чекаючи на polling-шар #13. #13 лише читає `interval` і викликає
  переходи.
- `UsageClient` лишається без Keychain/`Security`; помилки токена обробляє оркестратор. Чітке
  розділення: `UsageError` несе лише мережеві/декод-причини, `TokenError` — Keychain-причини.
- `fetch` тестується через `UsageTransport`-stub на всіх гілках (200/429/401/5xx/transport/non-HTTP/
  malformed) без походу в мережу; жоден тест не б'є по `api.anthropic.com`.
- `resets_at` не парситься в `UsageClient` — зберігається сирим рядком і йде в `ResetClock.parse`
  (#7), щоб нормалізація дат лишалась в одному місці.
- Токен ніколи не логується: `AppLogger.network` несе лише `.public`-діагностику (HTTP-статус,
  `retryAfter`, статичні рядки); заголовок `Authorization` будується, але в логер не передається.
- `PollingBackoff.escalated(retryAfter:)` шанує серверний `Retry-After`, довший за розклад
  (стрибок до першого кроку ≥ хінта або стеля) — стан лишається плоским `level`, тож `reset`
  працює без змін.
- Якщо в Фазі 2 зміниться політика опитування (інші інтервали для віджетів/комплікейшена) або
  з'явиться кешування (`If-Modified-Since` — `now` уже прокинутий у `buildRequest` під це) — це
  нове рішення → нова секція тут або окремий ADR.
