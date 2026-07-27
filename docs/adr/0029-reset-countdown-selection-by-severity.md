---
status: accepted
date: 2026-07-24
supersedes: [0028]
superseded_by: [0042, 0043]
---

# ADR-0029: Вибір reset-часу в menu bar за станами 5h × 7d + режим-радіогрупа

> **Частково переглянуто [ADR-0042](0042-settings-swiftui-form.md) (#168):** режим `hideDistant7d`
> прибрано разом із чекбоксом «Include distant 7-day limit reset». `ResetCountdownMode` тепер має три
> варіанти — `always` / `smart` (колишній `showDistant7d`, у Settings «When pacing well ahead or limit
> reached») / `never`; days-away ahead-of-pace 7d-countdown показується завжди, коли countdown
> показується взагалі (`showsSevenDayAheadWhenFar`). Таблиця вибору за severity (нижче) лишається
> чинною; згадки `showDistant7d`/`hideDistant7d`/`showsDistantAhead7d` в тілі — історичні.

> **Постскрипт (2026-07-27, [ADR-0043](0043-unified-reset-line-and-remove-resetnow.md), #167):**
> `selectReset` тепер повертає `ResetSelection` (`.hide`/`.show`/`.dataError`), не `ResetToShow?`.
> Реалізації-пункт «битий/nil `resets_at` обраного шумного бару → ⏰ (`.resetNow`)» замінено:
> такий випадок → `.dataError`, і menu bar промотується в ⚠️ error-стан (як інша помилка API), а не
> показує фейковий countdown. «Обидва calm без валідних дат → нічого» лишається (`.hide`). Таблиця
> вибору 5h×7d незмінна.

Суперсідить [ADR-0028](0028-hide-reset-label-when-pacing-is-calm.md), який робив лише бінарне
рішення «ховати, коли обидва бари спокійні».

## Контекст

ADR-0028 приховував countdown, коли обидва бари спокійні, і показував **найближчий** (nearest) ресет,
щойно бодай один ставав помаранчевим/червоним. Це відповідало на питання «чи показувати», але не на
«**який саме** час показувати». Найближчий ресет не завжди корисний: якщо 5h вичерпано (red) і
ресетнеться за годину, але 7d теж вичерпано й ресетнеться за дві — показ «1 год» вводить в оману, бо
до 2-ї сервіс усе одно заблокований.

Потрібно обирати час, що відповідає **наступному реальному полегшенню блокування**, і дати
користувачу режим, щоб керувати показом далекого 7d-часу та повернути класичну «завжди показувати».

### Семантика severity бару (джерело істини)

Успадковано з ADR-0028; тепер кодифіковано в `BarLayout.severity` (Kit, AppKit-free), дзеркалить
`PopupBarView.aheadColor`:

| severity | Колір | Умова | заблоковано? |
|---|---|---|---|
| `.calm` | green / yellow | `usage <= time`, або ahead `< 15` пт (`usage < 1`) | ні |
| `.ahead` | orange | ahead `>= 15` пт, `usage < 1` | ні (попереду плану) |
| `.exhausted` | red | `usage >= 1` | так (ліміт вичерпано) |

## Рішення

**Обирати, час якого вікна (5h чи 7d) показати — або сховати — за таблицею станів 5h × 7d, керованою
режимом `ResetCountdownMode`.** Принцип: показувати час *наступного реального полегшення блокування*.

### Таблиця (режими Show/Hide)

| 5h \ 7d | 7d calm | 7d orange | 7d red |
|---|---|---|---|
| **5h calm/idle** | нічого | час 7d ⃰ | час 7d (завжди) |
| **5h orange** | час 5h | ранній (обидва orange) | час 7d (red блокує) |
| **5h red** | час 5h | час 5h (red блокує) | пізніший (обидва red) |

⃰ gate лише для **orange-7d**: режим `showDistant7d` показує; `hideDistant7d` — лише якщо 7d-ресет
`< 24 год`. 7d **red** показується завжди. (На практиці orange-7d із ресетом `< 24 год` майже
недосяжний — при близькому 7d-ресеті вікно майже минуло, тож `usage > elapsed + 0.15` вимагало б
`usage ≈ 1` → red. Тож `hideDistant7d` фактично ховає весь orange-7d.)

### Режими (`ResetCountdownMode`, радіогрупа в Settings → «Menu bar widget»)

| Режим | «обидва calm» | «orange-7d далеко, 5h calm» | решта таблиці |
|---|---|---|---|
| `always` | **найближчий** | показувати | як таблиця |
| `showDistant7d` *(default)* | нічого | показувати | як таблиця |
| `hideDistant7d` | нічого | ховати | як таблиця |
| `never` | нічого | нічого | **скрізь нічого** |

`always` = default + «обидва calm» показує найближчий (⇒ ніколи не порожньо); `never` = завжди порожньо.
Параметризовано двома прапорцями режиму (`showsWhenBothCalm`, `showsDistantAhead7d`).

### Реалізація

1. **`BarLayout.severity`** (`PacingModel.swift`, Kit) — три-стан calm/ahead/exhausted; `isCalm`
   похідний. `BarView.severity` пробрасує через idle (idle → `.calm`).
2. **`ResetCountdownMode`** (Kit, raw-`String`, forward-compat як `WebDesktopMode`).
3. **`ResetClock.latestReset`** — дзеркало `nearestReset` для «обидва red → пізніший».
4. **`MenuBarLayout.selectReset`** — чиста функція-джерело таблиці; формат: 5h → `timeToReset`,
   7d → `timeToResetCompactDays` (компактні дні). Битий/nil `resets_at` обраного шумного бару → ⏰
   (`.resetNow`); обидва calm без валідних дат → нічого.
5. **`MenuBarMode.expanded`** несе `resetToShow: ResetToShow?` (nil = ховати), замість
   `reset`/`which`/`showReset`. `make(…:resetMode:)` кличе `selectReset` (active + idle).
6. **Shell.** `PersistedConfig.resetCountdownModeMenuBar` (default `.showDistant7d`) + 4-way радіогрупа;
   `StatusItemView` малює `resetToShow` (nil → без label/ширини).
7. **Error-режим** (30–60 хв stale) — countdown завжди **найближчий** (діагностика), режим не діє.

## Наслідки

- Countdown відповідає на «коли наступного разу попустить», а не просто «найближчий ресет».
- Користувач керує показом далекого 7d-часу й може повернути «завжди»/вимкнути повністю.
- `MenuBarMode.expanded` спростилася (одне опційне поле замість трьох).
- Дублювання порогів aheadColor ↔ severity лишається (та сама причина, що в ADR-0028) — тепер в
  одному місці (`BarLayout.severity`), звідки `isCalm` похідний.

## Верифікація

`swift build && swift test` (`BarLayout.severity`, `MenuBarLayout.selectReset` по всіх клітинках ×
4 режими). Наживо (`TOKENPACE_STUB`): нові фрейми `both-red` (→ пізніший = 7d «4d»),
`red-orange` (→ час red-бару = 5h), `5h-orange`, `both-orange`; існуючі `screenshot`/`idle` (обидва
calm → порожньо в default, найближчий у `always`); перемикання 4 режимів у Settings.
