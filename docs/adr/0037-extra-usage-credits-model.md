---
status: accepted
date: 2026-07-26
---

# ADR-0037: Модель грошових кредитів (extra usage) — `spend` як primary, тригер і pacing як у токенів

> Рішення ухвалені під час спайку [#142](https://github.com/artem-from-ua/tokenpace/issues/142)
> (жива структура API) і продуктового інтерв'ю; decode-модель + pacing реалізовано в
> [#143](https://github.com/artem-from-ua/tokenpace/issues/143). UI — menu bar
> [#144](https://github.com/artem-from-ua/tokenpace/issues/144) / dropdown
> [#145](https://github.com/artem-from-ua/tokenpace/issues/145). Epic — [#141](https://github.com/artem-from-ua/tokenpace/issues/141).

## Контекст

Підписка Claude Code має **платні кредити доплати** («usage credits» / extra usage): коли користувач
упирається в ліміт плану, витрати можуть іти з грошового балансу (у валюті акаунта), опційно обмежені
місячним лімітом (`Monthly spend limit`). TokenPace має показувати це:

- у **menu bar** — міжнародна іконка валюти, що з'являється лише коли користувач **зараз реально
  витрачає кредити**; колір відповідає pacing і керується `calmMenuBarColors`;
- у **dropdown** — окрема секція «Extra usage» з витраченою сумою, лімітом і pacing-статусом.

Досі декодер (`UsageSnapshot`, [ADR-0014](0014-usage-decode-resilience-on-reset-boundary.md)) свідомо
**ігнорував** блоки `spend` / `extra_usage` — вони тихо толерувалися як невідомі ключі.

Спайк #142 зняв **5 живих станів** `GET /api/oauth/usage` (акаунт мейнтейнера, валюта EUR), варіюючи
`Monthly spend limit`: out-of-credits, enabled-within-limit, near-cap, limit-below-spent (перевищення),
unlimited. Verbatim-body збережено як regression-фікстури в `UsageClientTests.swift`. Ці дані виявили
кілька нетривіальних фактів, що й вимагають зафіксованого рішення.

### Що показав API

Два паралельні блоки; **`spend` — новіший і чистіший**, `extra_usage` — старіший з додатковими полями:

```jsonc
"spend": {
  "used":  {"amount_minor": 1077, "currency": "EUR", "exponent": 2},   // money-ОБ'ЄКТ
  "limit": {"amount_minor": 1500, "currency": "EUR", "exponent": 2},   // money-об'єкт АБО null (unlimited)
  "percent": 72, "severity": "normal", "enabled": true,
  "cap": {"money": {…}, "credits": null},                              // або null
  "balance": null, "auto_reload": null                                 // ЗАВЖДИ null у цьому ендпоінті
},
"extra_usage": {
  "is_enabled": true, "monthly_limit": 1500,       // скаляр (мінорні одиниці), або null
  "used_credits": 1077.0,                           // = spend.used; джерело істини по витраченому
  "utilization": 71.8,                              // float %, або null коли ліміту нема
  "currency": "EUR", "decimal_places": 2,
  "spend_limit_reached": false, "credits_ever_enabled": true, …
}
```

Ключові спостереження зі спайку:

1. **Гроші — це об'єкти `{amount_minor, currency, exponent}`** (`spend.used`, `spend.limit`,
   `spend.cap.money`), а не скаляри. `extra_usage.monthly_limit` — навпаки, голе число в мінорних.
2. **Валюта не USD** — у мейнтейнера EUR. Хардкодити `$` не можна.
3. **Сервер капить `percent` / `utilization` на 100** — при spent 10.77 / limit 5.00 віддає `percent: 100`,
   не 215. Реальне перевищення видно лише через `spend_limit_reached` + порівняння `used_credits` vs `limit`.
4. **При перевищенні грошового ліміту сервер робить `spend.enabled: false`** (+ `spend_limit_reached: true`,
   `disabled_reason: "org_level_disabled_until"`) — кредити авто-вимикаються.
5. **`balance` / `auto_reload` — завжди `null`** у всіх 5 станах. Current balance, який показує веб-UI
   Claude (€10.00), **не приходить** у `/api/oauth/usage` — обхід усього дерева payload не знайшов його.
   Він живе в іншому (billing / member-dashboard) ендпоінті, недоступному TokenPace.

## Рішення

1. **`spend` — primary-джерело; `extra_usage` — доповнення.** Моделюємо `spend` (чистіша, structured
   money). З `extra_usage` беремо лише те, чого нема в `spend`: `used_credits` (джерело істини по
   витраченому — дублює `spend.used`), `decimal_places`, `spend_limit_reached`, `currency` як резерв.

2. **Гроші — окремий Kit-тип `{amount_minor: Int, currency: String, exponent: Int}`**, не `Double`.
   Точність грошей важлива; float дав би помилки округлення. Форматування суми (з урахуванням
   `exponent` / `decimal_places` і валюти) — у view (shell), тип лишається AppKit-free.

3. **Толерантний decode** у стилі [ADR-0014](0014-usage-decode-resilience-on-reset-boundary.md):
   `decodeIfPresent` + forward-compat дефолти, нове поле в memberwise-init з default `nil`. Відсутність
   чи невідома форма `spend`/`extra_usage` **не валить** snapshot (як і раніше). Наявні фікстури не ламаються.

4. **Тригер іконки = `spend.enabled == true` OR `spend_limit_reached == true`** (а не лише `enabled`).
   Обґрунтування: сервер вимикає `enabled` саме в момент перевершення ліміту (факт 4) — тобто тоді,
   коли сигнал «вперся в грошову стелю» найпотрібніший. Правило лише за `enabled` ховало б іконку в цей
   момент. Показ додатково гейтиться реальним використанням кредитів (хоча б один базовий ліміт
   5h/7d/scoped вичерпаний — саме тоді витрати йдуть з кредитів).

5. **Колір іконки рахується ТАК САМО, як бари токенів — `usage` vs `time`, серверний `spend.severity`
   ІГНОРУЄМО.** `CreditsPacing.barLayout(...)` віддає той самий `BarLayout`, що й 5h/7d-бари, тож view
   фарбує іконку тим самим `PopupBarView.aheadColor(usage:time:)`: зелений (у нормі) → жовтий (трохи
   випереджаєш) → оранжевий (сильно) → **червоний лише при досягнутому ліміті**. Осі:
   - `usageFraction = used_credits / limit`;
   - **`timeFraction` = частка календарного місяця, що минула, від 00:00 UTC 1-го числа.** Грошове
     вікно = календарний місяць у UTC — підтверджено офіційними [Anthropic Spend Limits API
     docs](https://platform.claude.com/docs/en/manage-claude/spend-limits-api) («monthly spend resets
     at 00 UTC on the first of each calendar month»). API **не дає** reset-часу грошей (факт 5-bis:
     `spend`/`extra_usage` без часових полів), тож `timeFraction` рахуємо локально (`monthElapsedFraction`,
     TZ інжектована, дефолт UTC — на відміну від токенних вікон, чий reset-час `ResetClock` показує в
     **локальній** TZ). `spend_limit_reached` (або `used >= limit`) форсує `usageFraction = 1` → `aheadColor`
     дає червоний. Це навмисно НЕ окрема severity-формула з порогом «% від стелі» — колір узгоджений із
     рештою pacing 1:1. Гасіння calm-кольорів під `calmMenuBarColors` — як у барів (#105).

6. **База pacing — тільки ЛІМІТ. Balance-логіку прибрано з обсягу.** Оскільки `balance` недоступний
   (факт 5), будь-який розрахунок «відносно балансу» неможливий:
   - **ліміт встановлений** → pacing відносно ліміту (`used / limit` × час місяця), як звичайні бари;
   - **ліміт не встановлений** (unlimited, `limit == null`) → **без pacing / без бару**, лише витрачена
     сума (немає стелі → немає `usageFraction` → `barLayout` віддає `nil`).
   Balance / auto-reload / поповнення — **окрема майбутня фіча**, коли (і якщо) з'ясуємо джерело даних.

7. **Розкол pure/shell — як усюди** ([ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md)):
   decode-модель і чиста `CreditsPacing` (тригер + `barLayout` usage-vs-time + `monthElapsedFraction`)
   живуть у `TokenPaceKit` (AppKit-free, юнітяться); мапінг `BarLayout` → колір (спільний `aheadColor`),
   SF-Symbol валюти й форматування сум — у shell (`StatusItemView` / `PopupViewController`).

## Наслідки

- **Decode стає багатшим, але сумісним назад.** Старі payload без `spend`/`extra_usage` (і всі наявні
  тестові фікстури) декодуються без змін — нове поле опційне.
- **Іконка чесно сигналить перевищення ліміту** (red/exhausted навіть коли сервер вимкнув `enabled`),
  а не зникає в найважливіший момент.
- **Немає залежності від серверної severity** — менша поверхня для регресій, якщо сервер змінить
  внутрішні пороги; ціна — власні пороги треба тримати узгодженими з барами (одне джерело — `PacingSeverity`).
- **Валюто-агностичність**: сума завжди з `currency`+`exponent`, іконка — generic-символ валюти
  (напр. `coloncurrencysign` ¤), не `$`. Працює для EUR і будь-якої іншої валюти акаунта.
- **Свідома прогалина: no-balance.** Поки TokenPace не показує current balance / auto-reload — навіть
  коли веб-UI Claude їх показує. Це задокументоване обмеження ендпоінта, не недогляд. Коли з'явиться
  доступ до джерела балансу — розширюємо окремим ADR.
- **`resets_at` грошового вікна** окремим полем у payload не спостерігався (веб-UI показує «Resets Aug 1»);
  джерело reset-часу для рядка «time to reset limit» у dropdown уточнюється в #145 — якщо джерела нема,
  рядок опускається. Це не блокує decode-модель.

## Альтернативи (відкинуті)

- **Довіритись серверному `spend.severity`** — відкинуто: непрозорі пороги, неузгодженість із рештою
  pacing-кольорів, залежність від змін на боці сервера (спостережене 72%→normal, 98%→critical —
  довідково, не використовуємо).
- **Тримати гроші як `Double` (у мажорних одиницях)** — відкинуто через похибки округлення; structured
  money точний і збігається з формою API.
- **Реалізувати balance-based розрахунок за оцінкою** — відкинуто: даних про balance нема, будь-яка
  оцінка була б вигадкою, що вводить в оману саме на грошах.
