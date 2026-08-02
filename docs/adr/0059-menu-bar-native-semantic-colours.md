---
status: accepted
date: 2026-08-02
---

# ADR-0059: Menu-bar widget — native semantic colours, not statusline-fixed sRGB

> This ADR supersedes the colour clauses of [ADR-0005](0005-pacing-fractions-not-blocks.md),
> [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) §5–§9,
> [ADR-0022](0022-popup-bar-transparency-and-contrast-experiment.md) (menu-bar clause),
> [ADR-0027](0027-session-idle-no-phantom-reset.md) D7 (menu-bar blue), and reverses the
> [ADR-0040](0040-native-system-metrics-no-hardcoded-ui.md) §3 exception. It **extends**
> [ADR-0046](0046-dev-color-tuner-override-layer.md) (ColorStore/ColorRole) rather than replacing it.
> The bright-tone alpha (a single 0.865) is derived from live eyedropper measurement; the maintainer
> confirmed the on-bar render.

## Контекст

Menu-bar-віджет (`StatusItemView`) історично малював **фіксованим sRGB** — точною xterm-256 палітрою
statusline (ADR-0005/0009): used `#303030`, gap-green `#5faf5f`, gap-red `#d75f5f`, idle `#005f5f`
тощо. Обґрунтування (ADR-0009 §9, ADR-0040 §3): образ — **non-template `NSImage`**, а `NSColor.labelColor`
всередині off-screen образу нібито резолвиться в неправильний RGB (темний текст на темному барі), тож
семантичні кольори «не працюють» і потрібен хардкод. statusline був референсом, щоб бар збігався з
терміналом one-to-one.

Ця модель має три вади, які проявилися на живому барі:
1. **Не «дихає».** Нативні menu-bar-іконки (місяць, Wi-Fi, батарея) підхоплюють відтінок шпалери крізь
   vibrancy-матеріал і фліпають світло/темінь разом із баром. Наш фіксований сірий лишався тим самим на
   будь-якій шпалері — помітно «мертвий» поряд із системними сусідами.
2. **statusline більше не референс.** Прив'язка до xterm-палітри була початковою ідеєю; продукт від неї
   відійшов. Тримати колір бару рабом термінальної теми — довільне обмеження.
3. **Хибна передумова.** «`labelColor` дає неправильний RGB в off-screen образі» — артефакт того, що
   образ малювався в **неправильному appearance** (лінивий `drawingHandler` резолвив кольори пізніше,
   під vibrant-матеріалом, де alpha `labelColor` падає 0.847→0.698). При **eager**-малюванні в
   `button.effectiveAppearance` `labelColor` резолвиться коректно й фліпає сам.

Завдання (переформульоване з мейнтейнером): щоб моно-частини бару виглядали й поводились як нативні
системні іконки — фліпали, дихали шпалерою, дімились системним способом — і несли кольорові акценти
так, як батарея несе свій жовтий/червоний. Тільки системні модифікатори (semantic-кольори), без
фіксованого sRGB, без ручної detection теми, без statusline-парити.

## Розглянуті варіанти

1. **Фіксований sRGB / `lightened` (статус-кво).** Не дихає — емпірично відкинуто.
2. **Справжня template-vibrancy.** `isTemplate = true` споживає лише альфа-маску й **інвертує** на
   темному барі (малює світлим контентним кольором → майже білий), не несе кольорових акцентів.
   `wantsLayer`+CALayer-overlay для кольору **ламає** vibrancy (Apple Forums thread/776799). Жодна
   реальна menu-bar-апка так не робить — недосяжно для нашої кольорової геометрії.
3. **Калібрація під шпалеру (піпетка + повзунки brightness/saturation).** Ручна компенсація
   «дихання». Пророблено й **відкинуто**: `labelColor@fixed-alpha` дихає САМ (див. Рішення), тож
   повзунки/семпл фону виявились зайвими.
4. **Custom-draw semantic (обране).** Єдиний non-template образ, `labelColor`-родина + `.system*`,
   резолвлені eager проти реального бару. Так роблять усі реальні menu-bar-апки (Stats/iStat/AlDente).

## Рішення

**Малювати бар одним non-template `NSImage`, всі кольори — системні semantic, резолвлені eager у
appearance реального бару. Ніякого фіксованого sRGB, ніякого statusline, ніякого ручного гілкування за
темою в рендері.**

**1. Рендер — eager проти `button.effectiveAppearance`.** `snapshotImage()` малює через
`image.lockFocusFlipped(true)` **всередині** `button.effectiveAppearance.performAsCurrentDrawingAppearance`
(у `AppDelegate.refreshStatusImage`), НЕ лінивий `NSImage(size:flipped:drawingHandler:)`. Лінивий
handler резолвив би dynamic-кольори пізніше, під vibrant-матеріалом (де alpha `labelColor` падає). Eager
запікає кожен semantic-колір проти **справжнього** appearance бару, що його виставив caller. Ре-снапшот
на фліп теми — через наявну KVO на `button.effectiveAppearance` (штатний шлях для non-template).
`button.effectiveAppearance` — **єдине** правильне джерело світлості бару (детектує бар від шпалери
навіть у системному Dark); `view/NSApp.effectiveAppearance` віддають системну тему, не бар.

