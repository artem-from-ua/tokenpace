---
status: accepted
date: 2026-07-27
superseded_by: [0069]
---

# ADR-0042: Вікно Settings — SwiftUI Form.grouped замість ручного AppKit-малювання

> **Частково переглянуто [ADR-0069](0069-settings-window-height-resizable.md):** клауза §4 про
> геометрію вікна («857×480 fixed … hidden zoom/miniaturize») більше не чинна — вікно **resizable по
> висоті** (ширина 857 лишається запіненою), zoom і miniaturize **показані**, зелена кнопка розтягує
> вертикально, а фрейм персистується з валідацією проти поточної конфігурації екранів. Там-таки
> з'ясувалося, що `NSHostingController` затирає всі size-межі вікна під час першого layout-проходу,
> тож пін ширини тримає `windowWillResize`, а не `contentMinSize`/`contentMaxSize`. Решта рішення
> (SwiftUI `Form.formStyle(.grouped)`, `NavigationSplitView`, `@Observable SettingsModel`, дослівно
> збережений контракт `AppDelegate.openSettings`) чинна.

## Контекст

ADR-0035 переписав вікно Settings на sidebar + grouped-inset картки, реалізовані **вручну на AppKit**
(`SettingsCard`/`SettingsRow`/`RoundedFieldBox`/`DividerView`, source-list `NSTableView`). Прохід
паритету #156 (ADR-0040) довів це наближення до System Settings **виміряними** константами (row 37 pt,
corner 4 pt, inset 12/11 pt, divider inset 10 pt, hairline 0.5 pt — див.
[system-settings-parity.md](../reference/system-settings-parity.md)).

Це працює й близько до системного, але має корінну ваду, яку ADR-0040 назвав прямо (§4): AppKit **не
має** grouped-inset контейнера (`NSTableViewStyle.insetGrouped` — iOS-only; `NSBox` дає лише `.custom`
= знову ручне малювання). System Settings рендерить свої картки через SwiftUI
`Form { Section }.formStyle(.grouped)` (перевірено: і shell, і pane-extensions лінкують SwiftUI). Тому
наші константи:

- можуть розійтися з майбутніми macOS (вони — знімок однієї версії System Settings);
- це не «системний дефолт», а reverse-engineered наближення;
- суперечать головному принципу ADR-0040 — «нуль хардкоду для системних елементів».

