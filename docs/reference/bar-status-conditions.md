# Умови переходу барів у статуси

Вичерпний довідник: **за яких саме умов кожен тип бару набуває кожного статусу/кольору**.

Для чого: `severity`, колір зазору, колір маркера й журнальний бакет — це **чотири різні
переформулювання** одного предикату, розкидані по Kit і AppKit. Розійтися вони можуть тихо. Цей
документ зводить усі гілки в одне місце, з посиланням на рядок коду для кожної.

> **Джерела істини, а не переказ.** Кожне твердження тут має supporting-рядок. Якщо код і документ
> розійшлися — правий код, а документ треба виправити тим самим PR.

Пов'язані документи: [ui-state-truth.md](ui-state-truth.md) (анатомія й метрики бару),
[menu-bar-signals.md](menu-bar-signals.md) (обернена задача — як читати те, що вже на екрані:
спершу «чи є число», і лише потім смужки),
[users-and-goals.md](users-and-goals.md) (навіщо статус узагалі існує),
[ADR-0061](../adr/0061-far-behind-blue-pacing-zone.md) (синя зона),
[ADR-0044](../adr/0044-dynamic-pacing-threshold.md) (динамічний ahead-поріг),
[ADR-0078](../adr/0078-idle-drawn-as-zero-in-both-styles.md) (idle як нуль).

---

## 1. Типи барів і що їм узагалі доступно

Не всі бари можуть набути всіх статусів. Це найчастіше джерело хибних мокапів.

Колонка «Пейсинговий синій» — про `farBehind`-зону, тобто про **статус**, а не про будь-який синій
піксель (усе синє в застосунку тепер бере одну роль `ColorRole.blue`).

| Тип бару | Джерело | Вікно | Пейсинговий синій? | Де малюється |
|---|---|---|---|---|
| **h5** — 5-годинний | `snapshot.fiveHour` | 18 000 c | **так** | menu bar + попап |
| **d7** — 7-денний | `snapshot.sevenDay` | 604 800 c | **так** | menu bar + попап |
| **Opus / Sonnet** | `snapshot.sevenDayOpus/Sonnet` | 7d-paced | **ні** | лише попап |
| **scoped per-model** | `snapshot.scopedModelWindows` | 7d-paced | **ні** | лише попап |
| **credits (money)** | `snapshot.spend` | календарний місяць, UTC | **ні** | лише попап |
| **idle-h5** | плейсхолдер | немає | **ні** — пейсингу не має | menu bar + попап |

**Чому синій лише для h5/d7.** Рендер гейтить його прапорцем `isBaseLimit`, який ставиться за
індексом рядка `index <= 1` ([PopupViewController.swift:1618](../../Sources/TokenPace/PopupViewController.swift)).
Per-model і credits проходять гілкою `Palette.gapGreen`
([PopupViewController.swift:607, 619](../../Sources/TokenPace/PopupViewController.swift)).
Menu bar per-model барів не має взагалі.

**Чому в idle «ні».** Idle-бар не має пейсингу як такого — він не проходить через `severity` і не
може набути `farBehind`. Його заливка — це стан «ready to start», а не вердикт: із
[#381](https://github.com/artem-from-ua/cc-timer/issues/381) вона **завжди зелена** (сіра при
blocked), і тижневий gate до неї більше не входить. Детально — §6.

> **Журнал і UI збігаються.** `PacingBucket.of` читає те саме `blueAllowed`, що й рендер, а
> per-model рядки несуть той самий weekly-gate, тож у `usage-journal-*.jsonl` scoped-вікно більше
> не може отримати `sev: "blue"`, якого користувач не бачив.

---

## 2. Спільний кістяк: чотири переформулювання одного предикату

| # | Місце | Що дає | Рядок |
|---|---|---|---|
| 1 | `BarLayout.severity` | `PacingSeverity` (Kit) | [PacingModel.swift:265](../../Sources/TokenPaceKit/PacingModel.swift) |
| 2 | `PacingBucket.of` | бакет для jsonl | [PacingBucket.swift:49](../../Sources/TokenPaceKit/PacingBucket.swift) |
| 3 | `aheadColor` / `behindColor` | `NSColor` зазору | [PopupViewController.swift:645, 665](../../Sources/TokenPace/PopupViewController.swift) |
| 4 | `isFarBehind` | слово «far behind pace» | [PopupViewController.swift:2592](../../Sources/TokenPace/PopupViewController.swift) |

