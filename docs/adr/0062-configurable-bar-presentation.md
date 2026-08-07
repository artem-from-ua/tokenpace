---
status: superseded
date: 2026-08-02
supersedes: []
superseded_by: [0076]
---

# ADR-0062: Конфігурована подача пейсинг-барів — Bar style, Calm-режим, поріг far-behind

> **Частково витіснений [ADR-0076](0076-pressure-scale-for-marker-less-bar.md)** (#307): стрічка без
> маркера більше **не** дорівнює ширині пейсинг-gap (`gapEnd − gapStart`) — вона рахується в
> перенормованій шкалі `[now .. reset]` (`BarLayout.pressureLength`), а тіки під нею мітять чверті
> часу, що лишився, а не частки вікна. UI-назви теж змінились: «Pace & Time» → **Progress**,
> «Pace» → **Pressure**; перейменовано й enum-кейси з `rawValue` (`.pacing` → `.progress`, `.simple` →
> `.pressure`), старі значення мігруються на старті. Решта цього запису — per-surface
> вибір, `CalmColorMode`, `FarBehindInterval`, `showTicks`, пресети — чинна.

> Частково витісняє [ADR-0061](0061-far-behind-blue-pacing-zone.md): behind-поріг більше не
> **фіксованої** ширини (тепер конфігурований через `FarBehindInterval`), а bool-опція «Work harder»
> замінена триставним `CalmColorMode`. Синій severity-case, 20-хв start-override, обсяг 5h/7d і
> `ColorRole.paceBlue` з 0061 лишаються чинними.

## Контекст

[ADR-0061](0061-far-behind-blue-pacing-zone.md) додав синю far-behind зону з **фіксованим** порогом
(60 хв / 5h, 24 год / 7d) і bool-toggle «Work harder» (тримати синій кольоровим під calm). #224
розширює подачу барів на кілька осей, які раніше були жорстко закодовані або відсутні:

- **Спосіб подачі бару.** Досі бар завжди мав кольоровий `gap` + маркер поточного часу («ти тут»).
  Не всім потрібна щільна пейсинг-графіка — декому досить кольору стану без маркера.
- **Скільки кольору приглушувати** було двома окремими bool-ами (`calmMenuBarColors` + `workHarderColors`),
  чия комбінація («calm on + work harder off» = мутити й синій) неочевидна.
- **Поріг green→blue** був фіксований — не було способу зробити синій рідшим/частішим або зовсім вимкнути.
- **Засічки під баром** у попапі завжди малювались.

## Рішення

**Винести подачу барів у чотири render-only опції, кожна — kit-enum з forward-compatible decode,
з єдиним джерелом дефолтів (пресет `.workHarder`).**

### 1. `BarStyle` — спосіб подачі (per-surface)

Триставний enum, що вибирає, чи малювати **маркер часу** окремо для menu bar і попапа:

- `.pacing` — gap + маркер на **обох** поверхнях (дореформена подача).
- `.mixed` — стрічка (pace-only) у **menu bar**, gap + маркер у **попапі** (маркер лише там, де є місце).
- `.simple` — стрічка (pace-only) на **обох**: без маркера.

**Стрічка (pace-only)** — кольорова смуга **від лівого краю**, довжина = ширина пейсинг-gap
(`gapEnd − gapStart`), тим самим семантичним кольором стану. Тобто стільки ж кольору, як у Pace & Time,
але без часової позначки. Розгалуження в малювачах — через `BarStyle.menuBarShowsTimeMarker` /
`popupShowsTimeMarker`, щоб `StatusItemView` і `PopupBarView` не розсинхронились.

> ⚠️ **Витіснено [ADR-0076](0076-pressure-scale-for-marker-less-bar.md).** Довжина стрічки більше не
> дорівнює `gapEnd − gapStart` — це `BarLayout.pressureLength` = `|u − t| / (1 − t)`, тож кольору в
> ній **не** стільки ж, скільки в Progress: вона ширша саме там, де стан гостріший.

### 2. `CalmColorMode` — що приглушено (замість двох bool)

Триставний enum, що **замінює** пару `calmMenuBarColors` + `workHarderColors`. Назва описує, які
**calm**-кольори мутяться в білий (orange/red-попередження завжди кольорові):

- `.off` — нічого не мутиться.
- `.yellowGreen` — мутяться зелений/жовтий; far-behind **синій лишається** (= старе «calm on + work harder on»).
- `.yellowGreenBlue` — мутяться зелений/жовтий **і** синій (= старе «calm on + work harder off», найтихіше).

Render-шар читає два derived-прапорці — `mutesCalm` і `mutesBlue` — тож логіка `calmedGapColor`
незмінна, лише джерело прапорців стало одне enum замість двох ключів.

### 3. `FarBehindInterval` — конфігурований поріг green→blue

Чотириставний enum, що масштабує behind-ширину з ADR-0061 (база 1h / 5h, 1d / 7d) множником:

- `.off` — синього немає взагалі (поріг → +∞).
- `.short` (×1) — 1h / 1d (= старий фіксований поріг ADR-0061).
- `.medium` (×2, **дефолт**) — 2h / 2d.
- `.long` (×3) — 3h / 3d.

`behindThreshold(windowDurationSeconds:multiplier:)` домножає базову ширину на множник (`.off` →
`.greatestFiniteMagnitude`, тож `surplus > threshold` ніколи не істинний). Множник несе нове поле
`BarLayout.behindMultiplier` (дзеркалить `windowDurationSeconds`), тож **Kit-severity й
AppKit-колір читають те саме** — не розходяться. `AppKit` передає
`PersistedConfig.farBehindInterval.multiplier ?? 0` у `barLayout(...)` через `MenuBarLayout.make` /
`PopupLayout.make`.

### 4. `showTicks` — засічки під баром у попапі (opt-out)

Bool-гейт на `PopupBarView.drawTicks`. Menu bar засічок не має, тож опція popup-only.

### Єдине джерело дефолтів — пресет `.workHarder`

`AppearancePreset.default = .workHarder` (#224). Кожен Appearance-getter у `PersistedConfig` при
відсутньому ключі бере значення з `AppearancePreset.defaultValues.<field>` замість власної літерали.
Наслідок: **нова Appearance-опція автоматично дефолтиться до свого `.workHarder`-значення** — дефолт
живе в одному місці (пресет), не дублюється в getter'ах. Fresh install / Reset → Work harder!.

### Пресети (розширені)

Три пресети керуються сегментованим контролом (`Chill | Work harder! | Control freak | Custom`), де
**Custom** — некликабельний індикатор, що підсвічується, коли конфіг не збігається з жодним пресетом
(`AppearancePreset.matching(_:)`):

| Пресет | CalmColorMode | BarStyle | showTicks | FarBehindInterval |
|---|---|---|---|---|
| Chill | `.yellowGreenBlue` | `.simple` | off | `.off` |
| Work harder! (**default**) | `.yellowGreen` | `.mixed` | on | `.medium` |
| Control freak | `.off` | `.pacing` | on | `.medium` |

## Наслідки

- **Bar style, Calm-режим і far-behind поріг тепер конфігуровані** через Settings → Appearance, кожен —
  один enum-ключ у `PersistedConfig`.
- **Конфлікт-стан UI.** Коли `FarBehindInterval == .off`, пункт «Yellow + Green + Blue» у Calm-контролі
  disabled (синього немає, що мутити) — popover пояснює причину, як «Custom»-індикатор пресетів.
- **`workHarderColors` ключ видалено** — злитий у `calmColorMode`. Старі логи
  `calm-colors: menu-bar set` / `work-harder-colors: menu-bar set` замінені на `calm-color-mode: set`.
- **Дефолти зсунулись** відносно ADR-0061: дефолтний far-behind поріг тепер 2h/2d (×2), не 1h/1d;
  дефолтний пресет — Work harder! (mixed бари, ticks on). Наявний користувач без збережених ключів
  побачить нову подачу.
- **Два дубльовані малювачі** (`StatusItemView.drawBar`, `PopupBarView.draw`) додають гілку Simple
  кожен — крос-референс-коментарі й спільні per-surface helper-и стережуть від дрейфу.
- **ADR-0061 лишається чинним** для синього severity-case, start-override, обсягу 5h/7d і
  `paceBlue` — цей запис лише робить ширину/muting конфігурованими.
