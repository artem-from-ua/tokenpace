# Верифікація UI перед PR

Детальний довідник для живої перевірки menu-bar / Settings змін перед PR: перелік стубів
(`TOKENPACE_STUB=…`), сценарії, що не мають стубу (screen-lock, авто-апдейт), і фічі, що потребують
підпису. Короткі правила — у [CLAUDE.md](../../CLAUDE.md) («Верифікація UI перед PR»); тут — конкретика.

> **Головне правило:** не відкривати PR, доки мейнтейнер не перевірив зміну **вживу** — на стубах
> та/або на реальній даті. Скриншоти з тимчасового dev-only коду за верифікацію **не рахуються**
> (див. нижче). Робочий цикл: коміт у feature-гілку → `swift build` → **віддати мейнтейнеру на
> перевірку** → дочекатися підтвердження → лише тоді PR.

> ⚠️ **Скриншот-автоматизація ненадійна: у menu bar кілька однойменних інстансів TokenPace** (реліз +
> dev-копії з різних сесій). AX/`osascript` не відрізняє їх, тож клік по menu-bar-item наослі́п відкриває
> не ту збірку; dropdown (NSMenu) не скриншотиться взагалі. **Не клікати menu-bar-item за іменем/індексом**
> — надійна UI-перевірка = мейнтейнер сам відкриває потрібну dev-іконку вживу. Повна методика (запуск,
> зупинка за власним PID, чому не broad-kill) — у [agent-workflow.md](agent-workflow.md) розділ «Запуск
> застосунку для перевірки UI».

> 📸 **Скриншот усього екрана — ТІЛЬКИ з явного дозволу мейнтейнера. Усі інші скриншоти — лише
> окремих вікон.** `screencapture` без обмеження області (`-x file.png`) захоплює весь desktop
> мейнтейнера (термінал, чати, приватні вікна) — заборонено без його прямого «так», незалежно від
> мети.
>
> Знімай **конкретне вікно за window-id** (`-l<windowID>`), ніколи не екран:
>
> ```sh
> # знайти CG window-id вікна TokenPace (popup — більше вікно під menu bar, layer 101):
> #   swift-однорядник через CGWindowListCopyWindowInfo, фільтр owner == "TokenPace"
> screencapture -o -l<windowID> popup.png   # захоплює саме це вікно
> ```
>
> - **Popup-дропдаун і вікно Settings** — справжні `NSWindow`: **відкрий дропдаун** і зніми його
>   вікно за window-id. Весь екран для цього НЕ потрібен.
> - **Menu-bar-віджет** знімають як **його власну область**, а не весь екран — `NSStatusItem` не має
>   window-id, тож захоплюй **вузьку рамку самого віджета** (`-R<x,y,w,h>` по його rect), не всю
>   верхню смугу й точно не весь desktop.

## Стуби `TOKENPACE_STUB`

Запуск: `TOKENPACE_STUB=<name> swift run`. Стуб підміняє транспорт usage- та status-запитів
(`StubUsageTransport` у `Sources/TokenPace/PollingShell.swift`). Джерело істини сценаріїв —
`StubScenario` (`Sources/TokenPace/StubScenario.swift`): `rawValue` кожного кейса = ім'я стуба з
таблиці нижче, `summary` — опис.

