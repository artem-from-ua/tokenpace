---
status: accepted
date: 2026-07-28
---

# ADR-0045: Чесний reset-boundary — rolled-forward grace + тригер за активністю

> Уточнює [ADR-0041](0041-idle-grace-on-reset-boundary.md): змінює **D3** (як придушувати) і
> **D5** (коли озброювати) та додає захист від переозброєння. Механізм грейсу з 0041 лишається;
> цей ADR виправляє два його дефекти. Спирається на
> [ADR-0030](0030-optimistic-reset-and-exact-timer.md) (rolled-forward `resets_at`) і
> [ADR-0027](0027-session-idle-no-phantom-reset.md) (чесний idle).

## Контекст

ADR-0041 додав грейс, щоб після ресету 5h-бар не блимав у «немає активної сесії». Реалізація
(D3) придушувала idle через `suppress()`, що ставив `sessionIdle: false`, **лишаючи
`resets_at: ""`**. Припущення D3 — «порожній `resets_at` → calm-«готовий» бар, каунтдаун падає на
7-денний» — виявилось **хибним** для поточного рендеру:

- порожній `resets_at` у pacing-гілці → `PacingModel.elapsedFraction == 1.0` → **зелений бар на всю
  ширину + «on pace»**;
- reset-лінія 5h-рядка форматиться окремо (не падає на 7d) → `resetLine == nil` → текст
  **«resetting…»** (`PopupViewController.resetText`).

Тобто грейс міняв один візуальний артефакт («немає сесії») на інший («resetting…» + фальшивий
100%-бар). Спостережено вживу: стан тримався **довше** за 5 хв, бо на реальному мерехтінні API
`active↔idle` навколо ресету грейс **переозброювався** — умова озброєння (0041, D5) спиралась на
`previous.lastSnapshot.sessionIdle`, а `advance` кладе туди вже придушений (`sessionIdle:false`)
снапшот, тож кожен короткий active-блимок скидав дедлайн і стартував новий 5-хвилинний грейс.

Додатково: грейс озброювався **завжди** після активного вікна — навіть коли пауза була справжня
(користувач справді пішов). Це затримувало чесний «ready to start» на 5 хв без потреби.

## Рішення

### D3′ (замінює D3). `suppress()` синтезує rolled-forward `resets_at`, а не порожній

`suppress(_:now:)` перебудовує 5h-вікно з
`resetsAt = ResetClock.isoString(from: ResetClock.nextReset(now:window:.fiveHour))` — **той самий**
rolled-forward `now + 5h`, що `ResetClock.optimisticReset` синтезує для shell-overlay (ADR-0030).
Наслідок: під час грейсу 5h показує спокійний «готовий» бар 0% із **чесним відліком** до наступного
ресету і природним статусом «on pace» (0% util при малому elapsed — наявна pacing-логіка). «resetting…»
неможливе, бо `resets_at` завжди валідний і в майбутньому. `ResetClock.isoString` піднято до
`internal`: optimistic-path і grace тепер серіалізують синтезований `resets_at` однаково.

Це також знешкоджує конфлікт двох шарів: раніше optimistic-overlay (t0) малював правильний
rolled-forward кадр, який негайно перетирався результатом форсованого полінгу (t1) з порожнім
`resets_at` (`App.apply` → `lastOutput = output`). Тепер обидва кадри несуть той самий rolled-forward
`resets_at`, тож перетирання безшовне.

### D5′ (замінює D5). Грейс озброюється лише за ознакою недавньої роботи

Критерій озброєння: `prevActive && claudeActive && utilFresh`, де

- `prevActive` — попереднє вікно було справді активним (як у 0041);
- `claudeActive` — процес `claude` CLI живий (уже в `PollState`, ADR-0011/0032);
- `utilFresh` — 5h `utilization` **зросла** за останні `utilFreshnessWindow` (15 хв).

Свіжість util відстежується новим **in-memory** полем `PollState.lastUtilizationChange: Date?`:
`advance` `.success` стемпить його на `now`, коли util зросла проти попереднього полу (перша
ненульова util від холодного стану рахується як ріст; ресет обнуляє util — це не ріст, тож мітка
переживає межу). Не persistent: після рестарту грейс і так без контексту.

Обидві умови (кон'юнкція): відкритий, але непрацюючий `claude` (немає spend > 15 хв) **не** тримає
бар — справжня пауза дає чесний «ready to start» одразу. Це свідома **реінтродукція** «прив'язки до
даних», яку 0041 D5 відкидав як зайву складність: практика показала, що простий булевий `prevActive`
тримає грейс і на справжніх паузах, а «resetting…»-регресія зробила ціну помилкового грейсу видимою.

### D-rearm (нове). Active-блимок у межах дедлайну не переозброює грейс

`applyIdleGrace` при active decoded, якщо грейс ще в межах дедлайну (`now < deadline`), **несе той
самий дедлайн далі** замість чистити його (`(decoded, deadline)`). Тож мерехтіння `active↔idle` не
може подовжити вікно: щойно оригінальний дедлайн спливає, наступний idle показує чесний стан. Рендер
у блимку — active-снапшот як є (вікно ж повернулось), змінюється лише те, що дедлайн зберігається.

## Наслідки

- Одразу після ресету 5h ніколи не показує «resetting…» / фальшивий 100%-бар: активна робота →
  спокійний «готовий» бар 0% із rolled-forward відліком; справжня пауза → синій «ready to start»
  одразу.
- Грейс не застрягає довше `idleGraceWindow` навіть на мерехтінні.
- Нове in-memory поле `PollState.lastUtilizationChange` + ширша сигнатура `applyIdleGrace`
  (`claudeActive`, `lastUtilizationChange`); `suppress` приймає `now`. Уся логіка лишається чистою
  функцією, покритою unit-тестами (`ApplyIdleGraceTests`).

Див. також: [ADR-0041](0041-idle-grace-on-reset-boundary.md) (базовий грейс),
[ADR-0030](0030-optimistic-reset-and-exact-timer.md) (rolled-forward overlay),
[ADR-0027](0027-session-idle-no-phantom-reset.md) (чесний idle).