`StatusItemView.gapColorTarget` ([:1043](../../Sources/TokenPace/StatusItemView.swift)) —
не п'яте переформулювання: він читає `severity` й делегує в `behindColor`.

### Константи

| Константа | Значення | Що робить |
|---|---|---|
| `pacingOrangeOverrideSeconds` | 1200 c (20 хв) | кінець вікна → будь-яке випередження помаранчеве |
| `pacingBlueStartOverrideSeconds` | 1200 c (20 хв) | старт вікна → синій не блимає |
| `aheadThreshold(timeFraction:)` | `0.16 × (1 − t)` | межа жовтий→помаранчевий, **динамічна** |
| `behindThreshold(...)` | 5h: 0.40, 7d: ≈0.2857 | межа зелений→синій, **фіксована в реальному часі** |
| `farBehindWidthMultiplier` | 2 | множник базової ширини, **константа** (не налаштування) |
| `blueAllowed` | Bool | чи взагалі дозволений синій для цього бару |

`behindThreshold` = `blueBehindWidthSeconds × 2 / windowDurationSeconds`, де база — 60 хв (5h) і
24 год (7d). Раніше множник задавав користувач (`FarBehindInterval`); тепер він фіксований, а
питання «чи малювати синій» повністю переїхало в `blueAllowed`
([PacingModel.swift](../../Sources/TokenPaceKit/PacingModel.swift)).

### `blueAllowed` — weekly-capacity gate

`blueAllowed` ставиться при побудові бару й відповідає на питання «чи має цей бар право радити
розганятися»:

| Бар | `blueAllowed` |
|---|---|
| d7 | `true` завжди — сам себе не гейтить |
| h5, Opus/Sonnet/scoped | `PacingModel.weeklyHasHeadroom(in:now:)` |
| credits, idle-плейсхолдери | `false` — пейсингу не мають |

`weeklyHasHeadroom` = `d7.pacing == .onPaceOrBehind && d7.usageFraction < 1`, тобто d7-бакет ∈
{blue, green}. **Closed by default:** якщо `resets_at` тижня не парситься, повертає `false` — інакше
fallback `?? now` дав би `timeFraction = 1.0` і хибно **відкрив** би gate.

---

## 3. Базові бари h5 / d7 — повна таблиця переходів

Позначення: `u` = `usageFraction` (`utilization/100`, кліп `[0,1]`), `t` = `timeFraction`
(частка вікна, що минула), `elapsed` = `windowDurationSeconds − remainingSeconds`.

Гілки перевіряються **згори вниз, перша істинна виграє**.

| # | Умова | Severity | Колір | Бакет |
|---|---|---|---|---|
| 0 | `u <= t` **і** `!blueAllowed` | `.calm` | зелений | `green` |
| 1 | `u <= t` **і** `elapsed <= 1200` | `.calm` | зелений | `green` |
| 2 | `u <= t`, `blueAllowed` **і** `(t − u) > behindThreshold` | `.farBehind` | **синій** | `blue` |
| 3 | `u <= t` (решта) | `.calm` | зелений | `green` |
| 4 | `u > t` **і** `u >= 1` | `.exhausted` | червоний | `red` |
| 5 | `u > t` **і** `remainingSeconds <= 1200` | `.ahead` | помаранчевий | `orange` |
| 6 | `u > t` **і** `(u − t) < 0.16×(1−t)` | `.calm` | жовтий | `yellow` |
| 7 | `u > t` (решта) | `.ahead` | помаранчевий | `orange` |

Гілка 0 — weekly-gate (або інертний бар); вона **передує** start-override. На відміну від
скасованого `FarBehindInterval.off`, це не налаштування, а факт про дані, тож **журнал її теж
поважає** — саме тому в колонці «Бакет» стоїть `green`, а не пропуск.