> **Живе перемикання без рестарту (#187, ADR-0047).** Коли dev-tools увімкнено
> (`defaults write com.artem-n.tokenpace devToolsEnabled -bool true` на **встановленому `.app`** — ADR-0053;
> у `swift run` ключ не діє, бо бінарник без bundle id → інший домен `UserDefaults`), відкрий
> ⌥ Option → меню → **Development tools…** і вибери сценарій у випадайці **Data source (stub)** угорі
> лівої колонки — джерело даних перемкнеться наживо (menu-bar іконка й popup оновляться протягом одного
> циклу полу), під випадайкою показано опис поточного сценарію. `TOKENPACE_STUB=…` при старті досі
> працює і **задає початковий вибір** випадайки; «Real network (no stub)» повертає застосунок на живий
> API. Для скриптингу авто-відкриття вікна лишається `TOKENPACE_OPEN_DEVTOOLS=1` (сам гейт dev-tools —
> вже `devToolsEnabled`, тож лише на `.app`).
> Послідовнісні стуби (`stale-error`, `reset-grace`, `optimistic-reset`, `just-unblocked`)
> відтворюються з полу №1 при повторному виборі (свіжий `StubUsageTransport` скидає лічильник полів).
>
> **Тег стуба біля Quit (#190).** Коли активний будь-який стуб, пункт **Quit TokenPace** під ⌥ Option
> показує назву сценарію — навіть у **підписаному `.app`** (де запускається реальна нотифікаційна
> збірка): `«Quit TokenPace (stub – credits-onset)»` на `.app`, `«… (dev build – credits-onset)»` на
> dev-бінарнику. Тег оновлюється й при живому перемиканні стуба. Чистий `.app` на реальній мережі — без
> тегу. Це найнадійніший спосіб на око підтвердити, який стуб реально працює.

| Стуб | Що показує |
|---|---|
| `1` | climbing — usage повзе вгору |
| `screenshot` | стабільний кадр для скриншотів: 5h **зелений** (10 % vs ≈65 % — well behind), 7d **жовтий** (36 % vs ≈29 % — mild ahead, під динамічним порогом `0.16·(1−time)`, навмисно не на amber/orange-межі, де сиділо старе 40 %), Fable **оранжевий** / Mythos **червоний** |
| `error` | auth-помилка (401) → ⚠️ (лише банер, без ліміт-рядків — cold-start) |
| `stale-error` | **stale-while-erroring** (баг відступу): перший полл валідний (повні бари: idle 5h «ready to start», 18 % 7d, Fable-рядок, «Extra usage» €11.68/€15.00), далі кожен полл — timeout → ⚠️ банер «Claude API connectivity issue» / «Authentication API timeout» **над** усіма барами. Перевіряй **горизонтальний відступ між текстом помилки і рядком «5-hour»** (той самий `sectionSpacing`, що після хедера) — без нього блок помилки злипався з «5-hour». API + Code — major outage (червоні крапки) |
| `idle` | «немає активної 5h-сесії» (#100): суцільний синій 5h-бар, без phantom-ресету, час падає на 7d-ресет («4d»). За default-ON «Hide 7-day bar when calm» (#94) 7d calm → **одинокий центрований idle-бар** |
| `idle-blocked` | **заблокований** idle (#158): idle 5h + 7d вичерпано (100 %) без credits. За default-OFF «Show pacing bars when 5h/7d limits reached» (#194, ADR-0049) меню-бар показує **лише countdown до ресету, без барів**; увімкни опцію → idle-бар **базовий сірий** (як стрічка пейсингу; у **обох** режимах Calm on/off). За default-ON «Show pause icon when fully blocked» (#199, ADR-0051) — **оранжевий pause** ліворуч (це `isBlocked`), **незалежно** від тумблера барів: перед баром, або перед countdown коли бари сховані; вимкни pause-опцію → гліф зникає, решта лишається. У попапі — завжди повна картина: статус «waiting for limit reset», 7d-ресет **червоний бейдж** (пігулка). Порівнюй з `idle`: там синій «ready to start», а під Calm — світло-сірий (не білий) |
| `active-blocked` | **активний** blocked (#177): жива 5h-сесія (48 %) при вичерпаному 7d (100 %, `weekly_all` critical) без credits → тижневий cap блокує попри квоту 5h. За default-OFF «Show pacing bars when 5h/7d limits reached» (#194) меню-бар показує **лише countdown, без барів** (main-вікно вичерпане); увімкни опцію → бари повертаються (5h-рядок звичайний «on pace»). За default-ON «Show pause icon when fully blocked» (#199) — **оранжевий pause** ліворуч (бо `isBlocked`: 7d вичерпано без credits), **незалежно** від того, показані бари чи лише countdown. У попапі — завжди повна картина: 7d-ресет отримує **червоний бейдж** «Effective blocker» |
| `optimistic-reset` | reset-boundary (#36): 5h ресетиться через ~20 с — бар стрибає 60 %→0 % без ⏰ + форс-рефреш |
| `reset-grace` | грейс на межі ресету (ADR-0041, ADR-0045): активне 5h-вікно (поли 0–1) → **порожнє** post-reset тіло (поли 2–3: `five_hour.resets_at:null`, без `session`-ліміту — декодер сам по собі дав би `sessionIdle`) → активне знову (поли 4+). У «дірі» 5h-рядок має показувати спокійний **0 % «on pace» з rolled-forward відліком** (`Nh at …`), а меню-бар **не блимати** — **ніколи «resetting…» чи зелений бар на всю ширину** (ADR-0045). Грейс озброюється лише коли запущений процес `claude` (`claudeActive`) — інакше показується чесний idle «ready to start» одразу. Порівнюй з `idle`: там idle **справжній** і має показатися |
| `broken-reset` | зламаний `resets_at` (#167, ADR-0043): «шумний» 5h (100 %) із **непарсабельним, але непорожнім** `resets_at` (`"not-a-date"`, НЕ `null` — `null`/порожній дав би чесний `sessionIdle`, а не помилку) → меню-бар показує **⚠️ замість пейсинг-барів** (як інша помилка API), а не фейкове `<1m`. 7d — calm із валідним ресетом (не джерело помилки) |
| `calm-degraded` | calm-бари + **degraded (жовта)** service-крапка: за вимкненого «Calm colours» (#105) крапка жовта; увімкни Calm (Settings → General) — крапка **біліє** разом із барами. Кадр для перевірки гасіння service-крапки |
| `just-unblocked` | «Back to work!» edge (#160): перший пол заблокований (7d=100 %, без кредитів), далі workable (7d=40 %) → нотифікація спрацьовує один раз. Див. окрему секцію нижче |
| `credits-onset` | «Now using Extra Usage Credit» edge: перший пол **не** на кредитах (7d=40 %, кредити enabled, але базовий ліміт не вичерпано → `isOnCredits=false`), далі 7d=100 % з тими самими enabled `spend`/`extra_usage` → робота переливається на платний кредит → нотифікація спрацьовує один раз (€10.77 / €15.00). Див. окрему секцію нижче |

### Іконка грошових кредитів (#144)

Трейлінг-іконка валюти (`coloncurrencysign` ¤) ліворуч від service-крапки. Усі три фрейми
фіксують 7d на 100 % (базовий ліміт вичерпано → тригер показу спрацьовує) і різняться блоком
`spend`. За замовчуванням гейт `showExtraUsage` увімкнений (default-ON), тож іконка видима одразу.
Перемикач у Settings — на #146.

| Стуб | Стан кредитів | Колір іконки |
|---|---|---|
| `credits-active` | enabled, ліміт €15.00, витрачено €10.77 (~72 %) | pacing usage-vs-time (зелена поза випередженням, бурштин/помаранч при випередженні) |
| `credits-limit-reached` | `spend_limit_reached` (ліміт €5.00 нижчий за €10.77) | **червона** (форсований usage = 1) |
| `credits-no-limit` | enabled, ліміт «unlimited» (`limit: null`) | **нейтральна** (foreground, без pacing) |

> Увімкни «Calm colours» (Settings → General) — calm-фрейми (`credits-active` у нормі,
> `credits-no-limit`) **біліють** разом із барами; `credits-limit-reached` (червона) лишається
> кольоровою.

### Секція «Extra usage» у дропдауні (#145)

Ті самі три стуби, але перевіряється **дропдаун** (клікни іконку в menu bar). Секція «Extra usage»
рендериться **під** лімітами 5h/7d/per-model. Показ у дропдауні за м'якшим гейтом, ніж іконка
(`CreditsPacing.isActive` — досить `enabled`/`spend_limit_reached`; вичерпаність базового ліміту НЕ
потрібна).

| Стуб | Що має бути в дропдауні |
|---|---|
| `credits-active` | Рядок «Extra usage ⟷ on pace / (well) ahead of pace» (залежно від дати місяця vs 72 %), рядок «€10.77 / €15.00 ⟷ `<reset line>`» — уніфікований формат до кінця календарного місяця в **місцевому** поясі (`15d` / `5d on Friday` / `20h at 03:00`, ADR-0043), і **бар** тим самим кольором, що іконка. **Плюс (#193/ADR-0048):** оскільки 7d вичерпано (100 %), а credits його покривають, рядок **7-day** несе **червоний бейдж** ресету (`5d`) — при цьому рядок НЕ сірий і статус звичайний (це не blocked) |
| `credits-limit-reached` | «Extra usage ⟷ limit reached», «€10.77 / €5.00 ⟷ `<reset line>`», **червоний** бар (usage форсовано в 1) |
| `credits-no-limit` | Лише «Extra usage ⟷ €10.77 spent» — **без** бару, **без** рядка ресету (unlimited, немає стелі) |

> Перевір, що суми — з валютою **€** (не `$`): форматер бере символ із коду валюти (EUR→€). Бар
> секції — той самий `PopupBarView`, що бари токенів, але **без** засічок-ticks (кредити пейсяться на
> весь місяць, без під-вікон).

### Тумблер «Show model & service limits» (#211)

Settings → Appearance → секція **Dropdown** → «Show model & service limits» (default-**on**). Гейтить
per-model/per-service рядки попапа (`Opus`/`Sonnet` із legacy-полів + `weekly_scoped`-записи як
`Fable`/`Mythos`).
Перевіряй на стубі з per-model лімітами — напр. `screenshot` (має Fable + Mythos):

```sh
TOKENPACE_STUB=screenshot TOKENPACE_DEVTOOLS=1 swift run
```

- **On** (дефолт): дропдаун показує рядки `Opus`/`Sonnet`/`Fable`/`Mythos` під `5-hour`/`7-day`.
- Зняти тумблер → дропдаун **одразу** (live callback, без реполу) згортається до лише `5-hour` +
  `7-day`; повернути → per-model рядки з'являються знову.
- Стан персиститься: перезапуск застосунку зберігає вибір.

### Нотифікація «Back to work!» (#160, ADR-0039)

Системна нотифікація, що спрацьовує на фронті `blocked → unblocked` (ліміт знову дозволяє роботу).
**Потребує реального `.app`** із `/Applications` — у `swift run` `UNUserNotificationCenter` не
авторизується (як launch-at-login та авто-апдейт); у dev-білді Settings показує підказку про це.

Кроки:

1. Settings → **Notifications** → увімкнути «Back to work» → підтвердити системний промпт авторизації.
2. Переконатися, що поточний час **у дозволеному вікні годин** і сьогодні **не** suppress-день.
3. Запустити `TOKENPACE_STUB=just-unblocked` (у встановленому `.app`, не `swift run`).
4. Через ~один пол після старту має з'явитися банер **«Back to work!»**.

**Швидка перевірка кнопкою «Try» (#193):** у Settings → **Notifications**, поряд із перемикачем,
є кнопка **Try**, що надсилає банер **негайно**, оминаючи edge-детект і вікно дозволених годин —
без стуба `just-unblocked`. Кроки: увімкнути «Back to work» (підтвердити промпт авторизації) →
натиснути **Try** → банер з'являється одразу. Це найпростіший спосіб перевірити сам банер (контент,
звук). Кнопка активна **лише коли перемикач увімкнено** і банер реально доставний: у dev-білді
(`swift run`, `.dev`) та при відмові в дозволі (`.denied`) вона сіра. Стани кнопки:

| Перемикач | authState | Кнопка «Try» |
| --- | --- | --- |
| OFF | будь-який | сіра |
| ON | authorized | активна |
| ON | denied | сіра |
| — | dev (`swift run`) | сіра |

Нотифікація **не** з'явиться (за дизайном), якщо: поточний час **поза** вікном годин; сьогодні
**suppress**-день (Fri-Sat / Sat-Sun — з урахуванням Правила A для wrap-вікна); або дозвіл на
нотифікації **не надано** (System Settings → Notifications → TokenPace).

**Рестарт-сценарій** (персистований стан): запустити `just-unblocked`, **вбити застосунок на першому
(заблокованому) полі**, знову запустити — банер має з'явитися після старту (стан «заблоковано»
переживає рестарт через `PersistedConfig.backToWorkWasBlocked`).

**Динамічна тривалість вікна:** у Settings поряд із тайм-пікерами показується «Nh window», що
оновлюється наживо при зміні пікерів (у т.ч. wrap через опівніч і `start == end` → «24h window»).

### Нотифікація «Now using Extra Usage Credit»

Системна нотифікація, що спрацьовує на фронті `not-on-credits → on-credits` (базовий ліміт вичерпано
і платний кредит починає покривати роботу — `ExtraUsageOnset.isOnCredits`). Тіло банера несе **суму
витраченого** і **ліміт** (якщо заданий): `«… now spending paid credit: €2.40 of €50.00.»`; за
unlimited-ліміту — `«… €10.77 so far.»`. **Потребує реального `.app`** із `/Applications` (як
«Back to work»); ділить один дозвіл-авторизацію з нею. Підкоряється **тому самому** вікну дозволених
годин + suppress-днів.

Кроки:

1. Settings → **Notifications** → увімкнути «Switching to Extra Usage» → підтвердити системний промпт
   авторизації (спільний із «Back to work»).
2. Переконатися, що поточний час **у дозволеному вікні годин** і сьогодні **не** suppress-день.
3. Запустити `TOKENPACE_STUB=credits-onset` (у встановленому `.app`, не `swift run`).
4. Через ~один пол після старту має з'явитися банер **«Now using Extra Usage Credit»** із рядком
   «€10.77 of €15.00».

**Швидка перевірка кнопкою «Try»:** поряд із перемикачем «Switching to Extra Usage» є кнопка **Try**,
що надсилає банер **негайно**, оминаючи edge-детект і вікно дозволених годин (тіло бере суму/ліміт із
останнього снапшоту, або generic-рядок, якщо `spend` відсутній). Найпростіший спосіб перевірити сам
банер без стуба — увімкнути перемикач, надати дозвіл, натиснути **Try**.

Нотифікація **не** з'явиться (за дизайном), якщо: поточний час поза вікном / suppress-день; дозвіл на
нотифікації не надано; або кредити вже на стелі (`spend_limit_reached` → це блокування, домен
«Back to work», а не цей). Стан «was on credits» персиститься (`PersistedConfig.extraUsageWasOnCredits`),
тож фронт переживає рестарт — як і в back-to-work.

### Фрейми вибору reset-часу (#103, ADR-0029)

Фіксовані severity 5h × 7d для таблиці вибору reset-часу:

| Стуб | 5h | 7d | Нотатка |
|---|---|---|---|
| `5h-orange` | orange | green | за default-ON #94 7d calm → **одинокий центрований orange-5h** |
| `both-orange` | orange | orange | обидва ahead ~26 пт |
| `both-red` | red | red | обидва вичерпані; пізніший ресет — 7d |
| `red-orange` | red | orange | red-бар (5h) керує countdown |
| `calm5-orange7` | calm | orange (days away) | кейс, де режим reset-countdown (smart vs never) дає видиму різницю |
| `calm-both` | green | green | обидва calm **зелені** (малий запас: 5h ~10 пт < 0.20, 7d ~9 пт < 0.143 — під фіксованим behind-порогом, тож НЕ сині); за default-ON #94 7d ховається → **одинока центрована зелена 5h** без reset-тексту (зніми чекбокс — знову дві смужки) |
| `near-reset` | orange (override) | green | ADR-0044: 5h попереду лише ~2 пт (usage 98 vs elapsed ~96 %), але ресет за **12 хв** → override робить бар **помаранчевим** (без override був би жовтий/calm), countdown зʼявляється. Перевірка динамічного порога + 20-хв override |
| `far-behind` | blue | blue | ADR-0061: обидва базові бари глибоко позаду (5h запас ~0.55, 7d ~0.61 — над behind-порогом, past 20-хв start-override) → **сині**. Перевірка синьої зони + опції **«Work harder»**: увімкни Calm colors (Settings → Appearance) — під **Work harder OFF** синій мутиться в білий, під **Work harder ON** лишається синім. Per-model/credits рядки (у попапі) лишаються зеленими навіть тут |

> Додаючи нову фічу зі своїм станом — **додай стуб і онови цю таблицю** (як зробили для #103, #94, ADR-0044, ADR-0061).
>
> **Синій — лише базові 5h/7d.** Синя зона (`.farBehind`, ADR-0061) з'являється, коли запас
> `time − usage` перевищує behind-поріг **фіксованої часової ширини** — 60 хв / 5h = 0.20, 24 год / 7d
> ≈ 0.143 — і минуло > 20 хв вікна. Наявні «зелені» стуби (`calm-both`, `red-green`, `calm5-orange7`,
> `near-reset` 7d) мають **малий** запас, тож коректно лишаються зеленими — синій демонструє лише
> `far-behind`. Опція «Work harder» (Appearance, друга після «Calm colors») тримає синій кольоровим
> під Calm; дефолт off, Chill off / Control freak on.

## Сценарії без стубу

### Форсований delegated refresh (#183)

Мета — вручну запустити **справжній** спаун `claude --safe-mode --model haiku -p '/usage'`
(delegated refresh, ADR-0017), не чекаючи природної експірації токена, щоб перевірити його поведінку —
зокрема відсутність TCC-промпту від імені TokenPace, коли в користувача є SessionStart-хук, що читає
файл із File Provider domain (iCloud/Dropbox/GDrive).

Стуб **`TOKENPACE_FORCE_REFRESH=1`** підміняє лише токен-провайдер на такий, що завжди повертає
*протухлий* токен → рушій щополінгу бере гілку `.expired` і кличе **реальний** `ClaudeCLIRefresher`.
На відміну від `TOKENPACE_STUB`, транспорт і рушій лишаються справжніми (тому працює тільки **без**
`TOKENPACE_STUB`). Anti-flap гейт стримує повторні спроби (cooldown `1→5→30→60 хв`), тож перший спаун
стається одразу на старті.

Перевірка (підніми стріми **першими**, тоді запускай):

```sh
log stream --predicate 'subsystem == "com.artem-n.tokenpace"' --level debug &
log stream --predicate 'process == "tccd"' --info --debug | grep -i tokenpace &
tccutil reset FileProviderDomain com.artem-n.tokenpace   # скинути грант для чистоти
TOKENPACE_FORCE_REFRESH=1 /Applications/TokenPace.app/Contents/MacOS/TokenPace
```

→ у логах `keychain` мають бути `delegated refresh: launching cli, path=…` і далі `expiresAt advanced`
(якщо реальний токен у Keychain справді протух і CC його оновив) або `cli exited 0 but keychain
unchanged` (якщо токен ще свіжий — спаун усе одно відбувся). **Не має бути** рядка `tccd` `Prompting
for access … by TokenPace`. Оскільки спаун чіпає **реальний** Keychain, запускай на власному Mac із
робочим Claude Code.

### Пауза опитування на екрані (#114)

Немає окремого стубу — перевіряється будь-яким стубом + реальним блокуванням екрана. Запусти
dev-білд, заблокуй екран (⌃⌘Q), розблокуй, і перевір логи:

```sh
log show --last 3m --predicate 'process == "TokenPace" AND eventMessage CONTAINS "screen-lock-pause"'
```

→ мають бути `screen locked, pausing polling` і `screen unlocked, polling immediately`, і **жодного**
`interval`/usage-логу між ними. Чекбокс — Settings → General → «Pause polling while the screen is
locked».

### Сигнали авто-апдейту — єдиний пункт дропдауна (#130, ADR-0036)

Мета — **менше шуму**: жодних системних нотифікацій (`UpdateNotifier` видалено), усе — в одному
пункті меню, що змінює лише колір крапки й текст. Стуб **`TOKENPACE_UPDATE_STATE=<state>`** форсує
стан пункту без реального релізу/фейлу (пише лише в пам'ять, **не** в `UserDefaults`):

| `TOKENPACE_UPDATE_STATE` | Крапка | Текст |
|---|---|---|
| `failed` | 🔴 | `New version available (update failed)…` |
| `available` | 🔵 | `New version available…` |
| `pending` | 🔵 | `Update pending…` |
| `whatsnew` | 🔵 | `What's new in the version…` |

Перевірка: `TOKENPACE_UPDATE_STATE=whatsnew TOKENPACE_STUB=1 swift run` → відкрий меню, глянь
колір/текст пункта (над Quit) й **вирівнювання крапки** з текстом (має збігатися з крапками статусів
сервісів у popup). Клік завжди → **Settings → About** (не браузер, з #210); `whatsnew` після кліку
зникає (крім форсованого стуба — той тримає стан). У логах: `update: menu item = <state>` і
`update: user opened About from update item`.

### About: деталі зафейленого апдейту + клікабельні версії (#210)

На панелі **About** оновлено кілька елементів:

Панель має дві секції:

- **Секція 1 (identity):** `Source code` · `Version` (просто номер, без лінка) · *(опційно)* рядок
  🔵 **New version available: X.Y.Z** з **Release notes** (лінк на `…/releases/tag/vX.Y.Z`) ліворуч
  біля тексту й **Download** (веб-реліз) праворуч.
- **Секція 2 (behaviour):** `Check for updates periodically` (+ Check Now) · `Install updates
  automatically` · *(опційно)* рядок 🔴 **Update to version X.Y.Z failed during `<стадія>`.** +
  `Reason: <причина>` (selectable, переноситься).

Крапки беруть ті самі `ColorStore`-кольори, що й дропдаун (синя `popupServiceBlue`, червона
`popupServiceRed`). Усі версії показуються **без `v`**; release-notes URL усе одно бʼє в `vX.Y.Z`.

Стуб **`TOKENPACE_FAKE_FAILURE=<stage>:<reason>`** форсує failure-рядок у About (пише лише в пам'ять,
**не** в `UserDefaults`); `<stage>` ∈ `download|unzip|verify|replace`; тег береться з
`TOKENPACE_FAKE_LATEST` або дефолтний `vX.Y.Z`. Разом із `TOKENPACE_SETTINGS_SECTION=0` відкриває
одразу About. Приклад:

```sh
TOKENPACE_STUB=1 TOKENPACE_DEVTOOLS=1 TOKENPACE_SETTINGS_SECTION=0 \
TOKENPACE_UPDATE_STATE=failed TOKENPACE_FAKE_LATEST=v0.56.0 \
TOKENPACE_FAKE_FAILURE='verify:team id mismatch (expected S5A4U9798Y, got ABCDE12345)' \
swift run
```

→ відкрий Settings (меню) → About: перевір обидві крапки, клік по Version і по «Update available»
(відкривають release notes у браузері), довгу причину (не обрізається, selectable).

### Авто-встановлення оновлень (#122–#125, ADR-0033; сигнали ADR-0036)

Повний флоу (download→verify→unzip→replace) працює **лише в нотаризованому `.app` із
`/Applications`** — у `swift run` інсталятор одразу `.notApplicable`. Опція
`installUpdatesAutomatically` — **default-ON** (opt-out, з #130). Після успіху пункт меню показує 🔵
«What's new…» (переживає рестарт); після фейлу — 🔴 «…(update failed)…», і цей tag не ретраїться.

- Стуб **`TOKENPACE_UPDATE_DRYRUN=1`** ганяє download→verify→unzip **без** заміни й перезапуску (і
  оминає гейти AC-power/metered — це forced-шлях). Приватний репо: asset качається через `gh` за
  `TOKENPACE_GH_AUTH=1`. Верифікація: збери нотаризований білд із **заниженою** версією (щоб реальний
  GitHub-реліз був новішим), постав у `/Applications` (**зроби backup чинного релізу!**), запусти
  ```sh
  TOKENPACE_GH_AUTH=1 TOKENPACE_UPDATE_DRYRUN=1 /Applications/TokenPace.app/Contents/MacOS/TokenPace
  ```
  з увімкненими обома чекбоксами Updates. Докази проходження (логи невидимі при прямому запуску, не
  через launchd): `defaults read com.artem-n.tokenpace lastSeenLatestVersion` = знайдений тег, і
  збережений верифікований bundle `$TMPDIR/TokenPace-update-<tag>.app` (перевір `codesign -dv` +
  `spctl --assess`). Після тесту **віднови чинний реліз** у `/Applications`.
- Для **реальної** заміни+relaunch (без dry-run) є стуб **`TOKENPACE_UPDATE_TARGET=<шлях>`** — націлює
  інсталятор на тестову копію `.app` поза `/Applications`, тож робочий інстанс не чіпається:
  ```sh
  cp -R build/TokenPace.app ~/UpdateTest/TokenPace.app
  TOKENPACE_GH_AUTH=1 TOKENPACE_UPDATE_TARGET=~/UpdateTest/TokenPace.app ~/UpdateTest/TokenPace.app/Contents/MacOS/TokenPace
  ```
  → копія має замінитись на новіший тег і перезапуститись; перевір версію копії + що новий процес
  стартував + `codesign`/`spctl` заміненого bundle. Прибери `~/UpdateTest` після тесту.

### Авто-відкриття вікна Settings при запуску

`TOKENPACE_OPEN_SETTINGS=1 swift run` (можна разом зі стубом даних) — dev-білд відкриває вікно
**Settings** одразу після старту, ~0.6 с. Це прибирає потребу клікати menu-bar item через AX, що
**небезпечно за кількох інстансів TokenPace** (клік може влучити не в той білд — див. нижче). Зручно
для швидкого перегляду змін у Settings.

```sh
TOKENPACE_OPEN_SETTINGS=1 TOKENPACE_STUB=screenshot swift run
```

Флаг opt-in (не прив'язаний до dev-білда), тож звичайний `swift run` стартує тихо. Продакшн-`.app`
поводиться так само лише за явно виставленого env, чого при нормальному запуску не буває.

Додатково `TOKENPACE_SETTINGS_SECTION=<index>` відкриває **конкретну** секцію Settings за 0-based
індексом (0=About, 1=General, 2=Appearance, 3=Monitored Services, 4=Notifications, 5=Session Logs) —
щоб зробити скриншот потрібної панелі без AX-кліку по sidebar-рядку:

```sh
TOKENPACE_OPEN_SETTINGS=1 TOKENPACE_SETTINGS_SECTION=4 swift run   # відкриє одразу на Notifications
```

### Авто-відкриття вікна Troubleshoot при запуску

`TOKENPACE_OPEN_TROUBLESHOOT=1 swift run` — так само відкриває вікно **Troubleshoot** одразу після
старту (~0.6 с). У нормальному потоці воно ховається за ⌥-розкритим пунктом меню, який ще незручніше
клікати через AX (модифікатор треба тримати під час трекінгу меню), тож стуб потрібен для скриншотів.
Комбінується зі стубом даних:

```sh
TOKENPACE_OPEN_TROUBLESHOOT=1 TOKENPACE_STUB=screenshot swift run
```

Джерело істини цього порядку/індексів — `enum SettingsSection: Int` (ADR-0042); змінюючи секції, онови
його і цей рядок разом. Detail-панелі тепер SwiftUI `Form.formStyle(.grouped)` (ADR-0042), тож паритет
grouped-inset карток доводиться скриншотами light+dark так само, як раніше для AppKit-версії.

### Development tools — колор-тюнер (#185)

Dev-інструмент підбору кольорів: вікно з дропдауном усіх ~35 іменованих кольорових ролей (menu-bar і
popup pacing **розділені**; є popup service-доти, warning red, «in use» pill, link, label) + **вбудований
inline-пікер** у правій панелі — усі 6 каналів (RGB **і** HSB) разом, над кожним повзунком динамічна
градієнт-стрічка, редаговані 16-бітні поля 0–65535 + alpha, живі копійовані RGB(0–255)+HEX readout-и.
Перемальовує menu-bar іконку й popup-preview **наживо**. У preview-вікні під popup — два mock-рядки
(синя «New update available» / червона «Automatic update failed») для підбору відповідних кольорів.
Гейт — **`defaults`-ключ `devToolsEnabled`** (`defaults write com.artem-n.tokenpace devToolsEnabled -bool true`,
ADR-0053) **плюс** затиснутий ⌥ Option на пункті меню «Development tools…». Незалежить від
типу білда (dev / notarized / release): гейт — `UserDefaults`-ключ, не `#if DEBUG`. Override-и
**ephemeral** (не персистяться); без ключа шар кольорів інертний (завжди дефолти).

> **Лише на встановленому `.app`.** Ключ читається з домену bundle id, тож діє тільки коли ключ
> виставлено на нотаризованому `.app` і його ж запущено. У `swift run` бінарник **без bundle id** →
> інший домен `UserDefaults`, тож `defaults write com.artem-n.tokenpace …` на нього не впливає —
> тюнер тепер можна ганяти **лише на зібраному `.app`**, не в `swift run` (ADR-0053).

Запуск для перевірки (auto-open обходить незручний ⌥-клік по menu-bar, як для Troubleshoot):

```sh
defaults write com.artem-n.tokenpace devToolsEnabled -bool true
TOKENPACE_OPEN_DEVTOOLS=1 TOKENPACE_STUB=both-orange open -n /Applications/TokenPace.app
```

→ вікно тюнера (always-on-top) відкриється саме, поруч — окреме always-on-top вікно **«Popup preview»**
з живим рендером дропдауна. Обери роль (напр. «Popup · gap orange»), посунь повзунок каналу (або
впиши 16-бітне значення) — і preview-вікно, і menu-bar іконка міняються негайно. Закриття вікна тюнера
закриває й preview. **Reset** / **Reset all** повертають дефолти,
**Copy sRGB** кладе значення в буфер, ● позначає недефолтні ролі. Без `devToolsEnabled` пункт меню
не з'являється навіть під ⌥, а `TOKENPACE_OPEN_DEVTOOLS` ігнорується.

### Тестування кольорів menu-bar віджета (swatch-режим + піпетка)

Підбір/звірка кольорів menu-bar (щоб гліф/бари/текст збігалися з нативними іконками — місяць, годинник,
Wi-Fi, battery) має **суворий метод**, вироблений болісним досвідом (сесія рефактора semantic-кольорів):

1. **Скріншот — НЕ джерело кольору.** `screencapture` на wide-gamut/XDR-дисплеї систематично спотворює
   RGB (color management), і кілька разів заводив у хибні висновки. Джерело істини — **Digital Color
   Meter** (нативна піпетка) у режимі **sRGB** (View → Display in sRGB). Див. розділ «Кольори» в CLAUDE.md.
2. **Завжди на РЕАЛЬНОМУ барі, скріншот ВЕРХНЬОЇ СМУГИ повного екрана — не вікна.** Скріншот вікна
   (напр. color-tuner preview) рендерить віджет **без menu-bar vibrancy й шпалери** → бреше. Прозорі
   ефекти («дихання» кольором фону) видно тільки на реальному барі поряд із системними іконками.
3. **Swatch-режим `TOKENPACE_SWATCHES=1`.** Замість віджета малює **великі кольорові квадрати**
   (`StatusItemView.render`) — кандидати кольору/alpha пліч-о-пліч. Так їх легко піпкати й порівнювати
   із сусідньою системною іконкою на **тому самому** реальному барі. Запуск:
   `TOKENPACE_SWATCHES=1 TOKENPACE_STUB=screenshot swift run` (або на `.app`). Редагуй набір свотчів у
   `render` під конкретну перевірку.
4. **Перевіряй на різних суцільних шпалерах** — чорна / темно-синя / світло-сіра / біла / кольорова
   (teal). Menu-bar світлість вирішується **per-display від яскравості шпалери**, НЕ від системної теми:
   на світлій шпалері бар світлий навіть у Dark mode. Тому світлий і темний бар — окремі випадки.
   Ставити/повертати шпалеру: `osascript -e 'tell application "System Events" to set picture of every
   desktop to "…"'` (систему лишати в оригінальному стані після тесту).
5. **Реальний режим бару — `NSStatusBarButton.effectiveAppearance`** (не `NSApp.effectiveAppearance` й
   не `view.effectiveAppearance` — ті echo системну тему, а не бар). `bestMatch(from:[.aqua,.darkAqua])`
   на ньому коректно фліпає з реальним баром (ADR-0059 / ticket §2.4).
6. **Цільові значення (виміряні на цьому дисплеї, орієнтир):** місяць — світлий бар `~0xC1C1C1`, темний
   `~0x4C5A6D` (дихає відтінком шпалери); системний текст (годинник) — світлий `~0x24`, темний `~0xE7`.

## Що НЕ рахується за верифікацію

- **Скриншоти з тимчасового dev-only коду.** Синтетичний рендер `StatusItemView` / PNG-матриці
  доводить лише логіку малювання, а не те, що фіча працює в живому віджеті, вікні Settings і потоці
  даних. Не заявляй «працює» / `готово` на їх основі.

## Фічі, що потребують підпису

Для фіч, що залежать від підпису (launch-at-login / SMAppService, банери оновлень), потрібен
**локальний нотаризований `.app`** із `/Applications` — у dev `swift run` вони не працюють.
