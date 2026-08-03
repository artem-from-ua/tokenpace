---
status: accepted
date: 2026-08-04
---

# ADR-0067: Локальний журнал використання (append-only JSONL)

## Контекст

TokenPace опитує `GET /api/oauth/usage` кожні 3 хв (15 хв в idle, ADR-0032), рендерить результат і
**викидає** його. На `main` (v0.64.0) нічого, крім `LogArchiver` (ADR-0031), не пише на диск, а всі
ключі `PersistedConfig` — це конфіг або одно-значні edge-маркери (`backToWorkWasBlocked`,
`extraUsageWasOnCredits`, `lastArchiveSync`) — достатньо, щоб зловити edge, ніколи — щоб тримати
часовий ряд. Тож застосунок відповідає на «чи я в темпі *зараз*» і не відповідає на жодне питання з
*учора* в ньому.

Issue [#238](https://github.com/artem-from-ua/tokenpace/issues/238) (Insights-епік) пропонує **один
append-only журнал**, який три downstream-фічі (#239/#240/#241) читають, замість того, щоб кожна
ростила своє сховище. Це ADR фіксує рішення для кроку 1
([#242](https://github.com/artem-from-ua/tokenpace/issues/242)) — колектор і сховище.

Розвилки: (1) формат і механізм сховища; (2) що саме зберігати — сирі поля чи й похідні стани; (3)
default-on чи off; (4) локація; (5) як пережити кілька інстансів застосунку, що пишуть одночасно.

## Рішення

**Append-only JSONL під Application Support, default-off, гетерогенні `kind`-рядки з сирими полями +
похідними станами, помісячна ротація за іменем файлу, flock між інстансами.**

### 1. Формат — append-only JSONL, гетерогенні `kind`-рядки

Один об'єкт на рядок, тегований `kind`: `usage` (успішний usage-полл), `error` (неуспішний:
429/timeout/network/auth/JSON-parse), `status` (окремий status-полл), `resume` (маркер розриву).
Декод **толерантний** (як `MonitoredServices`/`StatusSummary`): невідомий `kind`/ключ →
ігнорується, не throw; нові поля додаються як нові ключі. Читач (`JournalReader`) толерує
зіпсований/недописаний хвостовий рядок (crash mid-append) — пропускає, не падає.

**Не App Group.** ADR-0065 (WidgetKit, `draft`) планує писати снапшот у App Group container, але це
не реалізовано і має відкрите питання (App Group без повного sandbox). Журнал — перший запис
декодованого снапшоту на диск; він не чекає на віджет.

### 2. Зміст — сирі поля **та** похідні стани, які застосунок показує на UI

Downstream не має перераховувати те, що app уже обчислив. `usage`-рядок несе: усі 4 вікна
(`utilization`+`resets_at`), per-model `weekly_scoped` ліміти, `sessionIdle`, повний `SpendInfo`
(`Money` як `amount_minor`+`currency`+`exponent`, без втрати центів) — **плюс** похідні: `timePct`
(elapsed-фракція), `gap` (`timePct·100 − util` — pacing-запас у пунктах, для всіх лімітів і кредитів
з лімітом; очікувано популярна метрика, тож precompute), `sev` (об'єктивний колір-бакет), credits
`spentFrac`/`monthPct`/`creditGap`, `blocked`/`credits`-прапорці, `hasBrokenActiveReset`,
`BlockingReset.Choice`. Плюс `ms` — latency відповіді API.

**`sev` — «режим контролфріка».** Колір-бакет (`blue`/`green`/`yellow`/`orange`/`red`,
`PacingBucket`) обчислюється з сирих даних **незалежно від користувацьких косметичних налаштувань**
(`CalmColorMode` не застосовується — користувач може вимкнути синій чи увімкнути calm-muting), з
єдиним винятком: синьо-зелений поріг за формулою medium (2h/5h, 3d/7d — `behindThreshold`), а не за
`FarBehindInterval`. Так série лишається порівнянним між користувачами.

**Помилки — journal-таксономія, не UI.** `error.reason` розрізняє точніше за збіднений
`FailureReason`: **4xx→`clientProblem`** (429 — rate-limit на боці клієнта), **5xx→`serverProblem`**,
**decode→`decode`** (malformed 200), **401/403→`auth`**, transport → `timeout`/`dns`/`network`.

### 3. Default-off + Settings-тумблер

Дзеркалить `archiveEnabled` (ADR-0031): opt-in, інертний доки не ввімкнено. Журнал пише відсотки/суми
(не транскрипти), тож приватність слабша за архіватор — але «писати на диск без запиту» це звичка, яку
не починаємо. Тумблер живе в новому пункті сайдбара Settings **«Insights»** (перший, з роздільником),
бо журнал — фундамент усього Insights-напряму.

**Пишемо лише на живих реальних даних.** Запис лише коли тумблер увімкнено **І**
`currentScenario == .realNetwork` — синтетичний `TOKENPACE_STUB` не має потрапляти в журнал.

### 4. Локація — Application Support, помісячна ротація, dev/release ізоляція

`~/Library/Application Support/com.artem-n.tokenpace/usage-journal[-dev]-YYYY-MM.jsonl`:
- **`-YYYY-MM`** з UTC-timestamp рядка — природна помісячна ротація для майбутнього логротейта й
  обмежений розмір файлу.
- **`-dev`** якщо бандл запущено **не** з `/Applications` (`swift run` / dev-бандл) — dev-збірка не
  забруднює реальний журнал релізу, який мейнтейнер запускає з `/Applications`.
- Фіксована теку (app-керований стейт), без folder-picker'а — на відміну від архіватора, це не
  user-facing файл.

**Dev override:** `TOKENPACE_JOURNAL_FILE=<шлях>` спрямовує всі записи в один файл; генератор
`TOKENPACE_GENERATE_JOURNAL=<днів>` (`JournalFixture`) пише багатоденний журнал у нього для
верифікації downstream-читачів.

### 5. Concurrency — flock advisory lock

Штатно кілька інстансів TokenPace пишуть в один файл (нотаризований реліз + dev-копії). На macOS
`O_APPEND` атомарний лише до ~256 B, а рядок 300–700 B → без локу рядки різних процесів
перемішуються. Кожен append бере `flock(LOCK_EX)`; contention нульовий (запис раз на 3 хв).

## Наслідки

- **Історія починається з дня релізу** — без backfill; це аргумент випустити колектор до фіч, що
  його читають, а не після.
- **Розриви — first-class.** Каденція 3/15 хв + `pausePollingWhenScreenLocked` роблять діри в ряді
  за дизайном. `resume`-маркери відрізняють «нічого не сталося» від «ми не дивилися»; читач **ніколи
  не інтерполює** через розрив (та сама чесність, що `ServiceStatus.unknown` / idle ADR-0027).
- **Запис ніколи не валить полл.** `UsageJournal.append` не кидає й диспатчиться off-actor; на
  будь-якій помилці — лог і drop.
- **Без ротації-коду.** ~480 поллів/добу × ~70–300 B ≈ кілька MB/місяць; помісячні файли роблять
  ротацію питанням `rm` старих файлів, не логіки в app.
- **Чиста межа Kit/shell** (ADR-0009): типи рядка, фабрики, `PacingBucket`, gap, reader — pure й
  тестовані в Kit; shell робить лише flock-I/O та іменування.
- **`sev` пінить формулу medium** незалежно від `FarBehindInterval` — свідомий вибір заради
  порівнянності; якщо downstream колись схоче «як бачив користувач», сирих `timePct`+`util` для цього
  досить.