### Чотири пастки в цій таблиці

**Пастка 1 — рівність `u == t` спокійна.** Гілка `pacing == .onPaceOrBehind` тестує `t >= u`, тож
точна рівність іде **вліво**, у спокій ([PacingModel.swift:266](../../Sources/TokenPaceKit/PacingModel.swift)).

**Пастка 2 — 20-хвилинні override'и НЕ симетричні за досяжністю.** Обидва лежать після виходу зі
спокійної гілки, тож при `u <= t` кінець-override (рядок 5) **недосяжний**. Стан «97 % спожито,
97 % часу минуло, 9 хвилин до ресету» лишається **зеленим**, не помаранчевим.

**Пастка 3 — `severity` зливає зелений і жовтий.** Обидва — `.calm` (рядки 3 і 6). Розділяє їх лише
колірний шар і `PacingBucket`. Тому «бар `.calm`» ≠ «бар зелений».

**Пастка 4 — вичерпання на спокійному боці не дає `.exhausted`.** Щойно скинуте 100 %-вікно може
читатися як `u <= t` і піти гілкою 1-3 — тобто `severity` буде `.calm`. `PacingBucket.of` це
**виправляє окремо** (`if usageFraction >= 1 { return .red }` на спокійному боці,
[PacingBucket.swift:60](../../Sources/TokenPaceKit/PacingBucket.swift)), а `severity` — ні.
Це розбіжність №2 між UI і журналом.

### Числові приклади порогів

| Вікно | `t` | `aheadThreshold` | Жовтий, поки лід < | Синій, коли запас > |
|---|---|---|---|---|
| 5h | 10 % | 0.144 | 14.4 пп | 40 пп |
| 5h | 50 % | 0.080 | 8.0 пп | 40 пп |
| 5h | 90 % | 0.016 | 1.6 пп | 40 пп (недосяжно: `t−u ≤ 0.9`) |
| 7d | 30 % | 0.112 | 11.2 пп | 28.6 пп |
| 7d | 80 % | 0.032 | 3.2 пп | 28.6 пп |

Ahead-поріг **звужується** з часом (лід наприкінці вікна небезпечніший — вікно скинеться раніше,
ніж встигнеш повернутися на темп), behind-поріг **не рухається** (це фіксований проміжок реального
часу: «відстаю більше ніж на 2 години» однаково значуще на початку й наприкінці).

---

## 4. Per-model бари (Opus / Sonnet / scoped)

Пейсяться **як 7-денні** — беруть `LimitWindow.sevenDay` і позичають `seven_day.resets_at`, коли
власного немає ([UsageSnapshot.swift:591](../../Sources/TokenPaceKit/UsageSnapshot.swift)).

Таблиця з §3 діє **з одним винятком**: рядок 2 (синій) недосяжний у UI — замість нього завжди
зелений, бо `isBaseLimit == false`.

| # | Умова | Колір у попапі |
|---|---|---|
| 1-3 | `u <= t` (будь-який запас) | **зелений завжди** |
| 4 | `u >= 1` | червоний |
| 5 | `remainingSeconds <= 1200` | помаранчевий |
| 6 | лід < `0.16×(1−t)` | жовтий |
| 7 | решта | помаранчевий |

Слово «far behind pace» їм теж недоступне — `isFarBehind` гейтиться тим самим прапорцем
([PopupViewController.swift:2569](../../Sources/TokenPace/PopupViewController.swift)); вони
показують «on pace».

**У журналі так само.** Вони несуть `blueAllowed = weeklyHasHeadroom`, тож `sev` для них ніколи не
`blue` — раніше журнал міг записати синій, якого користувач не бачив.

---

## 5. Credits (money) бар

Найбільше відхилень від токенних барів.

