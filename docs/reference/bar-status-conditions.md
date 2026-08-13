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
індексом рядка `index <= 1` ([PopupViewController.swift:1618](../../Sources/TokenPace/PopupViewController.swift#L1618)).
Per-model і credits проходять гілкою `Palette.gapGreen`
([PopupViewController.swift:607, 619](../../Sources/TokenPace/PopupViewController.swift#L607)).
Menu bar per-model барів не має взагалі.

**Чому в idle «ні», хоч пігулка буває синя.** Idle-бар не має пейсингу як такого — він не проходить
через `severity` і не може набути `farBehind`. Його синій — це заливка стану «ready to start», яка
**теж** гейтиться станом тижня, але окремим шляхом. Детально — §6.

> **Журнал і UI збігаються.** `PacingBucket.of` читає те саме `blueAllowed`, що й рендер, а
> per-model рядки несуть той самий weekly-gate, тож у `usage-journal-*.jsonl` scoped-вікно більше
> не може отримати `sev: "blue"`, якого користувач не бачив.

---

## 2. Спільний кістяк: чотири переформулювання одного предикату

| # | Місце | Що дає | Рядок |
|---|---|---|---|
| 1 | `BarLayout.severity` | `PacingSeverity` (Kit) | [PacingModel.swift:265](../../Sources/TokenPaceKit/PacingModel.swift#L265) |
| 2 | `PacingBucket.of` | бакет для jsonl | [PacingBucket.swift:49](../../Sources/TokenPaceKit/PacingBucket.swift#L49) |
| 3 | `aheadColor` / `behindColor` | `NSColor` зазору | [PopupViewController.swift:645, 665](../../Sources/TokenPace/PopupViewController.swift#L645) |
| 4 | `isFarBehind` | слово «far behind pace» | [PopupViewController.swift:2592](../../Sources/TokenPace/PopupViewController.swift#L2592) |

`StatusItemView.gapColorTarget` ([:1043](../../Sources/TokenPace/StatusItemView.swift#L1043)) —
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
точна рівність іде **вліво**, у спокій ([PacingModel.swift:266](../../Sources/TokenPaceKit/PacingModel.swift#L266)).

**Пастка 2 — 20-хвилинні override'и НЕ симетричні за досяжністю.** Обидва лежать після виходу зі
спокійної гілки, тож при `u <= t` кінець-override (рядок 5) **недосяжний**. Стан «97 % спожито,
97 % часу минуло, 9 хвилин до ресету» лишається **зеленим**, не помаранчевим.

**Пастка 3 — `severity` зливає зелений і жовтий.** Обидва — `.calm` (рядки 3 і 6). Розділяє їх лише
колірний шар і `PacingBucket`. Тому «бар `.calm`» ≠ «бар зелений».

**Пастка 4 — вичерпання на спокійному боці не дає `.exhausted`.** Щойно скинуте 100 %-вікно може
читатися як `u <= t` і піти гілкою 1-3 — тобто `severity` буде `.calm`. `PacingBucket.of` це
**виправляє окремо** (`if usageFraction >= 1 { return .red }` на спокійному боці,
[PacingBucket.swift:60](../../Sources/TokenPaceKit/PacingBucket.swift#L60)), а `severity` — ні.
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
власного немає ([UsageSnapshot.swift:591](../../Sources/TokenPaceKit/UsageSnapshot.swift#L591)).

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
([PopupViewController.swift:2569](../../Sources/TokenPace/PopupViewController.swift#L2569)); вони
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
| Часова зона | локальна | **UTC** (жорстко) |
| Вікно | 5h / 7d | місяць; у `BarLayout` підставляється 7d як плейсхолдер |
| Синій | так (базові) | **ніколи** (`blueAllowed: false`) |
| Бар існує? | завжди | **лише коли є cap** |

**Бар відсутній, якщо немає ліміту.** `barLayout(for:now:)` повертає `nil`, коли `spentFraction`
не визначена (немає cap / необмежено / нульовий ліміт) — попап тоді показує лише витрачену суму
без бару й кольору ([CreditsPacing.swift:194](../../Sources/TokenPaceKit/CreditsPacing.swift#L194)).

**При досягненні cap `u` форсується в рівно 1**, щоб червоний спрацював попри округлення:
`spend.spendLimitReached ? 1 : min(1, max(0, rawUsage))`.

**20-хвилинний кінець-override працює й тут** — кінець місяця може бути ближче ніж за 20 хв; якщо
календар не зміг обчислити межу, підставляється довжина 7d, тож діє лише динамічний поріг.

Переходи: рядки 4-7 таблиці §3 (червоний / помаранчевий / жовтий), спокійний бік — **завжди
зелений**.

---

## 6. Idle-бар (немає активної 5h-сесії)

`sessionIdle` виникає, коли сервер не віддає 5-годинного вікна — тоді `resetsAt: ""`, а вікно
**не синтезується** ([UsageSnapshot.swift:439](../../Sources/TokenPaceKit/UsageSnapshot.swift#L439)).

Це **окремий код-шлях**: idle-бар не проходить через `barLayout`/`severity` взагалі. Його
`BarLayout` — інертний плейсхолдер (`u = 0, t = 0, windowDurationSeconds = 0`), який рендер ігнорує
([PopupLayout.swift:542](../../Sources/TokenPaceKit/PopupLayout.swift#L542),
[MenuBarLayout.swift:348](../../Sources/TokenPaceKit/MenuBarLayout.swift#L348)).

Пігулка **тризначна**:

| Умова | Заливка | Слово |
|---|---|---|
| `sessionIdle` **і** `CreditsPacing.isBlocked` | **сіра** | «waiting for limit reset» |
| `sessionIdle`, не blocked, **і** `weeklyHeadroom` | **синя** | «ready to start» |
| `sessionIdle`, не blocked, **без** headroom | **зелена** | «ready to start» |

- `isBlocked` = `mainWindowExhausted && !creditsCanCover`
  ([CreditsPacing.swift:150](../../Sources/TokenPaceKit/CreditsPacing.swift#L150)) — сірий лише коли
  головне вікно вичерпане **на 100 %** *і* кредити не покривають: працювати неможливо.
- `weeklyHeadroom` — той самий `PacingModel.weeklyHasHeadroom`, що гейтить пейсинговий синій.
  Синя пігулка обіцяє вільну квоту, і ця обіцянка хибна, щойно тиждень пішов попереду темпу.
- **Слово не змінюється** між синьою й зеленою: працювати справді можна, різниця лише в тому, чи є
  що «розганяти». Раніше текст обіцяв «ready to start, full quota available» — цю частину прибрано.

Прапорець їде окремим полем (`LimitRow.weeklyHeadroom` / `BarView.weeklyHeadroom`), бо idle-бар не
читає `blueAllowed` зі свого інертного `BarLayout`.

**Поверх цього — `CalmColorMode`** (лише menu bar, §7): синя пігулка лишається синьою під
`.yellowGreen`, зелена глушиться в обох режимах, сіра не глушиться ніколи
([#343](https://github.com/artem-from-ua/cc-timer/issues/343)).

> **Один синій, одна роль.** Раніше idle-заливка (`ColorRole.blue`) і пейсинговий зазор
> (`ColorRole.paceBlue`) були двома записами палітри з **однаковим** дефолтом `.systemBlue` — на
> екрані нерозрізненні, а розділені лише тим, що тюнер міг їх розвести. Ролі злито в одну `.blue`.

**Узгодженість із «Back to work!».** Зелена пігулка може співіснувати з нотіфікацією, і це не
суперечність: `WorkAvailability.canWork` питає «чи можливо працювати» (вичерпання), а gate — «чи є
запас» (темп). Тиждень, що скинувся зі 100 % до 85 % на початку вікна, дає і нотіфікацію, і зелену
пігулку: «працювати можна, тільки без розгону».

**Геометрія, не колір.** [ADR-0078](../adr/0078-idle-drawn-as-zero-in-both-styles.md) «idle малюється
як нуль» стосується **форми** — суцільна knobless-пігулка на нулі, без зон і без маркера часу.
Колір при цьому синій, а не нейтральний. Плутати ці два твердження — типова помилка.

---

## 7. Модифікатори поверх обчисленого кольору

Колір із §3-6 — це **вхід**, а не фінальний піксель.

### `CalmColorMode` — приглушення в біле (лише menu bar)

| Режим | Зелений/жовтий | Синій | Помаранчевий/червоний |
|---|---|---|---|
| `.off` | кольорові | кольоровий | кольорові |
| `.yellowGreen` | **білі** | кольоровий | кольорові |
| `.yellowGreenBlue` | **білі** | **білий** | кольорові |

Попередження ніколи не глушаться. Попап не глушить нічого.

**Idle-пігулка (§6) підпадає під ту саму таблицю** ([#343](https://github.com/artem-from-ua/cc-timer/issues/343)):
синя «ready to start» лишається синьою під `.yellowGreen` — це той самий `ColorRole.blue`, що й
пейсинговий зазор, тож глушити один і лишати інший суперечило б назві сегмента. **Зелена** пігулка
(тиждень без запасу) глушиться в обох режимах: зелений — саме те, що ці режими глушать за
означенням. Сіра (blocked) не глушиться ніколи — вона й так трек.

Рішення живе в `CalmColorMode.mutesIdlePill(isBlue:)`
([CalmColorMode.swift](../../Sources/TokenPaceKit/CalmColorMode.swift)), а не в `severity`: idle-бар
має жорстко `.calm` і `blueAllowed: false`, тож `.farBehind` там недосяжний.

### Journal vs UI

`PacingBucket` ігнорує **лише** `CalmColorMode` — це косметика, і серія має лишатися порівнюваною
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
| Idle-бар із маркером часу | idle малює нуль без маркера й зон |
| Idle-бар із заливкою на всю ширину | idle — це пігулка на нулі |
| **Біла idle-пігулка під `Yellow + Green` при спокійному тижні** | синя пігулка має той самий виняток, що й пейсинговий синій ([#343](https://github.com/artem-from-ua/cc-timer/issues/343)) — білою вона стає лише під `+ Blue` або коли тиждень без запасу (тоді вона зелена) |
| Жовтий на спокійному боці | жовтий існує лише при `u > t` |
| Синій на 5h при `t < 0.40` | `t − u ≤ t`, тож запас не досягне порога |
| **Синій h5 при d7 ∈ {yellow, orange, red}** | weekly-gate закритий → `blueAllowed == false` |
| **Синя idle-пігулка при гарячому тижні** | той самий gate → зелена заливка |
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

Далі: якщо бар не базовий (`isBaseLimit == false`) — синій замінюється зеленим. Якщо menu bar і
`CalmColorMode` глушить цей тон — колір стає білим.

---

## 10. Стуби для перевірки живцем

| Сценарій | Що показує |
|---|---|
| `far-behind` | обидва базові бари сині (5h запас ~0.55, 7d ~0.61) |
| `both-orange` / `both-red` | ahead-бік і вичерпання |
| `calm-both` | обидва зелені |
| `near-reset` | 20-хв кінець-override (2 пп ліду → помаранчевий) |
| `bar-extremes` | 5h синій (75 пп запасу) + 7d позаду темпу (щоб gate лишався відкритим) |
| `idle` | синя idle-пігулка (тиждень спокійний), «ready to start» |
| `idle-week-hot` | **зелена** idle-пігулка (тиждень попереду темпу), те саме слово |
| `idle-blocked` | сіра idle-пігулка, «waiting for limit reset» |
| `weekly-gate` | 5h глибоко позаду, але тиждень вичерпаний → 5h **зелений**, не синій |
| `credits-*` | money-бар у різних станах, зокрема без cap |
| `color-cycle` | прогін усіх бакетів по черзі |

Запуск: `TOKENPACE_DEVTOOLS=1 TOKENPACE_STUB=<id> swift run`.
Повний перелік — [ui-verification.md](../guides/ui-verification.md).
