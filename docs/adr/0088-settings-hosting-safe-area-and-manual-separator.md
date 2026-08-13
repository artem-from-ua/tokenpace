---
status: accepted
date: 2026-08-13
---

# ADR-0088: Detail-панель Settings — safe area відрізається на межі хостингу, риску тулбара веде контролер

> Уточнює [ADR-0069](0069-settings-window-height-resizable.md): мінімум висоти 480 → 470, а §2
> («скрол перевірено вживу на 300 pt») описував збірку до
> [#311](https://github.com/artem-from-ua/tokenpace/issues/311) — доданий там тулбар із
> `.fullSizeContentView` увімкнув баг пропагації safe area, і скрол панелі зламався непомітно.

## Контекст

[#346](https://github.com/artem-from-ua/tokenpace/issues/346): панель Settings, вища за вікно,
**обрізалась знизу замість скролитися** — скролбар не з'являвся, колесо давало rubber-band.
Гіпотеза тікета (`.frame(minHeight:)` на корені `NavigationSplitView`) спростована арифметично ще до
коду: на дефолтних 732 pt підлога 480 неактивна (`max(732, 480) = 732`), а баг відтворювався саме там.

Причину дав **замір живого дерева, не теорія**: перший SwiftUI-нащадок хостинга —
`PlatformViewHost<NavigationSplitRepresentable>` — розкладався **496 pt у вікні 470** (+26 =
половина 52-pt safe area тулбара) на будь-якій висоті вікна. Все нижче успадковувало 496: хвіст
кожної панелі та нижні 26 pt скролера висіли за краєм вікна, недосяжні. Це підтверджений Apple баг
пропагації safe area в detail-колонку `NavigationSplitView` під `NSHostingController` —
rdar://122947424, підтверджений інженером Apple Frameworks у
[треді 746611](https://developer.apple.com/forums/thread/746611).

Побічні знахідки в ході фіксу, кожна з власним заміром:

- **Риска тулбара** над detail-колонкою малювалась постійно, навіть при скролі на самому верху.
  `NSTitlebarSeparatorStyle.automatic` не біндиться до мостового scroll view — виміряно у **двох**
  конфігураціях: із незайманими інсетами моста (`automaticallyAdjustsContentInsets = false`,
  інсет 52) і з примусово повернутим `= true`. Лінія в обох випадках не реагує на скрол.
  Sidebar-колонка (`List`, auto=true) поводиться правильно — саме цей контраст спершу повів
  хибним слідом «повернути auto».
- **Перша картка на ~70 pt** проти системних 52 (виміряних у #311): grouped `Form` тримає **18 pt
  власного відступу всередині документа** (виміряно по позиціях карток; `defaultMinListHeaderHeight`
  не впливає — перевірено). Жоден публічний API ці 18 pt не прибирає.
- **Мінімум висоти** 480 був вищий за системний. Реальний мінімум System Settings, знятий із window
  server (`CGWindowListCopyWindowInfo`) із вікном, стиснутим до упору, — **857 × 470**. Frame ≡
  content в обох вікнах (`.fullSizeContentView`: тайтлбар накладається на контент, а не додається до
  нього); перша оцінка «443» зі скріншота була хибною саме тому, що віднімала неіснуючий тайтлбар.

## Рішення

**1. `hosting.safeAreaRegions = []` — корінь.** SwiftUI не отримує window-chrome safe area, і міст
розкладається точно у вікно (виміряно: сплiт 470 у вікні 470, на всіх висотах). Інсет під тулбар
колонки тримають самі — міст бере його з вікна, не з цієї safe area (виміряно після зміни: 52 і в
sidebar, і в detail).

**2. Риску веде контролер.** Правило системи — нема у спокої, hairline щойно контент заїжджає під
тулбар — реалізоване прямо: спостерігач `boundsDidChangeNotification` на clip view перемикає
`NSSplitViewItem.titlebarSeparatorStyle` між `.none` і `.line`
(`SettingsWindowController.driveDetailTitlebarSeparator()`). Ре-хук на кожній зміні панелі, бо
перемикання перебудовує scroll view — та сама дисципліна, що в `pinSidebarSplit()`.

**3. Перша картка на 52.** `.contentMargins(.top, −18, for: .scrollContent)`: інсет 52 − 18 = 34,
плюс 18 pt власного відступу документа = 52. Число інструментоване, не підібране оком.

**4. Мінімум висоти 470** — виміряний системний. Enforcement незмінний — `windowWillResize`
([ADR-0069 §3](0069-settings-window-height-resizable.md)).

**Відкинуті важелі** — усі виміряні; таблиця існує, щоб їх не пробували вдруге:

| Важіль | Виміряний наслідок |
|---|---|
| прибрати/зменшити `.frame(minHeight:)` на корені | `docH` незмінний — гіпотеза тікета не тримається |
| `VStack`-обгортка detail-колонки | інсет 32→52, `docH` незмінний |
| `.frame(maxHeight: .infinity, alignment: .top)` | `docH` незмінний |
| `.padding(.top, −20)` на панелі | зсуває весь pane разом зі scroll view — верх скролера обрізаний |
| `.safeAreaPadding(.top, −20)` | клемпиться до нуля, no-op |
| `.contentMargins(.bottom, N)` / `.safeAreaPadding(.bottom, N)` | розтягує сам scroll view на N нижче вікна — низ скролера за краєм (виміряно: навіс −26) |
| `sizingOptions = [.minSize]` | вікно дістає підлогу = ідеал дерева (522) — стискання нижче неможливе |
| примусовий `automaticallyAdjustsContentInsets = true` | інсети ті самі 52, риска все одно постійна |
| `defaultMinListHeaderHeight` | на 18 pt документа не впливає |

## Наслідки

- У `SettingsWindowController` четвертий bridge-патч (`driveDetailTitlebarSeparator`) поряд із
  `pinSidebarSplit` / `claimDividerCursor` / `mergeSidebarTitlebarStrip` — усе це ціна
  `NavigationSplitView` всередині `NSHostingController`. Рахунок росте; якщо знадобиться п'ятий,
  варто зважити нативний `NSSplitViewController` із двома hosting-колонками замість моста.
- Інсети detail-колонки **не можна чіпати** SwiftUI-модифікаторами понад згаданий top-margin:
  будь-який `.padding` / `.safeAreaPadding` / `.contentMargins(.bottom, …)` ламає геометрію
  скролера — див. таблицю.
- `safeAreaRegions = []` означає, що SwiftUI-дерево вікна Settings не бачить safe area взагалі.
  Якщо колись з'явиться вміст, який на неї покладається (нижній бар, оверлей поверх тулбара),
  інсет доведеться давати явно.
- Автоматична риска (`.automatic`) для цього вікна непридатна за конструкцією; будь-який майбутній
  перегляд має або зберегти ручний драйвер, або довести заміром, що `.automatic` забіндився.
- Сценарій верифікації — [ui-verification.md](../guides/ui-verification.md#скрол-detail-панелі-риска-тулбара-мінімальна-висота-346);
  метод діагностики таких багів —
  [agent-workflow.md § «Діагностика layout-багів у вікнах»](../guides/agent-workflow.md#діагностика-layout-багів-у-вікнах).

## Пов'язане

- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — pure core / thin shell (чому вікно — AppKit-shell).
- [ADR-0042](0042-settings-swiftui-form.md) — SwiftUI `Form` + `NavigationSplitView` (міст, який тут патчиться).
- [ADR-0069](0069-settings-window-height-resizable.md) — resizable висота; §2 і мінімум уточнено цим ADR.
- [ADR-0077](0077-settings-toolbar-segmented-back-forward.md) — тулбар, чия safe area і є тригером.
- [#346](https://github.com/artem-from-ua/tokenpace/issues/346), [#311](https://github.com/artem-from-ua/tokenpace/issues/311).
- [Тред 746611](https://developer.apple.com/forums/thread/746611) (rdar://122947424).