| Аспект | Токенні бари | Credits |
|---|---|---|
| `u` | `utilization / 100` | `used / limit` |
| `t` | частка вікна | частка **календарного місяця** |
| Часова зона | локальна | **UTC** (жорстко) — і для `t`, і для підписів країв місяця |
| Вікно | 5h / 7d | місяць; у `BarLayout` підставляється 7d як плейсхолдер |
| Синій | так (базові) | **ніколи** (`blueAllowed: false`) |
| Бар існує? | завжди | **лише коли є cap** |
| Стиль подачі | за `dropdownStyle` (Pressure / Balance / Progress) | **завжди Progress**; `BarStyle` ігнорується ([ADR-0092](../adr/0092-extra-usage-own-ruler.md)) |
| Тіки | набір за стилем (частки вікна / 20 % / 0.5) | **жодного**; натомість два підписи країв місяця (`Jan 1` / `Jan 31`) |

**Підписи країв — теж UTC, і це видимий користувачеві текст.** На межі місяця вони можуть на кілька
годин розійтися з локальним календарем (до ~11 год на схід від UTC, ~8 год на захід) — на відміну від
`resetLine` у тому ж рядку, який рендериться **локально**. Компроміс свідомий: момент ресету це точка
на осі часу, спільна для всіх, а мітка місяця — властивість календаря самого вікна, тож підпис мусить
називати той місяць, який міряє геометрія бару ([ADR-0092](../adr/0092-extra-usage-own-ruler.md)).

**Бар відсутній, якщо немає ліміту.** `barLayout(for:now:)` повертає `nil`, коли `spentFraction`
не визначена (немає cap / необмежено / нульовий ліміт) — попап тоді показує лише витрачену суму
без бару й кольору ([CreditsPacing.swift:194](../../Sources/TokenPaceKit/CreditsPacing.swift)).

**При досягненні cap `u` форсується в рівно 1**, щоб червоний спрацював попри округлення:
`spend.spendLimitReached ? 1 : min(1, max(0, rawUsage))`.

**20-хвилинний кінець-override працює й тут** — кінець місяця може бути ближче ніж за 20 хв; якщо
календар не зміг обчислити межу, підставляється довжина 7d, тож діє лише динамічний поріг.

Переходи: рядки 4-7 таблиці §3 (червоний / помаранчевий / жовтий), спокійний бік — **завжди
зелений**.

---

## 6. Idle-бар (немає активної 5h-сесії)

`sessionIdle` виникає, коли сервер не віддає 5-годинного вікна — тоді `resetsAt: ""`, а вікно
**не синтезується** ([UsageSnapshot.swift:439](../../Sources/TokenPaceKit/UsageSnapshot.swift)).

Це **окремий код-шлях**: idle-бар не проходить через `barLayout`/`severity` взагалі. Його
`BarLayout` — інертний плейсхолдер (`u = 0, t = 0, windowDurationSeconds = 0`), який рендер ігнорує
([PopupLayout.swift:542](../../Sources/TokenPaceKit/PopupLayout.swift),
[MenuBarLayout.swift:348](../../Sources/TokenPaceKit/MenuBarLayout.swift)).