ADR-0040 §4 уже **явно санкціонував** остаточний фікс: переписати панелі на SwiftUI Form через
`NSHostingView`, «поки що лишаємо AppKit hand-drawing (менший ризик, фазовано)». Цей ADR фіксує рішення
виконати той перехід (#168).

## Рішення

**1. Detail-панелі й sidebar вікна Settings переписуються на SwiftUI**, вбудований у наявне `NSWindow`
через `NSHostingController`. `Form { Section }.formStyle(.grouped)` дає row height, padding, corner
radius, dividers і card-spacing **системними дефолтами** — нуль констант. Sidebar → `NavigationSplitView`
+ `List(.sidebar)` (замість source-list `NSTableView` + кастомний chip). Це перший SwiftUI-плацдарм у
проєкті (доти — чистий AppKit); target `.macOS(.v15)` + Swift 6.1 роблять `@Observable` і сучасний
SwiftUI Form доступними без правок `Package.swift`.

**2. Стан живе в `@Observable SettingsModel`, поза SwiftUI-в'юхою.** Раніше стан жив у AppKit-outlet'ах,
і **eager-build** усіх панелей був неминучий: фонові callback-и (`updateAvailability`/
`updateArchiveStatus` з поллінг-completion при **закритому** вікні) торкалися outlet'ів → nil-crash за
лінивої побудови. Тепер ці методи мутують модель, що живе стільки, скільки `SettingsWindowController`, —
тож eager-build **прибирається**, SwiftUI-панелі будуються ліниво без ризику. Це і спрощення, і
збереження інваріанту.

**3. Публічний контракт `AppDelegate.openSettings` зберігається дослівно.** `SettingsWindowController`
стає тонкою hosting-обгорткою: ті самі 10 closure-property + `archiveSummaryProvider` +
`updateAvailability(_:)` + `updateArchiveStatus()` + `show()` + `convenience init()`, тепер
forward-яться в `SettingsModel`. `App.swift` (wire-инг контракту + фонові callsite-и) **не змінюється
ані на рядок** — це головний захисний інваріант рефактора. Кожен сеттер моделі зберігає порядок
**persist-then-callback** (спершу `PersistedConfig`, тоді `onXChange?`), як теперішні `@objc`-екшени;
resync на `show()` захищений `isSyncing`-guard від ретригера callback-ів.

**4. Складні AppKit-місця мостяться, не переписуються наосліп:**
- «Choose…» для папки архіву → імперативний `NSOpenPanel().runModal()` у методі моделі (зберігає
  `prompt`/`message`/seed-`directoryURL` і поведінку «toggle-on без destination → одразу prompt»);
  `.fileImporter` не дає prompt/message.
- Час дозволених годин → `DatePicker(.hourMinute)` через `Binding<Date>`↔minute-of-day адаптер
  (`date(fromMinuteOfDay:)`/`minuteOfDay(from:)` переносяться дослівно), замість bezelless-`NSDatePicker`
  у `RoundedFieldBox`.
- Suppress-days → `Picker(.menu)` (сам сайзиться під вибране), замість `NSPopUpButton` +
  `resizeSuppressPopup()` width-hack.
- Вікно (857×480 fixed, `.floating`, `isReleasedWhenClosed=false`, hidden zoom/miniaturize, width-pin,
  `NSApp.activate`) — лишається чистим AppKit у контролері. Фіксована ширина тримається NSWindow-pin'ом
  (авторитетний); всередині — `.navigationSplitViewColumnWidth(258)` на sidebar.

## Наслідки

- **Таблиця виміряних констант картки зникає з коду й docs.** `SettingsCard`/`SettingsRow`/
  `RoundedFieldBox`/`DividerView`/`FlippedView`/`SettingsColors`, `SettingsSplitViewController`,
  `SettingsSidebarController` (+`ChipView`/`iconMetrics`/`AppleSideBarDefaultIconSizeChanged`-observer)
  — **видаляються**. `system-settings-parity.md` втрачає таблицю «Виміряні метрики картки» та розділ
  про grouped-inset як виняток (тепер його дає SwiftUI Form). `SettingsWindowController` худне з ~1172
  до ~90 рядків.
- **Частина ADR-0035 і ADR-0040 переглянута далі:** grouped-inset контейнер, chip і time-picker більше
  **не** ручні AppKit-винятки — їх дає SwiftUI Form/List/DatePicker системними дефолтами. Свідомі
  винятки §3 ADR-0040 (menu-bar `StatusItemView`, pacing-бари попапа) лишаються чинними — вони не
  System Settings-елементи.
- **Верифікація лишається строгою** (ADR-0040): будь-яка UI-зміна — в обох темах (light+dark) і всіх
  станах (sidebar icon size тепер системний List, dev-білд/`.app`) скриншотами перед PR. Greenfield
  SwiftUI-паритет доводиться саме скриншотами поряд із System Settings.
- **Немає UI-тестів** (наявні тести цілять лише в `TokenPaceKit`), тож чиста логіка моделі
  (`ResetCountdownMode` ↔ radio+checkbox fold, minute-of-day↔Date, computed enablement) виноситься у
  static-функції й покривається новими Kit-юнітами.
- **`App.swift` — zero-diff.** `git diff Sources/TokenPace/App.swift` має бути порожнім у діапазоні
  контракту.

## Пов'язане

- [ADR-0035](0035-settings-window-sidebar-grouped-inset.md) — початковий sidebar+grouped-inset redesign
  (тіло історичне; цей ADR завершує перехід, який 0040 §4 передбачив).
- [ADR-0040](0040-native-system-metrics-no-hardcoded-ui.md) — принцип «нуль хардкоду»; §4 санкціонував
  саме цей SwiftUI-Form-перехід.
- [ADR-0012](0012-configure-window-and-launch-at-login.md) — floating-level accessory-вікно (збережено).
- [system-settings-parity.md](../reference/system-settings-parity.md) — виміряні константи, які цей
  перехід усуває.
- Issue #168 (переписання), #156 (паритет).
