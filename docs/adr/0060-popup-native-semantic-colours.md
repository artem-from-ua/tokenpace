---
status: draft
date: 2026-08-02
---

# ADR-0060: Уніфікована палітра — системні semantic-кольори, спільні для menu-bar і попапа (крім Claude-бренду)

> **Extends [ADR-0059](0059-menu-bar-native-semantic-colours.md)** на попап **і об'єднує колірні ролі
> обох поверхонь**. ADR-0059 переніс на системні semantic-кольори лише **menu-bar**, свідомо лишивши
> popup-палітру на фіксованих значеннях. Цей ADR (а) поширює ту саму філософію на попап і (б) **зливає
> дубльовані menu-vs-popup ролі в один плаский набір семантичних кольорів** — один колір на відтінок,
> спільний для pacing-барів і сервіс-крапок обох поверхонь.
> **Експериментальний статус (`draft`):** фіналізується (→ `accepted`) після підтвердження мейнтейнером
> на реальному попапі в обох темах.

## Контекст

Після ADR-0059 menu-bar малює виключно системними semantic-кольорами (`.system*`, `labelColor@alpha`),
а popup-палітра лишилась сумішшю: сервіс-крапки й on-pace зелений — уже `.system*`, але **ahead-of-pace
трійка** (`popupGapRed/Yellow/Orange`) і **сірі** (track, tick, indicator-ring) — числові sRGB-константи
або appearance-гілковані сирі greys у `PopupBarView`.

ADR-0022 §4.3 уже задумував popup pacing як «системні» (`.systemGreen/Red/Yellow/Orange`), але реалізація
жила через **числові sRGB-наближення** цих системних кольорів у `ColorRole.defaultColor` — hand-tuned
`#E12D23`/`#E6B419`/`#F8760F`. Наслідок: попап **не фліпав** light/dark-варіант і не ніс Increase-Contrast,
на відміну від menu-bar, який ті самі `.menuGap*` уже читає як `.systemRed/Yellow/Orange`. Так само track
попапа (`monochromeGrey`) був **непрозорим** сірим (ADR-0022 §4.2), тоді як menu-bar track перейшов на
напівпрозорий `labelColor@0.22`, що дихає матеріалом-підкладкою.