Пігулка **двозначна** (з [#381](https://github.com/artem-from-ua/cc-timer/issues/381) — до того була
тризначною):

| Умова | Заливка | Слово |
|---|---|---|
| `sessionIdle` **і** `CreditsPacing.isBlocked` | **сіра** | «waiting for limit reset» |
| `sessionIdle`, не blocked | **зелена** | «ready to start» |

- `isBlocked` = `mainWindowExhausted && !creditsCanCover`
  ([CreditsPacing.swift:150](../../Sources/TokenPaceKit/CreditsPacing.swift)) — сірий лише коли
  головне вікно вичерпане **на 100 %** *і* кредити не покривають: працювати неможливо.
- **Синьої idle-пігулки більше немає на жодній поверхні**
  ([ADR-0105](../adr/0105-color-advice-governs-pacing-bars-only.md)). До
  [#381](https://github.com/artem-from-ua/cc-timer/issues/381) вона була синьою при тижневому запасі
  й зеленою без нього — і саме її синій колір розходився з тим, що синій означає на **активному**
  барі. Тепер обидва рендери цілять у зелений безумовно:
  [PopupViewController.swift:432](../../Sources/TokenPace/PopupViewController.swift)
  (`blocked ? monochromeGrey : color(.green)`) і
  [StatusItemView.swift:995](../../Sources/TokenPace/StatusItemView.swift).
- Разом із кольором пішов і прапорець: полів `LimitRow.weeklyHeadroom` / `BarView.weeklyHeadroom`
  **немає** — idle-бару більше нема чого питати про тиждень.
- `PacingModel.weeklyHasHeadroom` лишається й далі гейтить `blueAllowed` для **активних** барів
  ([ADR-0081](../adr/0081-weekly-capacity-gate-for-blue.md) у цій частині чинний) — просто idle до
  нього більше не входить.
- **Слово не змінюється** між зеленою й (колишньою) синьою: працювати справді можна. Раніше текст
  обіцяв «ready to start, full quota available» — цю частину прибрано.

**Поверх цього — [`ColorAdvice`](../../Sources/TokenPaceKit/ColorAdvice.swift)** (лише menu bar, §7):
зелена пігулка глушиться в білий під обома глушильними режимами (і **безумовно** під Pressure), сіра
не глушиться ніколи.

> **Один синій, одна роль.** Раніше idle-заливка (`ColorRole.blue`) і пейсинговий зазор
> (`ColorRole.paceBlue`) були двома записами палітри з **однаковим** дефолтом `.systemBlue` — на
> екрані нерозрізненні, а розділені лише тим, що тюнер міг їх розвести (сам тюнер прибрано —
> [ADR-0106](../adr/0106-remove-dev-color-tuner-and-dissolve-colorstore.md)). Ролі злито в одну `.blue`,
> а з [#381](https://github.com/artem-from-ua/cc-timer/issues/381) idle не читає її взагалі —
> `.blue` лишився суто пейсинговим.

**Узгодженість із «Back to work!».** Зелена пігулка може співіснувати з нотіфікацією, і це не
суперечність: `WorkAvailability.subscriptionAvailable` питає «чи доступна квота» (вичерпання —
[ADR-0113](../adr/0113-back-to-work-tracks-the-subscription-quota.md)), а gate — «чи є запас» (темп). Тиждень, що скинувся зі 100 % до 85 % на початку вікна, дає і нотіфікацію, і зелену
пігулку: «працювати можна, тільки без розгону».

**Геометрія, не колір.** [ADR-0078](../adr/0078-idle-drawn-as-zero-in-both-styles.md) «idle малюється
як нуль» стосується **форми** — суцільна knobless-пігулка на нулі, без зон і без маркера часу.
Колір при цьому синій, а не нейтральний. Плутати ці два твердження — типова помилка.

---

## 7. Модифікатори поверх обчисленого кольору

Колір із §3-6 — це **вхід**, а не фінальний піксель.

### `ColorAdvice` — приглушення в біле (лише menu bar)

Тип названо за **порадою, яку несе колір**, а не за механізмом гасіння
([ColorAdvice.swift](../../Sources/TokenPaceKit/ColorAdvice.swift), перейменований із `CalmColorMode`
у [#381](https://github.com/artem-from-ua/cc-timer/issues/381) —
[ADR-0104](../adr/0104-appearance-named-for-behaviour-on-three-layers.md)). Рядок у Settings → Appearance ›
Menu bar зветься **«Colors tell me»**, сегменти — нижче в першій колонці; старі raw
(`yellowGreenBlue`/`yellowGreen`/`off`) читаються через `legacyRawValues`.

| Режим (сегмент) | Зелений/жовтий | Синій | Помаранчевий/червоний |
|---|---|---|---|
| `.slowDown` (`Slow down`) | **білі** | **білий** | кольорові |
| `.slowDownOrSpeedUp` (`Slow down or speed up`, дефолт) | **білі** | кольоровий | кольорові |
| `.howItsGoing` (`How it's going`) | кольорові | кольоровий | кольорові |

Попередження ніколи не глушаться. Попап не глушить нічого. Рендер читає не сам кейс, а два derived-
прапорці — `mutesCalm` і `mutesBlue`.

**Під Pressure гасіння безумовне.** У menu bar при `menuBarStyle == .pressure` увесь спокійний бік
(синій/зелений/жовтий) і idle-пігулка глушаться в білий **незалежно від `ColorAdvice`**
([StatusItemView.swift:995](../../Sources/TokenPace/StatusItemView.swift) — `barStyle ==
.pressure || colorsTell.mutesCalm`). Саме тому рядок «Colors tell me» під Pressure **стає неактивним і
показує `Slow down`**: під цим стилем кольоровим лишається рівно помаранчевий «витрачаєш зашвидко», а
це і є той сегмент. Контрол звітує про стан замість пропонувати вибір, який нічого не змінить;
збережене значення не переписується й повертається на Balance чи Progress.

**Ці три поверхні більше не читають `ColorAdvice` взагалі**
([ADR-0105](../adr/0105-color-advice-governs-pacing-bars-only.md),
[#381](https://github.com/artem-from-ua/cc-timer/issues/381)), бо відповідають на інші питання:

- **Service-крапка**: її шкала (сірий → жовтий → помаранчевий → червоний) самодостатня, і від
  [#410](https://github.com/artem-from-ua/tokenpace/issues/410) однакова на всіх трьох поверхнях —
  menu bar, попап, Legend ([ADR-0111](../adr/0111-degraded-dot-is-yellow-on-every-surface.md)).
  Змінився **тон** `degraded`, а не те, хто його вирішує: налаштування крапка не читала й не читає.
- **Символ валюти (¤)**: його власна шкала біла→помаранчева→червона самодостатня
  ([ADR-0068](../adr/0068-credits-in-use-marker-anatomy.md)).
- **Idle-пігулка** (§6): гаситься за спільним `idleMuted`, тим самим, що й решта спокійного боку.

### Journal vs UI

`PacingBucket` ігнорує **лише** `ColorAdvice` — це косметика, і серія має лишатися порівнюваною
між користувачами. `blueAllowed` він, навпаки, **поважає**: це не налаштування, а факт про дані
([PacingBucket.swift](../../Sources/TokenPaceKit/PacingBucket.swift)).

Ширина синьої зони більше не налаштовується: колишній `FarBehindInterval` (×1/×2/×3/off) прибрано,
множник фіксований на ×2.

---

## 8. Неможливі комбінації

Стани, яких код **не може** видати. Рендер із них робить хибним увесь розбір навколо.

| Комбінація | Чому неможлива |
|---|---|
| Синій per-model / credits рядок | `isBaseLimit == false` → завжди `gapGreen` |
| Синій у перші 20 хв вікна | start-override, гілка 1 |
| Помаранчевий при `u <= t` | кінець-override недосяжний на спокійному боці |
| Синій бар зі словом «far behind» на Opus | `isFarBehind` гейтиться `isBaseLimit` |
| Credits-бар при `limit == nil` | `barLayout` повертає `nil` — бару немає |
| Credits-бар у Pressure чи Balance | Завжди шкала вікна, незалежно від `dropdownStyle` ([ADR-0092](../adr/0092-extra-usage-own-ruler.md)) |
| Credits-бар із тіками | Його лінійка — два підписи країв місяця, зубців немає (0092); та й самі підписи видно **лише під ⌥** ([ADR-0098](../adr/0098-ruler-split-identify-always-explain-on-option.md)) — без нього бар стоїть без лінійки взагалі |
| Idle-бар із маркером часу | idle малює нуль без маркера й зон |
| Idle-бар із заливкою на всю ширину | idle — це пігулка на нулі |
| **Синя idle-пігулка** — за будь-яких налаштувань і будь-якого стану тижня | З [#381](https://github.com/artem-from-ua/cc-timer/issues/381) синього idle немає на жодній поверхні: заливка або зелена, або біла (під гасінням), або сіра (blocked). Виняток `Yellow + Green` для idle, що діяв за [#343](https://github.com/artem-from-ua/cc-timer/issues/343), зник разом із синім |
| **Кольорова idle-пігулка під Pressure у menu bar** | Під Pressure гасіння безумовне (`barStyle == .pressure \|\| colorsTell.mutesCalm`), тож зелена пігулка там **завжди** біла — незалежно від `ColorAdvice`, який під цим стилем навіть не показується в Settings |
| **Біла (нейтральна) service-крапка в menu bar — у будь-якому стані** | Від [#410](https://github.com/artem-from-ua/tokenpace/issues/410) ([ADR-0111](../adr/0111-degraded-dot-is-yellow-on-every-surface.md)) `statusDotTarget` не має жодного винятку: усі шість станів беруть свій тон зі шкали (`degraded` — жовтий, як у попапі й на Legend). Гілки `calmWhite` там більше немає, тож нейтральна крапка не малюється ніде |
| Жовтий на спокійному боці | жовтий існує лише при `u > t` |
| Синій на 5h при `t < 0.40` | `t − u ≤ t`, тож запас не досягне порога |
| **Синій h5 при d7 ∈ {yellow, orange, red}** | weekly-gate закритий → `blueAllowed == false` |
| **Idle-пігулка, що змінює колір за станом тижня** | Тижневий gate більше не входить у idle: полів `LimitRow.weeklyHeadroom` / `BarView.weeklyHeadroom` немає, тож `idle` і `idle-week-hot` малюють однакову **зелену** пігулку |
| `sev: "blue"` у журналі, якого не було на екрані | журнал читає те саме `blueAllowed` |

---

## 9. Як перевірити стан арифметично

Перш ніж стверджувати «бар буде такого кольору», порахуй:

```
u = utilization / 100
t = elapsed / windowDuration          # частка вікна, що минула
elapsed = windowDuration - remainingSeconds

if u <= t:
    if not blueAllowed:                     -> ЗЕЛЕНИЙ (weekly gate / інертний бар)
    elif elapsed <= 1200:                   -> ЗЕЛЕНИЙ (start-override)
    elif (t - u) > behindThreshold:         -> СИНІЙ (лише h5/d7)
    else:                                   -> ЗЕЛЕНИЙ
else:
    if u >= 1:                              -> ЧЕРВОНИЙ
    elif remainingSeconds <= 1200:          -> ПОМАРАНЧЕВИЙ (end-override)
    elif (u - t) < 0.16 * (1 - t):          -> ЖОВТИЙ
    else:                                   -> ПОМАРАНЧЕВИЙ
```

Далі: якщо бар не базовий (`isBaseLimit == false`) — синій замінюється зеленим. Якщо menu bar і цей
тон глушиться — колір стає білим; глушить його `ColorAdvice` (§7) **або**, безумовно, стиль
Pressure.

---

## 10. Стуби для перевірки живцем

| Сценарій | Що показує |
|---|---|
| `far-behind` | обидва базові бари сині (5h запас ~0.55, 7d ~0.61) |
| `both-orange` / `both-red` | ahead-бік і вичерпання |
| `calm-both` | обидва зелені |
| `near-reset` | 20-хв кінець-override (2 пп ліду → помаранчевий) |
| `bar-extremes` | 5h синій (75 пп запасу) + 7d позаду темпу (щоб gate лишався відкритим) |
| `idle` | **зелена** idle-пігулка, «ready to start» (до [#381](https://github.com/artem-from-ua/cc-timer/issues/381) була синя) |
| `idle-week-hot` | тиждень попереду темпу — і пігулка **та сама зелена**. Стан лишився стубом навмисно: він доводить, що idle **не** реагує на тиждень; розбіжність із `idle` була б регресією |
| `idle-blocked` | сіра idle-пігулка, «waiting for limit reset» |
| `weekly-gate` | 5h глибоко позаду, але тиждень вичерпаний → 5h **зелений**, не синій |
| `credits-*` | money-бар у різних станах, зокрема без cap |
| `credits-month-end` | той самий money-бар на **90 % місяця** — найтісніше місце його лінійки: маркер часу підходить до правого підпису (`Jan 31`) найближче |
| `color-cycle` | прогін усіх бакетів по черзі |

Запуск: `TOKENPACE_STUB=<id> swift run`.
Повний перелік — [ui-verification.md](../guides/ui-verification.md).
