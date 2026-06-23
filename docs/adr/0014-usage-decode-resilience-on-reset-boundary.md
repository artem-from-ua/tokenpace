---
status: accepted
date: 2026-06-23
---

# ADR-0014: UsageSnapshot — синтез вікна на межі ресету замість падіння decode

## Контекст

У релізі v0.10.0 popup періодично показував **«Usage API unavailable — retrying…»**, хоча сервіси
Claude були operational, а бари застигали на старих даних. Дебаг по логах
(`log show --predicate 'process == "cc-timer"'`) показав, що це **не** збій API:

- HTTP-статус відповіді — **200** (CFNetwork: `response_status=200`, `cache_hit=true`).
- Але `UsageClient.decode` тричі поспіль кидав `usage decode failed`.
- Збій трапився **рівно на переході 5-годинного вікна через ресет** (`five_hour` 29% → 1%, новий
  `resets_at`), тривав ~7 хв і відновився сам.

Корінь: модель `UsageSnapshot`/`UsageWindow`/`UsageLimit` декодувала core-вікна
(`five_hour`/`seven_day`) як **обов'язкові** значення. На межі ресету API легально присилає в тілі
200 `null` там, де модель вимагає значення. Перевірено пробами проти живого тіла — кожен із цих
випадків валив **увесь** snapshot:

| Тіло 200 | Старий decode |
|---|---|
| `five_hour: null` / `seven_day: null` | падає (`valueNotFound`) |
| `five_hour` відсутній | падає (`keyNotFound`) |
| `utilization: null` усередині вікна | падає |
| елемент `limits[]` без `severity` / з `percent: null` | падає |

Помилка `UsageError.decode` мапиться у `FailureReason.serverProblem`
([ADR-0010](0010-usage-health-and-error-states.md)) → «Usage API unavailable». Повідомлення вводить
в оману: API доступний, ми просто не змогли прочитати **перехідне** тіло. А ще бари ховалися/застигали
саме тоді, коли вікно реально скинулось і мало б показати свіжі 0%.

Постало рішення між трьома підходами до `null`-вікна:

1. **Падати** (статус-кво) — найпростіше, але дає хибне «unavailable» на кожному ресеті.
2. Зробити core-вікна **optional** (`nil` при `null`) — не валить snapshot, але ховає бар саме на
   ресеті, коли користувач очікує побачити оновлення.
3. **Синтезувати** свіже порожнє вікно — на межі ресету вікно реально порожнє (`utilization = 0`),
   тож це семантично правдиве заповнення, а не маскування помилки.

## Рішення

**Синтезувати свіже вікно з `utilization = 0`, коли core-вікно приходить `null`/відсутнє/без
`resets_at`** — варіант 3. Логіка живе в одному місці, `UsageSnapshot.init(from:)` (custom decoder),
щоб увесь downstream (health, popup, menu bar) отримував уже нормалізований snapshot і не знав про
крайній випадок.

1. **`utilization = 0`** — щойно скинуте вікно має нульове використання. Це правда, не заглушка.

2. **`resets_at` за fallback-ланцюгом:**
   1. власний `resets_at` об'єкта вікна, якщо він є (випадок `utilization: null`) — взяти як є;
   2. інакше з `limits[]` за `kind` (`session`/`five_hour` → 5h; `weekly_all`/`seven_day` → 7d) —
      ці записи дублюють той самий `resets_at` у тій самій відповіді (не розрахунок);
   3. інакше локальна оцінка `ResetClock.nextReset(now:window:)` = `now + durationSeconds`,
      **округлена вгору до 10 хв** (груба точність чесно відображена грубим округленням).

3. **Кожен синтез логується** (`AppLogger.network.notice("synthesized … resets_at source=…")`), а
   при справжньому decode-fail логується **обрізане тіло** (через наявний `responseText`, cap 500) —
   щоб майбутня неанонсована зміна схеми API діагностувалася з логів, а не з здогадок (раніше
   `decode` писав лише «usage decode failed» без тіла, а `os_log` обрізає довге success-тіло до
   ~1 КБ).

4. **`limits[]` — усі поля стійкі** (`decodeIfPresent` + дефолти). Масив ніде не споживається
   downstream (лише future-proofing), окрім як джерело fallback `resets_at`, тож `null` в одному
   полі не сміє валити snapshot. Нові поля API (`scope`, `seven_day_oauth_apps`, `tangelo`, …)
   ігноруються `Decodable`, як і раніше.

5. **`now` для оцінки — через `JSONDecoder.userInfo`** (`CodingUserInfoKey.usageNow`), щоб шар
   decode лишався тестованим і не кликав `Date()` всередині (дух чистих шарів,
   [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md)). `UsageClient.decode(from:now:)`
   прокидає реальний `now`; default — `Date()` лише для call-site без годинника (тести).

Повідомлення «unavailable» **не** змінюється: після стійкого decode гілка `.decode` спрацьовуватиме
лише на справді зламаному тілі (не-JSON, обрізане), де «server problem» доречне. Окрему причину
`malformedResponse` свідомо не вводимо зараз — якщо гілка все ж з'явиться в логах, заведемо окремо.

## Наслідки

- **Звичайний ресет більше не дає хибного «Usage API unavailable».** Бар показує свіжі 0% з
  коректним часом до наступного ресету.
- **Стійкість до майбутніх змін схеми API.** Відсутнє/`null` поле деградує елегантно замість падіння;
  лог тіла при decode-fail дає доказ замість здогадок.
- **`utilization` тепер tolerant до `null`, але не до неправильного типу** — `utilization: "13"`
  (рядок) усе ще падає (type-mismatch), що ловить тест `utilizationAsStringThrowsDecode`. Це навмисно:
  ми пробачаємо лише `null` на межі ресету, не приховуємо реальні баги серіалізації.
- **Старий контракт «падати на відсутньому вікні» змінено** — два тести (`missingFiveHourThrowsDecode`/
  `missingSevenDayThrowsDecode`) переписані на тести синтезу; додано regression-тест на повне живе
  тіло й unit-тести `ResetClock.nextReset`.
- Пов'язано з [ADR-0008](0008-usageclient-pure-backoff-and-transport-seam.md) (decode-шар
  `UsageClient`) і [ADR-0010](0010-usage-health-and-error-states.md) (мапінг помилок у стани UI).
