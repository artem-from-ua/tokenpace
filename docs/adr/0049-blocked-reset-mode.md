---
status: superseded
date: 2026-07-31
superseded_by: [0063]
---

# ADR-0049: Окремий `MenuBarMode.blockedReset` для віджета «лише countdown»

> **Витіснено [ADR-0063](0063-unified-pause-hides-bars.md).** Тумблер «Show pacing bars when 5h/7d
> limits reached» (ключ `hideBarsWhenBlocked`) злито в єдиний `pauseHidesBars`, а предикат ховання
> барів звужено з `mainWindowExhausted` до `isBlocked`. Кейс `MenuBarMode.blockedReset` лишається в
> моделі, але тепер гейтиться новим ключем.

## Контекст

Коли ліміт вичерпано (заблоковано), pacing-бар у menu-bar-віджеті нічого корисного не показує — він
просто червоний «на 100 %». Єдиний дієвий сигнал у цей момент — **час до найближчого ресету**. Опція
«Hide pacing bars when blocked» (#194, default-on, opt-out) прибирає **обидва** бари у стані блокування
й лишає тільки countdown.

Стан «заблоковано» тут — `CreditsPacing.mainWindowExhausted` (будь-яке головне вікно 5h/7d на
`utilization ≥ 100`), **без** урахування credits: навіть якщо платні кредити ще покривають роботу, бар
на 100 % не несе pacing-інформації. Це ширше, ніж `CreditsPacing.isBlocked` (той додає
`&& !creditsCanCover`), і це свідомий вибір мейнтейнера.

Питання цього ADR — **як виразити «лише countdown, без барів» у моделі `MenuBarMode`**. Наявний
`.expanded(fiveHour: BarView, sevenDay: BarView?, resetToShow: ResetToShow?)` має **обов'язковий**
`fiveHour`; `sevenDay` уже опційний (#94). Стан «жодного бару» в нього не вкладається.

## Розглянуті варіанти

1. **Зробити `fiveHour` опційним у `.expanded`** (`fiveHour: BarView?`) — тоді `nil/nil + resetToShow`
   = countdown-only. Але це торкається всієї геометрії малювання в hot draw-path
   (`StatusItemView.drawExpanded` / `drawBars` / `barsBlockWidth` / вертикального центрування) і **ламає
   всі наявні expanded-тести**: їхні хелпери деструктурують не-опційний `five`
   (`MenuBarLayoutTests.swift`, `case let .expanded(five, …)`). Семантично «немає даних для 5h» і
   «свідомо не малюємо 5h» злилися б в одному `nil`, хоча це різні речі (порівн. `sevenDay == nil`, яке
   вже означає «свідомо приховано»).

2. **Новий кейс `MenuBarMode.blockedReset(reset:which:)` (обране).** Локальний, явний варіант: чиста
   нова гілка в `render`-switch, `itemWidth` і жодного дотику до `drawExpanded`/`drawBars`. Малювання
   майже ідентичне наявному шляху «error-glyph alone» — центрований monospace-лейбл. Наявні
   expanded-тести не зачеплені (їхня деструктуризація `.expanded` лишається валідною).

## Рішення

**Додано кейс `MenuBarMode.blockedReset(reset: TimeToReset, which: LimitWindow)`** — «лише countdown,
без барів».

- **Де вирішується (Kit).** У базовому `MenuBarLayout.make(from:now:…)`, **перед** розгалуженням на
  idle/active бари, за прапорцем `hideBarsWhenBlocked` (пробрасується з `PersistedConfig`): якщо
  `CreditsPacing.mainWindowExhausted(in:)` **і** `BlockingReset.forBlocked(snapshot:now:)` дає ресет →
  повертаємо `.blockedReset`. `which`/формат визначає приватний `blockedResetMode(for:now:)`: 5h-вікно
  (`.token(id: 0)`) → live `H:MM` countdown, 7d / per-model / credits → compact-days (`Nd`), рівно як
  форматує `selectReset`.

- **Форсований ресет.** Countdown показується **незалежно** від `resetMode` (навіть `.never`), бо без
  барів це єдина корисна інформація. Це той самий вибір, що вже робить idle-blocked-гілка й попап (усі
  три читають `BlockingReset.forBlocked`, тож завжди узгоджені).

- **Fallback.** Якщо `forBlocked` → `nil` (у вичерпаного вікна `resets_at` не парситься), у
  `.blockedReset` **не** входимо — лишаємо звичайний шлях, де `hasBrokenActiveReset`/`selectReset`
  чесно піднімають ⚠️ data-error (#167, ADR-0043), а не вигадують countdown.

- **Error-шлях недоторканий.** `usageMode` у stale/error-фазі (#12) деструктурує результат `make` як
  `.expanded`, щоб показати діагностичні stale-бари поряд з ⚠️. Тому туди `hideBarsWhenBlocked` **не**
  пробрасується (default `false`) — exhausted-yet-stale стан завжди зберігає бари.

- **Тільки menu bar.** Popup (`PopupLayout`) незмінний — при кліку користувач бачить повну картину з
  барами.

## Наслідки

- **Плюс:** локальна зміна, наявні тести й геометрія `.expanded` недоторкані; чиста точка юніт-тесту
  (новий `@Suite` у `MenuBarLayoutTests.swift`). Розмежування «немає даних» (`.error`) vs «свідомо без
  барів» (`.blockedReset`) явне на рівні типу.
- **Мінус:** `MenuBarMode` тепер має три кейси замість двох — кожен новий `switch` по `mode` (view,
  `itemWidth`) мусить обробити `.blockedReset`. Компілятор це гарантує (exhaustiveness).
- **Гейт опції** — `PersistedConfig.hideBarsWhenBlocked` (default-on), тумблер у Settings → Appearance
  → Menu Bar Widget; зміна перемальовує з останнього полу (`reRenderForCurrentTime`), рестарт не
  потрібен.
