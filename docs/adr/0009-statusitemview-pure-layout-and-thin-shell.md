---
status: superseded
date: 2026-06-22
superseded_by: [0015]
---

# ADR-0009: StatusItemView — чиста MenuBarLayout + тонкий AppKit-shell

> **Частково superseded [ADR-0015](0015-no-idle-mode.md):** рішення §2 (поріг idle 5 %) і §4
> (idle-гліф `*`) скасовано — компактного/idle-режиму більше немає. Решта цього ADR (розкол
> pure/shell, `MenuBarMode` як відкритий enum, малювання смужок, monochrome ⚠️) лишається чинною.

## Контекст

Issue #10 («StatusItemView — смужки + idle») вводить перший видимий UI: кастомне малювання menu
bar (дві pacing-смужки + час до ресету) з компактним idle-режимом. На відміну від попередніх
модулів (`PacingModel`, `ResetClock`, `TokenProvider`, `UsageClient`), тут уперше з'являється
залежність від AppKit, яка під SPM без повного Xcode **не покривається unit-тестами**.

Постають три рішення про межі модуля — той самий клас, що в
[ADR-0005](0005-pacing-fractions-not-blocks.md),
[ADR-0007](0007-token-provider-throws-and-scope-split.md),
[ADR-0008](0008-usageclient-pure-backoff-and-transport-seam.md):

1. **Де живе обчислення «що малювати».** Якщо вся логіка (idle-vs-expanded, які смужки, який час)
   сидить усередині `NSView`, вона некована тестами й заплутана з малюванням.
2. **Який поріг idle і де його зафіксувати.** SPEC дає лише орієнтир («обидва ліміти < ~5% і нема
   pacing-попередження»), точне число — на реалізацію.
3. **Як показати повністю кастомну кольорову графіку в `NSStatusItem`** так, щоб система не
   перефарбовувала кольори під Dark/Light tinting.

## Рішення

1. **Розкол pure-core + thin-shell — `MenuBarLayout` (у `CCTimerKit`) окремо від `StatusItemView`
   (у `cc-timer`).** `MenuBarLayout.make(from:now:)` — чиста, детермінована (інжектований `now`)
   функція `UsageSnapshot → MenuBarMode`, що **не додає нової арифметики**: переюзує
   `PacingModel.barLayout`/`limitIndicator` (геометрія смужок + severity) і `ResetClock.resetDisplay`
   (найближчий ресет + формат). Єдине власне рішення — idle-vs-expanded. Це дзеркалить `BarLayout`
   (ADR-0005) і `PollingBackoff` (ADR-0008): уся обчислювана логіка виду — у бібліотеці, юніт-тестована;
   `StatusItemView` лишається тонким `NSView`, що лише малює готову модель. Дані виду тестуються в
   `MenuBarLayoutTests` без AppKit; саме малювання перевіряється вручну (`swift run` / `.app`).

2. **Поріг idle — `5.0 %`, строге `<`.** `idle` ⇔ обидва вікна `utilization < 5`. Половина «нема
   pacing-попередження» зі SPEC **автоматична**: обидва алерти `LimitIndicator` вимагають
   `utilization > 90` (`.warning`) або `== 100` (`.critical`) — значно вище 5 %, тож будь-яке
   попереджене вікно вже не-idle. Окремої умови на warning немає (це була б мертва гілка). Межа
   строга (`<`), як `OAuthCredentials.isExpired`'s `<=` та `PacingModel`'s `> 90` — рівно 5 % уже
   expanded.

3. **`MenuBarMode` лишається відкритим enum.** Дві гілки в #10 (`idle`, `expanded`); стани помилок
   (`⚠️` / застарілі дані) — окрема гілка в #12, тож enum не перевантажується зараз.

4. **Idle-гліф — жирний моноширинний `*`.** SPEC просить «малу іконку без повних смужок»; обрано
   простий, читабельний за обох тем гліф. Колір (`NSColor.labelColor`) **не** адаптується
   автоматично у non-template `NSImage` — резолвиться в appearance menu bar вручну, див. пункт 9.

5. **Показ через готовий non-template `NSImage` (`button.image`), а не subview.** Вкладання
   кастомного `NSView` як subview кнопки `NSStatusItem` ненадійне (системна кнопка володіє своїм
   лейаутом і малює поверх доданих subview). Надійний шлях для повністю кастомної графіки — віддати
   кнопці готове зображення, відрендерене жадібно (`lockFocusFlipped`). `image.isTemplate = false`
   зупиняє перефарбовування pacing-кольорів під Dark/Light tinting (SPEC «Технічні зауваги»).

