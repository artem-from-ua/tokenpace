---
status: accepted
date: 2026-07-27
superseded_by: [0042, 0059, 0069]
---

# ADR-0040: Нативний вигляд UI через системні механізми, а не захардкоджені метрики

> **Частково переглянуто [ADR-0042](0042-settings-swiftui-form.md) (#168):** §2 (винятки-хардкод для
> grouped-inset контейнера, chip і time-picker) і §4 («поки лишаємо AppKit hand-drawing») виконано —
> вікно Settings переписано на SwiftUI `Form.formStyle(.grouped)` + `NavigationSplitView`, тож
> grouped-inset/chip/time-picker більше **не** ручні винятки (їх дають Form/List/DatePicker системними
> дефолтами), а виміряні константи усунено. Принцип §1 «нуль хардкоду для системних елементів» лишається
> чинним.
>
> **Частково переглянуто [ADR-0059](0059-menu-bar-native-semantic-colours.md):** §3-виняток «menu-bar
> `StatusItemView` — фіксований sRGB, бо `labelColor` дає неправильний RGB» **скасовано** — бар тепер
> підпорядковано §1 (нуль хардкоду): системні semantic-кольори (`labelColor`-родина + `.system*`).
> Виняток pacing-барів **попапа** (ADR-0022) лишається.
>
> **Частково уточнено [ADR-0069](0069-settings-window-height-resizable.md):** клауза §1 «Вікно →
> фіксоване 857 pt» стосується тепер лише **ширини** — висота вікна Settings користувацька (resizable)
> і персистується. Принцип §1 цим не порушено, а виконано: ресайз якраз усуває хардкод, бо ручні бампи
> фіксованої висоти під кожну нову опцію Appearance більше не потрібні — контент скролить системним
> `Form.grouped`. Sidebar 258 лишається фіксованим.

## Контекст

Мета продукту — **TokenPace має максимально слідувати дизайну рідних застосунків macOS** (передусім
System Settings). Під час великого проходу паритету (#156, поверх redesign #131 / ADR-0035) виявилося,
що вікно Settings рясніло **захардкодженими** розмірами, шрифтами, відступами й кольорами, підібраними
«на око». Це давало відхилення від System Settings, які нескінченно «підкручувались» числами.

Корінна причина: код **малює grouped-inset UI вручну** (кастомний `SettingsCard`, кастомний chip за
sidebar-іконкою, свій `NSTableView`, ручні констрейнти рядків), обходячи системні механізми AppKit,
які самі дають нативний вигляд.

Постало рішення того ж класу, що ADR-0009…0011 (де межа системного vs власного): **що брати з системи,
а що лишати власним — і як не хардкодити те, що система дає сама.**

## Рішення

**1. Для стандартних системних елементів — нуль захардкоджених метрик.** Використовувати те, що AppKit
дає сам, замість підбирати числа:

- Розмір sidebar-іконок → читати `NSTableViewDefaultSizeMode` (`NSGlobalDomain`), реагувати на зміну
  через `DistributedNotificationCenter` (`AppleSideBarDefaultIconSizeChanged`). `effectiveRowSizeStyle`
  **не** резолвить `.large` для source-list — не покладатись на нього.
- Перемикачі → `NSSwitch.controlSize = .mini`; popup → `.flexiblePush` + `.small` +
  `showsBorderOnlyWhileMouseInside`; шрифти → `NSFont.systemFontSize`/`smallSystemFontSize`/text styles.
- Вирівнювання рядків → `NSStackView.alignment = .firstBaseline` + `edgeInsets` (висота рядка = контент
  + симетричний inset), а не ручне центрування top/bottom (робить текст top-heavy).
- Символи секцій → точні з `.appex Info.plist` System Settings (General=`gear`, Notifications=
  `bell.badge.fill`, вага `.regular`). Довгі мітки → truncate + `allowsExpansionToolTips`. Шлях до
  папки → `NSPathControl`. Вікно → фіксоване 857 pt (як System Settings), sidebar фіксований 258.

**2. Винятки — де AppKit НЕ має API (хардкод неминучий, але ВИМІРЯНИЙ, не вгаданий).** macOS AppKit не
має iOS-подібних grouped-примітивів; System Settings рендерить через SwiftUI/приватне, чистого
AppKit-аналога немає. У цих місцях малюємо вручну, але значення **виміряні з живого System Settings**
(AX `AXSize` / Retina ÷2) і задокументовані:

- **Колір картки/фону** — немає семантичного grouped-background (ні `NSColor`, ні матеріалу з
  правильним light↔dark фліпом) → фіксований dynamic `NSColor` (картка 242/43, фон 246/40).
- **Grouped-inset контейнер** (`SettingsCard` row height, corner radius, padding) — AppKit не має
  контейнера з цими дефолтами → ручне малювання з виміряними значеннями.
- **Скруглений time picker** — `NSDatePicker` не округлює власний bezel → bezelless picker у кастомному
  `RoundedFieldBox`.
- **Кольоровий sidebar-chip** — стандартний `.imageView` outlet накладає source-list tint/vibrancy
  (блідне, зникає на неактивному вікні) → кастомний chip, розмір із виміряної таблиці.

**3. Свідомі власні винятки (не System Settings-елементи).** Фіксована палітра лишається:
- Menu-bar-віджет (`StatusItemView`) — фіксований sRGB, бо `labelColor` дає неправильний RGB в
  off-screen `NSImage` (ADR-0009).
- Pacing-бари попапа — фіксована палітра, спільна зі statusline (ADR-0022).

**4. Остаточний паритет без констант — SwiftUI Form.** System Settings — це SwiftUI
`Form { Section }.formStyle(.grouped)` (перевірено: і shell, і pane-extensions лінкують SwiftUI). Це
єдиний спосіб отримати row height/padding/corner radius/dividers **системними дефолтами** без жодної
константи. Переписати `SettingsCard` на SwiftUI Form через `NSHostingView` (#168); поки що
лишаємо AppKit hand-drawing з виміряними значеннями (менший ризик, фазовано).

## Наслідки

- **Процес верифікації посилено:** будь-яка UI-зміна перевіряється в **обох** темах (light+dark) і
  **всіх** станах (sidebar icon size 1/2/3, dev-білд/`.app`) скриншотами перед PR. Пропуск цього був
  найчастішою причиною регресій у #156 (див. [system-settings-parity.md](../reference/system-settings-parity.md)).
- Частина ADR-0035 переглянута: ручний `controlBackgroundColor` fill картки → dynamic grouped-колір /
  material-підхід; чекбокс-дизейбл-логіка поширена на «Back to work» для dev-білдів.
- Де хардкод неминучий — він **іменований, виміряний і задокументований**, не «магічне число».
- Детальний розбір (уроки, метод вимірювання, типові помилки) — у
  [docs/reference/system-settings-parity.md](../reference/system-settings-parity.md).

## Пов'язане

- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — pure-core/thin-shell; menu-bar
  фіксований колір (виняток §3).
- [ADR-0021](0021-popup-two-column-layout-and-uniform-dropdown-typography.md) — HIG-звірка перед
  комітом; «не eyeball-ити розмір».
- [ADR-0022](0022-popup-bar-transparency-and-contrast-experiment.md) — pacing-бари фіксована палітра.
- [ADR-0035](0035-settings-window-sidebar-grouped-inset.md) — початковий Settings-redesign (частково
  переглянутий тут).
- Issue #156.