Питання (#217): чи довести popup-палітру до тієї самої нативної адаптивності, що й menu-bar — тобто
замінити числові наближення справжніми системними кольорами й подивитися вживу, як воно фліпає теми.

Додатковий висновок під час роботи: після переходу обидві поверхні дефолтяться на **ті самі** `.system*`
кольори, але `ColorRole` тримав **окремі** ролі для кожної (`menuGapRed` vs `popupGapRed`, `menuStatusYellow`
vs `popupServiceYellow` тощо) — ~40 ролей, де багато пар резолвляться в один колір. Це плутало (зміна
menu-ролі в тюнері не міняла попап і навпаки) без реальної користі. Тож рішення розширено до **повної
уніфікації**: один плаский набір семантичних ролей, спільний для обох поверхонь.

## Рішення

**Popup-палітра малює системними/semantic-кольорами, як menu-bar. Виняток — Claude-бренд.**

1. **Ahead-of-pace трійка → `.system*`.** `popupGapRed → .systemRed`, `popupGapYellow → .systemYellow`,
   `popupGapOrange → .systemOrange` у `ColorRole.defaultColor`. Це вирівнює попап із menu-bar (де
   `.menuGapRed/Yellow/Orange` вже системні) — обидві поверхні тепер беруть той самий системний відтінок,
   що фліпає теми й несе Increase-Contrast. Числові наближення `#E12D23`/`#E6B419`/`#F8760F` прибрано.
2. **Сірі → semantic.** Провайдери у `PopupBarView`:
   - `defaultIndicatorStroke` → `.separatorColor` (той самий hairline, що й menu-bar-ring
     `.menuIndicatorStroke`);
   - `defaultTick` → `.tertiaryLabelColor` (приглушений нейтрал, слабший за крапку);
   - `defaultMonochromeGrey` → `labelColor.withAlphaComponent(0.22)` — **той самий track-тон, що й
     menu-bar** (`.menuUnusedGrey`). Це **реверсить непрозорість** popup-бару з ADR-0022 §4.2: track
     стає напівпрозорим і композититься з NSMenu-матеріалом попапа (дихає ним), а не суцільним сірим.
3. **Claude-бренд лишається числовим.** `popupClaudeBrand` (`#D97757`) — фірмова терракота Claude;
   системного semantic-відповідника немає, тож він свідомо тримається як sRGB-константа.
4. **Мертвий код прибрано.** Після переходу сірих на semantic зникли єдині виклики `paletteGray(_:)` та
   `paletteDynamic(_:)` — обидва хелпери видалено.
5. **Preview-only chrome недоторканий.** `popupMenuMatchedBackground` (`#212121`) і `popupMenuBorder`
   (`#4D4D4D`/`#C4C4C4`) — це матеріал-матч і hairline **прев'ю** dev-тюнера, ніколи не малюються в
   живому UI (audit #206); лишаються фіксованими.
6. **Повна уніфікація ролей (~40 → 18).** Дубльовані menu-vs-popup ролі злиті в один плаский набір:
   - **6 семантичних відтінків** — `green/yellow/orange/red/blue/gray` — по одному на відтінок,
     спільні для pacing-гепів **і** сервіс-статус-крапок обох поверхонь (напр. `.systemGreen` тепер
     обслуговує menu on-pace, popup on-pace, credits-¤ і operational-крапку — одна роль `green`).
   - **Chrome:** `barTrack` (`labelColor@0.22`), `indicatorRing` (`separatorColor`), `tick`
     (`tertiaryLabelColor`), `inUsePill`.
   - **Текст/calm/бренд** лишаються (`foreground`, `label`, `link`, `dimmedLabel`, `pillText`,
     `calmWhite`, `idleCalmGrey`, `claudeBrand`).
   Обидва приватні `Palette`-акцесори тепер вказують на ту саму роль; тюнер показує кожен колір **раз**
   із нейтральною назвою. Override-шар ефемерний (у пам'яті), тож ренейм/видалення ролей нічого не
   осиротило.
7. **Desaturation idle-blue прибрано.** Провайдер `defaultIdleBlue` десатурував `.systemBlue` ~15% до
   сірого (+~22% до білого на світлій темі). Він **видалений** — popup idle тепер малює **чистим**
   `.systemBlue`, ідентично menu-bar. Це **навмисна візуальна зміна** (за рішенням мейнтейнера: «тільки
   без desaturated»): на світлій темі popup idle-бар стане насиченішим/важчим.
8. **Тривіальні провайдери інлайнено.** `defaultIndicatorStroke/Tick/MonochromeGrey` (однорядкові після
   уніфікації) інлайнено прямо в `ColorRole.defaultColor` і видалено; лишається лише `defaultDimmedLabel`
   (per-appearance blend). Разом із `defaultIdleBlue` та хелперами `paletteGray`/`paletteDynamic` це
   прибрало весь per-element колірний плумбінг попапа.

**Правило (ADR-0046/0059) дотримано:** зміна `Palette`-акцесорів і `ColorRole.defaultColor` — в одному
коміті.

## Наслідки

- **+** Popup-палітра фліпає light/dark і несе Increase-Contrast автоматично, як menu-bar і нативні
  іконки; попап і menu-bar тепер збігаються за pacing-відтінком (обидва `.system*`).
- **+** Прибрано числові sRGB-наближення й appearance-гілкування сирих greys + супутній мертвий код.
- **−** Системні `.systemRed/Yellow/Orange` відрізняються від hand-tuned тонів (`.systemYellow` зокрема
  може читатися блідішим/зеленкуватим за ручний амбер) — свідомий обмін ручного відтінку на нативну
  адаптацію; фіналізується живою перевіркою.
- **−** Track попапа стає напівпрозорим (реверс ADR-0022 §4.2): тепер залежить від alpha-compositing з
  NSMenu-матеріалом. Точну alpha (0.22) звірено з menu-bar, але на попапі вона може потребувати
  підкрутки; fallback — `.secondaryLabelColor` (непрозорий semantic).
- **+** Один плаский набір ролей замість ~40 дубльованих: тюнер показує кожен колір раз, а зміна
  відтінку застосовується до обох поверхонь одразу — узгоджено за визначенням.
- **−** Втрачено можливість тюнити menu vs popup (чи pacing vs status) **незалежно** — це і є ціль
  уніфікації, але хто покладався на роздільне тюнення, того більше немає. Оскільки override-шар
  ефемерний і ніколи не шипиться, на звичайний запуск це не впливає.
- **−** Popup idle-blue втрачає desaturation → стає чистим `.systemBlue` (єдина навмисна візуальна
  зміна; menu-bar idle був чистим і так). На світлій темі помітно насиченіший.
- **Експериментально:** решта злиттів — піксель-у-піксель (усі поглинуті ролі вже мали той самий
  `.system*` дефолт), тож єдиний реальний зсув вигляду — idle-blue; його й перевіряємо вживу.

## Пов'язане

- [ADR-0059](0059-menu-bar-native-semantic-colours.md) — menu-bar semantic-кольори; цей ADR поширює те
  саме рішення на попап.
- [ADR-0022](0022-popup-bar-transparency-and-contrast-experiment.md) — вигляд popup-барів; клауза про
  **непрозорий монохромний** track (§4.2) та числову реалізацію pacing-кольорів (§4.3) superseded цим
  ADR; рішення про суцільний фон дропдауна (`SolidBackdropView`) лишається чинним.
- [ADR-0046](0046-dev-color-tuner-override-layer.md) — ColorStore/ColorRole, який це рішення розширює;
  тюнер працює як раніше (але для *системних* кольорів «flattens» адаптацію — тому експеримент робиться
  редагуванням `defaultColor`, не тюнером).
