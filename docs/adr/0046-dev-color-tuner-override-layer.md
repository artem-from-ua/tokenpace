---
status: superseded
date: 2026-07-30
superseded_by: [0106]
---

# ADR-0046: Централізований `ColorStore` override-шар для dev color-tuner

> Витіснено [ADR-0106](0106-remove-dev-color-tuner-and-dissolve-colorstore.md): тюнер і `ColorStore`
> видалені, обидві `Palette` читають `ColorRole.defaultColor` напряму. Чинним лишається сам
> **каталог ролей** — але як палітра застосунку, а не як реєстр для UI інструмента; розділення
> menu-bar / popup із «Уточнення D2» теж живе далі, на власних підставах.

## Контекст

Кольори інтерфейсу TokenPace жили у **двох незалежних приватних `enum Palette`**: menu-bar
(`StatusItemView.Palette`, фіксований sRGB — non-template image) і popup (`PopupBarView.Palette`,
appearance-aware `NSColor(name:dynamicProvider:)`), плюс кілька окремих семантичних кольорів
(`claudeBrandColor`, `dimmedLabelColor`). Кожен колір — `static let`-літерал, читаний прямо в місцях
малювання. Ahead-of-pace градація (yellow/orange/red) вже була single-source у `PopupBarView.aheadColor`
(її крос-файлово реюзає й menu-bar).

Підбір кольору означав цикл «правка літерала → `swift build` → дивись → знову»: жодного способу
побачити наживо, як зміна впливає на menu-bar іконку та popup. Потрібен був dev-інструмент (#185) —
вікно з дропдауном ролей + **вбудований inline-пікер** (RGB/HSB-повзунки + 16-бітні поля), що
перемальовує обидві поверхні негайно.

Питання: як дати такому інструменту **перевизначати** будь-який колір у рантаймі, не зачепивши
звичайних користувачів і не роздувши hot draw-path.

## Розглянуті варіанти

1. **`#if DEBUG`-гейт.** Компілятор викидає код у release. Але: фіча має працювати й на нотаризованому
   /release-білді (мейнтейнер підбирає кольори на реальному встановленому застосунку), а `#if DEBUG`
   це унеможливлює.
2. **Мінімальний override-dict у кожному `Palette`.** Найменше рефактору, але дублює логіку у двох
   місцях і не дає єдиного каталогу ролей для UI (назви/групи/описи/трансформації).
3. **Централізований `ColorStore` + `ColorRole`-каталог (обране).** Один enum усіх ролей і один
   store, через який обидва `Palette` читають кожен колір.

## Рішення

**Ввести `ColorRole` (плоский каталог ролей) і `ColorStore` (`@MainActor` singleton), через який
обидва `Palette` читають кожен колір.** Кожен `static let X = <literal>` став `static var X: NSColor
{ ColorStore.shared.color(.x) }`; дефолти перенесені 1:1 у `ColorRole.defaultColor`
(appearance-aware провайдери лишилися на боці `PopupBarView`/`PopupViewController` як `default*`
статики, щоб per-appearance логіка не дублювалась). Трансформації (`lightened`, alpha, calm-swap)
лишилися на місцях — вони обгортають значення зі store.

**Гейт — env-var `TOKENPACE_DEVTOOLS`, а не тип білда.** Коли він порожній, `ColorStore.color(role)`
завжди повертає default і словник override взагалі не читається — нульовий вплив на draw-path і
неможливість випадково змінити колір. Незалежно від dev/notarized/release. Той самий прапорець гейтить
і пункт меню «Development tools…» (плюс ⌥ Option), і сам override.

Override-и **ephemeral**: тримаються в памʼяті, не персистяться; вихід повертає всі дефолти. Зміна
кольору смикає `onChange` → `AppDelegate.reRenderForCurrentTime()`, що ре-снапшотить menu-bar і
перебудовує popup за один прохід (той самий шлях, що вже використовує toggle «Calm colors»).

## Уточнення D2: розділення menu-bar / popup pacing

Спершу ahead-of-pace кольори (yellow/orange/red) були single-source у `PopupBarView.aheadColor`, і
menu-bar тягнув їх крос-файлово. Для тюнера це означало, що один повзунок керує обома поверхнями —
джерело плутанини («де окремий menu-bar червоний?»). **Рішення:** розділити — додати окремі
`menuGapRed/Yellow/Orange` і параметризувати `aheadColor` за `PacingSurface { popup, menuBar }`.
Menu-bar-виклики передають `.menuBar` (і додатково лайтенять ~10%), popup — `.popup`. Дефолти
menu-констант стартують з тих самих значень, що popup (щоб вигляд не змінився), далі тюняться
незалежно. Каталог також розширено до ~35 ролей — додано popup service-доти (окремі appearance-aware
`.system*`, на відміну від fixed-sRGB menu-дотів), popup warning red, «in use» pill, link, label.

## Наслідки

- **+** Живий підбір будь-якого з ~20 кольорів без перезбірки; єдиний каталог ролей із назвами,
  групами, вичерпним описом використання й позначкою трансформацій — джерело підписів у tuner.
- **+** Кольори тепер мають один шар доступу; якщо колись знадобиться тема/персистентність — місце вже є.
- **−** Кожен `Palette`-колір — тепер computed `var` (виклик `ColorStore.color`) замість `static let`:
  дешевий Bool-чек + словниковий lookup лише коли dev-tools увімкнено, інакше Bool-чек + default.
- **−** `enum Palette` довелося позначити `@MainActor` (store — `@MainActor`); draw-код і так на main.
- Правило: змінюючи `Palette`-колір, оновлюй `ColorRole.defaultColor` у тому ж коміті (мають збігатись).
