---
status: accepted
date: 2026-07-25
superseded_by: [0040]
---

# ADR-0035: Вікно Settings — sidebar-навігація та grouped-inset картки

> **Частково переглянуто [ADR-0040](0040-native-system-metrics-no-hardcoded-ui.md) (#156):** проходом
> паритету з System Settings уточнено *реалізацію* карток і метрик — ручний `controlBackgroundColor`
> fill (давав чисто-білу картку) замінено на dynamic grouped-колір (242/43 light/dark), додано material/
> виміряні row-height/corner-radius, sidebar-іконки за системним розміром, `NSStackView.firstBaseline`-
> вирівнювання, `NSPathControl` для шляху. Загальна структура (sidebar + grouped-inset картки, eager-
> build, `AppDelegate`-контракт) лишається чинною; тіло цього ADR історичне.

## Контекст

Вікно Settings (issue #14, ADR-0012) від початку було одним пласким вертикальним `NSStackView` у
`NSScrollView`: секції розділені bold-заголовками та `NSBox`-роздільниками, усі контроли — чекбокси
лівого краю. За кілька релізів воно обросло опціями (#89 monitored services, #103 reset countdown,
#105 calm colors, #110 session logs, #114 pause-on-lock, #37 updates) і перетворилося на довгий
скрол із шести секцій.

Дві проблеми:

1. **Не масштабується.** Кожна нова опція подовжує єдиний скрол; орієнтуватися в ньому дедалі важче,
   а попереду ще опції (#130 тощо).
2. **Не виглядає нативно.** Сучасний macOS System Settings (Ventura+) використовує sidebar-навігацію
   та grouped-inset картки, а не пласкі секції з горизонтальними лініями.

Мейнтейнер попросив редизайн під гайдлайни System Settings із sidebar-пікером секцій (бо кількість
опцій зростатиме) та нативним оформленням груп.

## Рішення

Переписати вікно як **`NSSplitViewController`**: sidebar-список секцій зліва + детальна панель
grouped-inset карток справа.

1. **Sidebar** (`SettingsSidebarController`, source-list `NSTableView`) — 5 пунктів із кольоровими
   SF-Symbol-чипами: **General**, **Menu Bar**, **Monitored Services**, **Session Logs**, **About**.
   Дрібні секції згорнуто: колишні **Updates** злиті в **About**. Пункти масштабуються під ріст
   опцій там, де один скрол не масштабувався.

2. **Grouped-inset картки** (`SettingsCard`) — AppKit не має нативного заокругленого контейнера, що
   збігається з Sequoia, тож картка — layer-backed `NSView`: заливка `controlBackgroundColor` на
   `windowBackgroundColor`-тлі вікна, `cornerRadius` 10 pt, inset-hairline-роздільники (`DividerView`,
   `separatorColor`, висота `1/backingScaleFactor`) між рядками. Оскільки `CGColor` **не** динамічний,
   заливка й роздільники перевстановлюються у `updateLayer()` (з `wantsUpdateLayer`), який AppKit
   кличе на кожній зміні appearance — так dark/light лишається коректним.

3. **NSSwitch замість чекбоксів.** Контроли-перемикачі стали `NSSwitch` на правому краї рядка (як у
   System Settings). Radio лишаються radio (ексклюзивний вибір, не toggle). Оскільки `NSSwitch` не
   має title/subtitle, усі хінти та сірий «always monitored»-маркер — окремі лейбли в рядку.

4. **Панелі будуються eager, не лениво.** `updateAvailability(_:)` та `updateArchiveStatus()`
   викликаються з фонових завершень опитувань, поки вікно закрите; ленива панель дала б nil-outlet.
   `SettingsSplitViewController.buildAllPanes()` матеріалізує всі 5 панелей одразу в `init`.

**Збережено дослівно** публічний контракт, на який зав'язаний `AppDelegate.openSettings`: 8
`on…Change`/provider-callback-ів + `updateAvailability(_:)` + `updateArchiveStatus()` + `show()`.
Уся логіка sync-on-show, умовні enablement (WEB/Desktop mode radios ↔ switch; «include distant 7d» ↔
smart-radio; archive-кнопки ↔ enabled+folder), ексклюзивна reset-countdown-група (4 режими ↔ 3 radio
+ 1 nested checkbox) та жива `SMAppService`-логіка launch-at-login (з collapse-on-empty хінтом,
`isAppBundle`-гейтом, rollback на невдачі) перенесені без зміни поведінки. Жоден лог-меседж не
змінився.

Вікно лишається single-instance (`isReleasedWhenClosed = false`), `.floating`-рівня (спливає з
menu-bar-app без Dock-іконки, ADR-0012 §6), тепер resizable з `setFrameAutosaveName`; центрується один
раз при першому показі, якщо autosave не відновив позицію.

### Альтернативи, які відкинули

- **Верхні вкладки (toolbar tabs)** — валідний до-Ventura стиль, але мейнтейнер обрав sidebar саме
  через кращу масштабованість під ріст опцій.
- **Grouped-inset без навігації** (один скрол карток) — не розв'язує проблему масштабу.
- **NSBox `.custom` для картки** — його заокруглення legacy-механізм і не збігається з Sequoia; радіус
  усе одно підганяти вручну, тож простіше layer-backed `NSView`.

## Наслідки

- Вікно виглядає як панель System Settings; додати нову секцію = додати один `Section`-дескриптор
  (title + SF-Symbol + tint + builder), без подовження скролу.
- Три нові типи в shell: `SettingsCard`/`DividerView`/`FlippedView` (`SettingsCard.swift`),
  `SettingsSplitViewController`, `SettingsSidebarController`. `SettingsWindowController` тепер хостить
  split-VC замість плаского стека.
- `SettingsRow` централізує row-білдери (switch-рядок, button-рядок, label+hint, link), тож нові
  рядки узгоджені за padding і поведінкою.
- Corner radius (10 pt) та divider inset (~14 pt) — не документовані Apple, підігнані на око; можуть
  потребувати корекції на майбутніх macOS.
- Це UI-редизайн без зміни моделі даних: `PersistedConfig`-ключі, тести Kit (593, усі зелені) та
  логування недоторкані. ADR-0012 лишається історичним записом (окреме вікно, opt-out, best-effort на
  unsigned — усе чинне); змінилося лише **оформлення** вікна, тож формального superseded не додаємо —
  цей ADR доповнює 0012 по осі layout.