**2. Track (доріжка/основа) = `labelColor.withAlphaComponent(0.22)`.** Напівпрозорий силует: фон бару
(шпалера крізь vibrancy) просвічує на 78%, тож track і приглушується ЯК МІСЯЦЬ, і ДИХАЄ відтінком фону.
`labelColor` фліпає сам (білий/чорний). Модель `ink@0.22 over bg` підтверджена піпеткою на teal/синьому/
білому барах (наш `3f7070` vs місяць `407373`; `445465` vs `455667`; `0xBF` vs `0xC1`). Роль
`menuUnusedGrey` у `ColorRole.defaultColor`.

**3. Bright-тони (reset-текст, ⚠️, tick) = `labelColor` at fixed alpha.** `bright(_:)` бере `labelColor`,
резолвить його RGB у sRGB і підставляє **одну** фіксовану alpha **0.865**. Піпеткою light-бар хотів ~0.85
(`1e2423` = система), dark-бар ~0.88 (`≈0xE6` vs `0xE7`), але **оком різниця між ними невидима**, тож одне
середнє значення обслуговує обидві теми — без перемикача, без гілкування. `labelColor` фліпає КОЛІР сам;
alpha лише вирівнює непрозорість під vibrant-матеріалом (де власна alpha `labelColor` падає 0.847→0.698).

**4. Кольорові акценти = `.system*`.** Pacing gap/marker, service-dot, idle → `.systemGreen/Yellow/
Orange/Red/Blue` через наявний `accent()` (масштаб `accentSaturation`, за замовчуванням 1.0). Вони
навмисно **непрозорі** й не тінтяться шпалерою — як жовтий батареї лишається жовтим на будь-якому фоні;
лише фліпають light/dark-варіант і несуть Increase-Contrast.

**5. Ніякого перемикача теми, калібрації, повзунків, семплу фону.** `labelColor` фліпає світло/темінь
сам, track@0.22 дихає фізично (напівпрозорість), а bright-alpha невідчутна між темами — тож жодного
ручного контролю яскравості не потрібно. Розглядався перемикач «Wallpaper brightness» (Auto/Light/Dark)
для розведеної alpha 0.85/0.88, але **відкинутий**: різниця невидима оком, тож він додавав налаштування
без користі. Скинуто разом із мертвим кодом: `monoBrightness`, `calibrationColor`, `monoTintFraction`,
env-overrides `TOKENPACE_MONO_BRIGHTNESS/ACCENT_SATURATION/CALIB_HEX`.

**6. dimmed → НЕ додаємо.** У бару немає dimmed-стану: втрату зв'язку показуємо content-swap на ⚠️
(інформативніше за приглушення, яке ховало б сигнал). `appearsDisabled` не застосовуємо.

**Відношення до ADR-0046.** Це рішення **розширює** ColorStore/ColorRole: ролі лишаються, змінюються
лише їхні `defaultColor` для menu-bar (fixed sRGB → semantic). Tuner і override-шар працюють як раніше.

## Наслідки

- **+** Моно-частини дихають шпалерою й фліпають тему автоматично, як нативні іконки; акценти несуть
  системні light/dark + Increase-Contrast варіанти безкоштовно.
- **+** Прибрано хардкод sRGB, statusline-парити, ручну калібрацію й супутній мертвий код.
- **−** Це custom-draw **апроксимація**, не справжня template-vibrancy (недосяжна — див. варіант 2): моно
  дихає бо напівпрозоре, не бо система тінтить наш образ. На **насичених кольорових** барах track копіює
  яскравість/дихання місяця, але не його недокументований **синій tint** (система тінтить приглушені
  іконки в холодний бік) — відкладено на етап тюнінгу кольорів.
- **−** Bright-alpha — одне середнє (0.865) для обох тем; на кожній окремій темі «ідеал» був би на
  ±0.015 інший, але різниця невидима оком, тож компроміс без наслідків для вигляду.
- Правило (ADR-0046): змінюючи menu-`Palette`-колір, оновлюй `ColorRole.defaultColor` у тому ж коміті.

## Пов'язане

- [ADR-0005](0005-pacing-fractions-not-blocks.md) — частки [0,1] лишаються; колірна прив'язка
  (PacingState→RGB, xterm) superseded.
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — тонкий shell/pure layout лишається;
  §5–§9 (non-template fixed sRGB, statusline-палітра, «labelColor дає неправильний RGB») superseded.
- [ADR-0022](0022-popup-bar-transparency-and-contrast-experiment.md) — popup-прозорість недоторкана;
  клауза «menu-bar лишається fixed statusline» superseded.
- [ADR-0027](0027-session-idle-no-phantom-reset.md) — idle-логіка лишається; D7 menu-bar fixed blue →
  `.systemBlue`.
- [ADR-0040](0040-native-system-metrics-no-hardcoded-ui.md) — §3 виняток «StatusItemView fixed sRGB»
  скасовано (тепер бар підпорядковано правилу §1 «нуль хардкоду»).
- [ADR-0046](0046-dev-color-tuner-override-layer.md) — ColorStore/ColorRole, який це рішення розширює.
