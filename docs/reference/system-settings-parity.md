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

1. **Спершу перевір, чи є системний механізм.** Історично більшість «магічних чисел» у Settings
   існувала лише тому, що ми **малювали grouped-inset вручну**, а не використовували системний
   контейнер. Перш ніж підбирати число — спитай: «а чи система не дає це сама?».
2. **Detail-панелі Settings тепер на SwiftUI `Form { Section }.formStyle(.grouped)`** (ADR-0042, #168) —
   як і сам System Settings. Row height/padding/corner radius/dividers — **системні дефолти, нуль
   констант**. Виміряна таблиця метрик картки, що жила тут раніше, **видалена** — вона описувала
   `SettingsCard`, якого більше немає. AppKit усе ще не має grouped-inset контейнера — тому й перейшли
   на SwiftUI Form, а не підбирали числа.
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
| Розмір sidebar-іконок | **виняток: зафіксовано на Large** (#335). Раніше читали `NSTableViewDefaultSizeMode` (`NSGlobalDomain`, 1/2/3=S/M/L) через `DistributedNotificationCenter` (`AppleSideBarDefaultIconSizeChanged`) — механізм працював, але слідував **лише** розмір чіпа: ширину колонки SwiftUI не віддає (виміряно: `.navigationSplitViewColumnWidth(259)` → 307 pt; `.frame(width:)` не масштабує зовсім — 200 → 307, 240 → 243, 340 → 243), а інсет рядка тягнеться за шириною списку (32.5 pt на Small проти системних 10) і `listRowInsets` уміє лише **додавати** до 20-pt підлоги. Слідувати одній осі з кількох = не збігатися з системою на жодному розмірі | `effectiveRowSizeStyle` **не** резолвить `.large` для source-list — не покладатись на нього |
| Розмір перемикачів | `NSSwitch.controlSize = .mini` (26×15 pt — точний збіг із System Settings) | не `.regular`/`.small` (завеликі) |
| Popup-меню (dropdown) | `.flexiblePush` + `.small` + `showsBorderOnlyWhileMouseInside = true` (компактний, borderless-at-rest) | не `.push`/`.automatic` (важка синя рамка) |
| Шрифти | `NSFont.systemFontSize` (13) / `NSFont.smallSystemFontSize` (11) / text styles | не сирі `ofSize: 11`/`12` |
| **Ширина** вікна | **857 pt, фіксована** (виміряно з System Settings), sidebar **фіксований 258** | не робити ширину resizable — sidebar/detail (258/599) налаштовані під неї й попливуть; не робити sidebar динамічним «під найдовший label» — System Settings цього не робить |
| **Висота** вікна | **resizable** від 480 pt угору, дефолт 732 (ADR-0069). Пін ширини тримає `windowWillResize` — `NSHostingController` затирає всі size-межі під час першого layout-проходу. Зелена кнопка = **вертикальний** zoom; фрейм персистується з валідацією проти `NSScreen.visibleFrame` | не бампити фіксовану висоту вручну під кожну нову опцію Appearance (так робили до ADR-0069 — 480→…→732); не вмикати full-screen (`.floating`-вікно воює з full-screen Space, ADR-0020); не покладатися на `contentMinSize`/`contentMaxSize` як на enforcement |
| Заголовок вікна | Титульна смуга **без тексту й прозора** (`titleVisibility = .hidden` + `titlebarAppearsTransparent`), а назва пейна — айтем **нашого AppKit-тулбара** (`SettingsToolbarController`, 15 pt semibold — виміряно попіксельно проти системного, #311). Це закриває HIG-мандат «відображати вибрану секцію» (#156 §2) | не лишати текст у титульній смузі (дублює назву пейна); **не** класти назву в SwiftUI `ToolbarItem`: `.navigation` кладе її над **сайдбаром** біля світлофора (переперевірено і через `sceneBridgingOptions`-міст у #314 — той самий результат), `.principal` центрує по всьому вікну, а trailing `Spacer` її не зсуває (айтем стискається до інтринсику) |
| Кнопки ‹ › історії | **Один** `NSToolbarItem`, view = `NSSegmentedControl` (`.separated`, `.momentary`, template-шеврони 13 pt medium `.large`), без жодного ручного розміру — контрол самозбирається в 80×40, слот 76×52, плашки 33/34×28 впритул, як у System Settings ([ADR-0077](../adr/0077-settings-toolbar-segmented-back-forward.md)) | не робити пару **двома** айтемами: hover-зона згенерованого `NSToolbarButton` — це його **плашка** (кнопка − 12 pt), тож між окремими кнопками завжди лишається мертва зона (#314, вичерпано в #313); не класти в кастомний view plain `NSButton` — поза генерацією тулбара він **не малює** hover-плашку взагалі |
| Матеріал під світлофором | `styleMask` містить **`.fullSizeContentView`** — split view йде на всю висоту, тож vibrancy сайдбару продовжується за титульною смугою | без нього смуга над сайдбаром малює фон **вікна** (виміряно 40,40,40 у dark) проти 70,70,70 самого сайдбару — видимий шов рівно там, де світлофор |
| Позиція кнопок вікна (світлофор) | порожній `NSToolbar` + **`window.toolbarStyle = .unified`**. Прямого API для позиції світлофора немає — AppKit кладе його відносно висоти titlebar+toolbar, тож потрібну висоту дає саме тулбар. Виміряно на еталонному скріншоті System Settings: центр червоної кнопки **(25.75, 25.75) pt** від початку вікна, діаметр 11.5 pt; наш рендер збігається до пікселя | не лишати вікно без тулбара — голий `.titled` дає (13.5, 13.5) pt, тобто світлофор на ~12 pt вище й лівіше системного; **`.unifiedCompact` теж не підходить** — дає (18.75, 18.75); не рухати кнопки вручну |
| Вирівнювання рядка | `NSStackView` `.alignment = .firstBaseline` + `edgeInsets` визначають висоту рядка | не центрувати текст руками через top/bottom-pin (робить текст top-heavy) |
| Символи секцій | точні з `.appex Info.plist` System Settings: General=`gear` (не `gearshape`), Notifications=`bell.badge.fill`; вага `.regular` | не вгадувати символ; не `.semibold` (затовсто) |
| Довгі sidebar-мітки | truncate на одному рядку + `allowsExpansionToolTips = true` (HIG) | не wrap |
| Шлях до папки | `NSPathControl` (сам обрізається, клік→Finder, не розпирає layout) | не голий `NSTextField` (розпирає вікно) |

## Що дає SwiftUI Form безкоштовно (колишні AppKit-винятки)

macOS AppKit не має iOS-подібних grouped-примітивів. Раніше через це доводилося малювати вручну з
виміряними константами. **Тепер detail-панелі на SwiftUI (ADR-0042)**, і всі ці місця дає система:

- **Grouped-inset контейнер** (row height, corner radius, padding, dividers, card-spacing) →
  `Form { Section }.formStyle(.grouped)`. Колишній `SettingsCard`/`SettingsRow` і виміряні константи
  (row 37 / inset 12/11 / corner 4 / divider 10 / hairline 0.5 pt) **усунено** — тепер це системні
  дефолти без жодної константи.
- **Колір картки / фону панелі** → `Form.grouped` бере системний grouped-background сам (раніше —
  ручний dynamic `NSColor` 242/43, 246/40, бо `.contentBackground`-матеріал давав чисто-білий баг).
- **Скруглені кутики time picker** → нативний `DatePicker(.hourMinute)` (раніше — bezelless
  `NSDatePicker` у кастомному `RoundedFieldBox` з виміряними insets).
- **Кольоровий chip за sidebar-іконкою** → `List(.sidebar)` + `Label`/`.foregroundStyle` (раніше —
  кастомний `ChipView`, бо стандартний `.imageView` outlet накладав source-list tint/vibrancy).

Menu-bar-віджет (`StatusItemView`) тепер малює **системними semantic-кольорами** (`labelColor`-родина +
`.system*`, ADR-0059), не фіксованим sRGB — вони й дають нативний вигляд/дихання. Pacing-бари **попапа**
теж перейшли на системні semantic-кольори (ADR-0060; трійка `.systemRed/Yellow/Orange`, track
`labelColor@0.22`, крім Claude-бренду) — це **не** System Settings-елементи, і SwiftUI Form їх не
стосується.

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
   notification, не local defaults-KVO. (Уроки 5–6 про механізм лишаються чинними, але sidebar його
   більше не використовує — розмір зафіксовано на Large, #335. Заразом виміряно, що `defaults write`
   цієї нотифікації **не шле** — її шле сам System Settings, тож перевіряти реакцію на зміну треба
   через його UI, а не через `defaults`.)

## Як вимірювати System Settings (метод)

- **AX `AXSize`/`AXPosition`** — точні розміри вікна, sidebar, рядків (`AXOutline`, `AXOutlineRow`).
- **Retina-скриншот ÷2** — кольори (pixel-семпл центру), геометрія, кути.
- **`.appex Info.plist`** — символи/tint секцій System Settings (`ISSymbolName`/`ISEnclosureColor`).
- **SDK-хедери** (`NSTableView.h` тощо) — які API/стилі реально існують (не з пам'яті!).
- Не вгадувати з training-data: HIG-сайт SPA-рендериться, часто не піддається `WebFetch` — шукати
  офіційні сторінки/форуми Apple, чесно позначати межу впевненості (конвенція, ADR-0021).

## Пов'язане

- [ADR-0042](../adr/0042-settings-swiftui-form.md) — перехід detail-панелей на SwiftUI Form (усунув
  виміряні константи картки, що жили в цьому довіднику).
- [ADR-0040](../adr/0040-native-system-metrics-no-hardcoded-ui.md) — рішення-принцип «нуль хардкоду».
- [ADR-0035](../adr/0035-settings-window-sidebar-grouped-inset.md) — початковий redesign (двічі
  переглянутий: 0040 material/dynamic-колір, 0042 SwiftUI Form).
- [conventions.md](conventions.md) § UI-дизайн (AppKit).
- [ui-verification.md](../guides/ui-verification.md) — стуби й процес живої верифікації.
- Issue #156 (паритет), #168 (SwiftUI-Form-переписання).
