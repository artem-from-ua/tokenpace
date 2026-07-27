# Узгодження вікна Settings із macOS System Settings

> Довідник про те, як TokenPace відтворює вигляд і поведінку системного **System Settings** (macOS 15
> Sequoia), де це вдається «безкоштовно» через AppKit, а де ні — і які помилки НЕ повторювати.
> Народжений із великого проходу #156 (redesign #131 → паритет із System Settings).

## Мета продукту

**TokenPace має максимально слідувати дизайну інтерфейсу рідних застосунків macOS.** Кожен екран,
вікно й контрол мають виглядати й поводитися так, ніби це частина системи — той самий вигляд, розміри,
кольори, шрифти, відступи, поведінка, що й у застосунках Apple (System Settings передусім). Користувач
не повинен відчувати, що це «сторонній» застосунок. Це — головний орієнтир будь-якої UI-роботи тут;
усе нижче — про те, **як** цього досягати технічно (і де це важко, бо AppKit не дає системного примітиву).

## TL;DR (для того, хто прийшов сюди перед правкою Settings-UI)

1. **Спершу перевір, чи є системний механізм.** Більшість «магічних чисел» у нашому Settings існують
   лише тому, що ми **малюємо grouped-inset вручну**, а не використовуємо системний контейнер. Перш
   ніж підбирати число — спитай: «а чи AppKit не дає це сам?».