6. **Кольори — точна `statusline` 256-color палітра (фіксований sRGB), не системні семантичні.**
   Зони мапляться 1:1 на xterm-256 RGB кодів зі statusline (ADR-0005): used `dark_gray` 236 =
   `#303030`, gap-green `bright_green` 71 = `#5faf5f`, gap-red `bright_red` 167 = `#d75f5f`, future
   `dark_blue` 23 = `#005f5f` (фактично **темний teal**, не синій — мапа коду 23), додатково
   затемнений до `#004c4c`, щоб хвіст відступав як фон. Фіксований RGB, а не `systemGreen`/тощо:
   мета — щоб menu bar точно повторював вигляд термінального statusline в будь-якій темі; зображення
   non-template, тож macOS його не перефарбовує.

7. **Індикатор часу — кружечок у кольорі pacing із темною обводкою, не вертикальна риска.** Точка на
   позиції `timeFraction` забарвлюється за **сирим** відношенням use vs time (тонший поділ, ніж
   бінарний `PacingState`, де рівність складається в зелений): `usage < time` → green (відстаєш),
   `usage > time` → red (випереджаєш), `usage == time` → teal (`future`). Темне кільце (`#181818`)
   відділяє точку від будь-якої кольорової зони під нею.

8. **Перемальовування лише при зміні даних.** `StatusItemView.layout { didSet { … } }` оновлює
   зображення лише коли модель справді змінилась (`layout != oldValue`) — жодного таймера
   (architecture.md: енергоефективність). Polling-шар (#13) ставитиме `layout` після кожного
   опитування; у #10 `AppDelegate` ставить його раз із mock-снапшота.

9. **Семантичний колір тексту резолвиться в appearance menu bar вручну (виявлено й виправлено в
   #11).** Оскільки зображення non-template (пункт 5), macOS **не** перефарбовує його під тему menu
   bar — а `NSColor.labelColor` усередині off-screen `NSImage` резолвиться в RGB у *ambient*
   appearance (за замовчуванням Aqua), даючи темний текст на темному menu bar. Рішення:
   `snapshotImage(appearance:)` малює всередині `appearance.performAsCurrentDrawingAppearance { … }`,
   а `AppDelegate` передає `button.effectiveAppearance` і **перерендерює образ при зміні теми** (KVO
   на `effectiveAppearance` кнопки). Це стосується лише *тексту* (`labelColor` idle-гліфа й часу
   ресету) — фіксовані sRGB pacing-кольори (пункт 6) свідомо не залежать від теми. Відступи
   підтиснуто, щоб айтем не «роздувався» поряд із нативними: внутрішній горизонтальний відступ
   `hPadding = 2` (menu bar додає власний проміжок між айтемами), вертикальний зазор смужок
   `barGap = 4` (компактніший стек). Текст (idle-гліф, час ресету) лишається растеризованим у
   тому ж `NSImage`, що й смужки — після цих доробок він читається в одному масштабі з нативними
   айтемами (годинник/акумулятор), тож перехід на нативний `button.attributedTitle` визнано
   непотрібним (#26 закрито як вирішене цими змінами).

## Наслідки

- Уся логіка виду (idle-поріг, вибір смужок/часу) покрита unit-тестами (`MenuBarLayoutTests`:
  idle/expanded, межа 5 %, відповідність `PacingModel`/`ResetClock`, fallback `.resetNow`), не
  чекаючи на AppKit. `StatusItemView` несе лише малювання, що перевіряється оком.
- `CCTimerKit` лишається без AppKit — `MenuBarLayout`/`BarView`/`MenuBarMode` оперують лише
  семантикою (`PacingState`/`LimitIndicator`/`TimeToReset`); мапа в `NSColor` живе в `cc-timer`.
  Це зберігає бібліотеку реюзабельною для Фази 2 (iOS/watchOS, інший рендер).
- `AppLogger` отримує 4-ту категорію `ui` (переходи режиму idle↔expanded). Малювання не логується
  (високочастотне); секрети не торкаються цього шару.
- `MenuBarMode` готовий до розширення `.error` у #12 без зміни наявних гілок.
- Mock-снапшот у `AppDelegate` — тимчасовий; #13 замінює його живим `Keychain → UsageClient`-опитуванням,
  лишаючи `StatusItemView`/`MenuBarLayout` незмінними (вони вже приймають готовий `UsageSnapshot`).
- Якщо у Фазі 2 рендер піде через SwiftUI/інший фреймворк — `MenuBarLayout` переюзовується як є,
  а новий тонкий shell замінює `StatusItemView`; це нове рішення → нова секція тут або окремий ADR.
