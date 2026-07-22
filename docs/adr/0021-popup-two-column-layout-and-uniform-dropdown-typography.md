---
status: accepted
date: 2026-07-23
---

# ADR-0021: Popup — двоколонковий layout, ⌥-gated статуси, єдиний шрифт дропдауна

## Контекст

Серія UI-ітерацій над popup-дропдауном (`PopupViewController`) звела докупи кілька дрібних правок,
які разом становлять один візуальний патерн, вартий фіксації — щоб наступна зміна попапу
продовжувала його, а не випадково розійшлася новим підходом:

1. Кожен рядок деталей лімітної секції (`"20% used  ·  resets in ~20m at 05:30"`) був **одним**
   рядком з `·`-роздільником — «resets in» не було нічим прив'язане до правого краю бару під ним.
   Так само перший рядок секції (`"Claude Code  ·  ahead of pace"`).
2. Рядки статусу сервісів Claude (issue #31) показувались **завжди**, займаючи постійний простір
   навіть коли обидва компоненти `operational` — цінність для більшості відкриттів попапу нульова
   (віджет перевіряють заради чисел, не заради зеленого «все ок»).
3. Заголовок секції "Claude Code" і нативні пункти меню («Settings…», «Quit…») в тому самому
   дропдауні мали **незалежно підібрані** розміри шрифту — спроба зрівняти їх «на око» через
   `NSFont.menuFont(ofSize: 0)`, потім через емпіричний підбір (16 pt), обидва рази не збіглася з
   реальним рендером `NSMenuItem`.

## Рішення

1. **Двоколонковий split-layout замість одного рядка з `·`.** Новий приватний хелпер
   `addSplitLine(left:right:leftFont:rightFont:leftColor:rightColor:)` — `NSStackView` з
   `.distribution = .equalSpacing`, шириною, форсованою на `Metrics.width - 2·hPadding` (той самий
   контент-width, що й бар під ним). `addTitleStatusLine` (title/pacing) і `addDetailLine`
   (used/reset) обидва делегують сюди — права половина завжди вирівняна по правому краю бару.
   Побічний ефект: бар теж розтягнутий на повну контент-ширину (раніше — фіксовані 240 pt) — обидва
   тепер поділяють один і той самий правий край.

2. **Секція статусу сервісів — ⌥-gated, не завжди видима.** `PopupViewController.optionHeld: Bool`
   (`didSet` → `rebuild()`) фідиться з `App.swift`'s `updateActionItemForOption(_:)` — того самого
   modifier-poll timer, що вже перемикає «Settings…»/«Troubleshoot…» (ADR-0020 §3). Умова показу:
   `status?.worstProblem != nil || optionHeld` — реальна проблема **завжди** показується незалежно
   від ⌥ (саме тоді попап повинен пояснювати себе), «усе гаразд» — лише під ⌥. Разом зі статусами
   ховається/показується і рядок «Updated … · interval …» (та сама секція).

   **Критична деталь:** `NSMenu` не перевимірює хостоване `NSMenuItem.view` самостійно при зміні
   контенту (`NSMenu` лейаутить з `frame`, не Auto Layout — та сама пастка, що описана в
   `setPopupLayout`'s коментарі для звичайних live-полів). Тому `updateActionItemForOption(_:)` після
   `popupVC.optionHeld = optionHeld` **обов'язково** повторює `popupVC.view.frame =
   NSRect(origin: .zero, size: popupVC.view.fittingSize)` — без цього дропдаун не змінює висоту при
   затисканні ⌥, хоча контент коректно рендериться.

3. **Один спільний конструктор шрифту для всього дропдауна — не підбір «на око».** Немає надійного
   способу *прочитати*, яким саме шрифтом/розміром AppKit реально малює `NSMenuItem.title` в
   сучасному (Big Sur+ redesign) меню: `NSFont.menuFont(ofSize: 0)` документовано повертає 13 pt
   (`= NSFont.systemFontSize`), але рендериться помітно менше за фактичний нативний пункт; ручний
   підбір через скріншот-порівняння (спробувано 14/15/16/17 pt) теж не дав стабільного результату —
   16 pt здавався найближчим у пробному ряду, але поруч із реальним «Settings…» виявився явно
   завеликим. Замість продовжувати підбір, рішення — **писати**, а не читати: одна пакетна константа

   ```swift
   let dropdownTextSize: CGFloat = NSFont.systemFontSize   // PopupViewController.swift, file-scope
   ```

   застосована явно з обох боків:
   - `PopupViewController` — усі лейбли (`Metrics.textSize = dropdownTextSize`), різниця лише вага
     (`.boldSystemFont`/`.systemFont`), ніде більше немає захардкодженого `ofSize:`.
   - `App.swift` — нативні пункти («Settings…»/«Troubleshoot…», «Quit…») отримують
     `NSMenuItem.attributedTitle` (не голий `.title`) з тим самим `NSFont.systemFont(ofSize:
     dropdownTextSize)` через хелпер `dropdownMenuItemText(_:)`, включно з динамічним свапом у
     `updateActionItemForOption(_:)`.

   Розбіжність стає структурно неможливою — обидва боки читають одну змінну, замість того щоб два
   незалежні викликання AppKit-API випадково збігтися.

## Наслідки

- `PopupViewController.Metrics` більше не містить `barWidth`, `titleSpacing`, `separatorPadding`,
  `statusToLimitsSpacing` — усі поглинуті єдиним `sectionSpacing` (той самий проміжок і після
  заголовка секції, і між лімітними секціями/барами) або відпали разом із видаленим титульним
  рядком/рискою (`addSeparator`/`addSeparatorIfNeeded` видалені як мертвий код — жодна секція
  дропдауна більше не розділяється лінією, лише whitespace; HIG однаково допускає обидва підходи до
  групування, це стилістичний, не комплаєнс-вибір).
- Попап більше не показує окремий заголовок «TokenPace» — перший рядок дропдауна тепер «Claude
  Code» (бренд-колір `#d97757`, підтверджений з `anthropics/skills`' `brand-guidelines/SKILL.md`).
  Розрізнення dev-build/installed `.app` (issue #69), яке раніше жило в цьому заголовку, переїхало
  в пункт «Quit» (`"Quit TokenPace (dev build)"` на bare `swift run`).
- `PopupLayout.rows(from:now:)` (`TokenPaceKit`, pure) — заголовки секцій втратили слово «limit»:
  `"5-hour limit"` → `"5-hour"`, `"7-day limit"` → `"7-day"`. `PopupLayoutTests` оновлено відповідно.
- `docs/conventions.md` отримує нову секцію «UI-дизайн (AppKit)»: обов'язкова звірка з актуальними
  Apple HIG перед комітом UI-зміни (не з пам'яті — HIG-сайт SPA-рендериться, `WebFetch` часто
  повертає порожній контент; резервний шлях — `WebSearch` на офіційні сторінки Apple Developer, з
  чесним позначенням межі впевненості, коли точного офіційного числа не знайдено), і сам принцип
  «один спільний конструктор шрифту, не підбір на око» — узагальнений з цього ADR на будь-який
  майбутній AppKit-екран.

## Пов'язані

- [ADR-0020](0020-troubleshoot-window-and-diagnostics-pipeline.md) §3 — той самий modifier-poll
  timer (`optionPollTimer`/`updateActionItemForOption`), тепер фідить і `popupVC.optionHeld`.
- [ADR-0013](0013-claude-status-line.md) — `StatusHealth`/`ServiceStatus`/`worstProblem`, чия умова
  показу (`!= nil`) тепер прямо кероує видимістю UI-секції, а не лише menu-bar крапкою.
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — pure-core/thin-shell розділення;
  показ статус-секції за ⌥ — рішення AppKit-шару (`optionHeld` живе в `PopupViewController`, не в
  `PopupLayout`), модель `StatusHealth` не змінена.