2. **AppKit macOS НЕ має grouped-inset контейнера.** System Settings — це **SwiftUI**
   `Form { Section }.formStyle(.grouped)`. Немає NSTableView-стилю, немає NSBox-типу, що малює цю
   картку. Тому наш AppKit-`SettingsCard` — ручне малювання, і частина констант тут **неминуча**
   (див. «Винятки»). Повний паритет без констант = переписати на SwiftUI Form (#168).
3. **Не підбирай числа з голови й «на око».** Якщо константа неминуча — вона має бути **виміряна** з
   живого System Settings (AX `AXSize` / Retina-скриншот ÷2), а не вгадана. Задокументуй, звідки взята.
4. **Перевіряй ОБИДВІ теми і ВСІ стани.** Light **і** dark. Малий/середній/великий розмір sidebar-
   іконок. Dev-білд і `.app`. Найчастіша причина «не так» у цьому проході — я дивився лише light і лише
   один стан.
5. **Не діагностуй наосліп.** Зроби скриншот, порівняй попіксельно з System Settings, і лише тоді
   правь. Кожна правка «навмання» тут ламала щось інше.

## Принцип: системні механізми, не хардкод (ADR-0040)

Для **стандартних системних елементів** — нуль захардкоджених розмірів, шрифтів, відступів, кольорів.
Використовувати те, що AppKit дає сам:

| Що | Системний механізм | НЕ робити |
|---|---|---|
| Розмір sidebar-іконок | читати `NSTableViewDefaultSizeMode` (`NSGlobalDomain`, 1/2/3=S/M/L) — реагувати на зміну через `DistributedNotificationCenter` ім'я **`AppleSideBarDefaultIconSizeChanged`** | не хардкодити один розмір; `effectiveRowSizeStyle` **не** резолвить `.large` для source-list — не покладатись на нього |
| Розмір перемикачів | `NSSwitch.controlSize = .mini` (26×15 pt — точний збіг із System Settings) | не `.regular`/`.small` (завеликі) |
| Popup-меню (dropdown) | `.flexiblePush` + `.small` + `showsBorderOnlyWhileMouseInside = true` (компактний, borderless-at-rest) | не `.push`/`.automatic` (важка синя рамка) |
| Шрифти | `NSFont.systemFontSize` (13) / `NSFont.smallSystemFontSize` (11) / text styles | не сирі `ofSize: 11`/`12` |
| Ширина/висота вікна | System Settings-вікно **фіксоване 857 pt** завширшки (min=max), sidebar **фіксований 258** | не робити resizable; не робити sidebar динамічним «під найдовший label» — System Settings цього не робить |
| Заголовок вікна | HIG: відображати вибрану секцію; ми поки статичний «TokenPace Settings» (single-pane form) | — |
| Вирівнювання рядка | `NSStackView` `.alignment = .firstBaseline` + `edgeInsets` визначають висоту рядка | не центрувати текст руками через top/bottom-pin (робить текст top-heavy) |
| Символи секцій | точні з `.appex Info.plist` System Settings: General=`gear` (не `gearshape`), Notifications=`bell.badge.fill`; вага `.regular` | не вгадувати символ; не `.semibold` (затовсто) |
| Довгі sidebar-мітки | truncate на одному рядку + `allowsExpansionToolTips = true` (HIG) | не wrap |
| Шлях до папки | `NSPathControl` (сам обрізається, клік→Finder, не розпирає layout) | не голий `NSTextField` (розпирає вікно) |

## Винятки: де AppKit НЕ має API (хардкод неминучий, але виміряний)

macOS AppKit не має iOS-подібних grouped-примітивів. У цих місцях System Settings рендерить через
SwiftUI/приватні механізми, а чистого AppKit-аналога немає. Тут ми малюємо вручну — але значення
**виміряні** з живого System Settings, не вгадані, і задокументовані:

- **Колір картки / фону панелі.** macOS не має семантичного grouped-background (немає iOS
  `secondarySystemGroupedBackground`). Жодна семантична `NSColor` чи `NSVisualEffectView`-матеріал
  не дає пари з фліпом light↔dark. → фіксований **dynamic** `NSColor`: картка 242/43, фон 246/40
  (light/dark). `.contentBackground`-матеріал давав чисто-білий (255) — це був баг.
- **Скруглені кутики time picker.** `NSDatePicker` не вміє округлити власний bezel; System Settings —
  bespoke SwiftUI-контрол. → bezelless picker (`isBezeled/isBordered/drawsBackground = false`)
  всередині кастомного `RoundedFieldBox`. Insets виміряні (leading 4, trailing −1).
- **Кольоровий chip за sidebar-іконкою.** Стандартний `NSTableCellView.imageView` outlet накладає
  source-list template-tint + vibrancy (робить glyph блідо-сірим і ховає на неактивному вікні) →
  chip лишається кастомним; розмір із виміряної таблиці (chip 14/20/26 pt для S/M/L).
- **Сам grouped-inset контейнер** (`SettingsCard`): row height, corner radius, padding. AppKit не має
  контейнера, що дає ці системні дефолти. → ручне малювання; значення виміряні (див. `SettingsCard`).
  **Правильний остаточний фікс — SwiftUI `Form.formStyle(.grouped)` через `NSHostingView`** (окремий
  тікет), який дав би всі ці метрики системними дефолтами без жодної константи.

### Виміряні метрики картки (System Settings, Retina ÷2)

Оскільки AppKit не має grouped-контейнера, ці значення в `SettingsCard`/`SettingsRow` — **виміряні**
з живого System Settings (не вгадані), і мають лишатися такими, доки не буде переходу на SwiftUI Form:

| Метрика | Значення | Примітка |
|---|---|---|
| Висота однорядкового рядка | **37 pt** | текст вертикально центрований |
| Вертикальний inset (пер бік) | **12 pt** | 13 pt шрифт у 37 pt рядку |
| Горизонтальний inset (край→мітка) | **11 pt** | |
| Corner radius картки | **4 pt** | делікатне скруглення (НЕ 10 — типова помилка) |
| Divider inset (обидва боки) | **10 pt** | симетричний, ~на межі тексту |
| Товщина hairline (border/divider) | **0.5 pt** | 1 px @2×, не 1 pt |


## Мої (агента) помилки в цьому проході — і як їх уникати

Задокументовано чесно, щоб наступний агент (чи я) не наступив на ті самі граблі.

1. **Обходив системні механізми, тоді підбирав числа.** Найбільша системна помилка. Приклади: хардкодив
   розміри sidebar-іконок замість `.imageView`-outlet; малював картку кольором замість шукати material;
   не подумав про SwiftUI Form. **Урок:** спершу питання «чи є системний спосіб?», лише потім — константа.
2. **Перевіряв лише світлу тему.** Користувач весь час був у **dark**, а я скриншотив light — тому
   пропускав dark-баги (колір picker-фону, слабкий divider). **Урок:** завжди light **і** dark.
3. **Перевіряв лише один стан.** Розмір sidebar-іконок ламався на large, бо я дивився лише medium.
   **Урок:** усі три розміри (mode 1/2/3), dev-білд і `.app`.
4. **Правив наосліп і ламав інше.** Зміна вирівнювання trailing зламала праве вирівнювання перемикачів;
   зміна top/bottom-констрейнтів роздула About-картку — двічі. **Урок:** діагностуй скриншотом →
   порівняй з System Settings → правь → **перевір усі панелі** скриншотами, лише тоді віддавай.
5. **`effectiveRowSizeStyle` не резолвить `.large` для source-list.** Витратив цикл, поки не почав
   читати `NSTableViewDefaultSizeMode` напряму. **Урок:** для source-list icon size — глобальний
   default, не `effectiveRowSizeStyle`.
6. **`UserDefaults.didChangeNotification` не ловить крос-процесну зміну** глобального домену. Runtime-
   реакція на зміну sidebar icon size вимагає `DistributedNotificationCenter` з приватним ім'ям
   `AppleSideBarDefaultIconSizeChanged`. **Урок:** зовнішні зміни `NSGlobalDomain` — через distributed
   notification, не local defaults-KVO.

## Як вимірювати System Settings (метод)

- **AX `AXSize`/`AXPosition`** — точні розміри вікна, sidebar, рядків (`AXOutline`, `AXOutlineRow`).
- **Retina-скриншот ÷2** — кольори (pixel-семпл центру), геометрія, кути.
- **`.appex Info.plist`** — символи/tint секцій System Settings (`ISSymbolName`/`ISEnclosureColor`).
- **SDK-хедери** (`NSTableView.h` тощо) — які API/стилі реально існують (не з пам'яті!).
- Не вгадувати з training-data: HIG-сайт SPA-рендериться, часто не піддається `WebFetch` — шукати
  офіційні сторінки/форуми Apple, чесно позначати межу впевненості (конвенція, ADR-0021).

## Пов'язане

- [ADR-0040](../adr/0040-native-system-metrics-no-hardcoded-ui.md) — рішення-принцип + винятки.
- [ADR-0035](../adr/0035-settings-window-sidebar-grouped-inset.md) — початковий redesign (частково
  переглянутий цим проходом: material/dynamic-колір замість `controlBackgroundColor`).
- [conventions.md](conventions.md) § UI-дизайн (AppKit).
- [ui-verification.md](../guides/ui-verification.md) — стуби й процес живої верифікації.
- Issue #156 (паритет), #168 (SwiftUI-Form-переписання).
