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

> **Живе перемикання без рестарту (#187, ADR-0047).** У dev-збірці (`TOKENPACE_DEVTOOLS=1`) відкрий
> ⌥ Option → меню → **Development tools…** і вибери сценарій у випадайці **Data source (stub)** угорі
> лівої колонки — джерело даних перемкнеться наживо (menu-bar іконка й popup оновляться протягом одного
> циклу полу), під випадайкою показано опис поточного сценарію. `TOKENPACE_STUB=…` при старті досі
> працює і **задає початковий вибір** випадайки; «Real network (no stub)» повертає застосунок на живий
> API. Для скриптингу: `TOKENPACE_DEVTOOLS=1 TOKENPACE_OPEN_DEVTOOLS=1 swift run` авто-відкриває вікно.
> Послідовнісні стуби (`stale-error`, `reset-grace`, `optimistic-reset`, `just-unblocked`)
> відтворюються з полу №1 при повторному виборі (свіжий `StubUsageTransport` скидає лічильник полів).

| Стуб | Що показує |
|---|---|
| `1` | climbing — usage повзе вгору |
| `screenshot` | стабільний кадр для скриншотів: 5h **зелений** (10 % vs ≈65 % — well behind), 7d **жовтий** (36 % vs ≈29 % — mild ahead, під динамічним порогом `0.16·(1−time)`, навмисно не на amber/orange-межі, де сиділо старе 40 %), Fable **оранжевий** / Mythos **червоний** |
| `error` | auth-помилка (401) → ⚠️ (лише банер, без ліміт-рядків — cold-start) |
| `stale-error` | **stale-while-erroring** (баг відступу): перший полл валідний (повні бари: idle 5h «ready to start», 18 % 7d, Fable-рядок, «Extra usage» €11.68/€15.00), далі кожен полл — timeout → ⚠️ банер «Claude API connectivity issue» / «Authentication API timeout» **над** усіма барами. Перевіряй **горизонтальний відступ між текстом помилки і рядком «5-hour»** (той самий `sectionSpacing`, що після хедера) — без нього блок помилки злипався з «5-hour». API + Code — major outage (червоні крапки) |
| `idle` | «немає активної 5h-сесії» (#100): суцільний синій 5h-бар, без phantom-ресету, час падає на 7d-ресет («4d»). За default-ON «Hide 7-day bar when calm» (#94) 7d calm → **одинокий центрований idle-бар** |
| `idle-blocked` | **заблокований** idle (#158): idle 5h + 7d вичерпано (100 %) без credits. За default-ON «Hide pacing bars when blocked» (#194, ADR-0048) меню-бар показує **лише countdown до ресету, без барів**. Вимкни опцію (Settings → Appearance) → idle-бар **базовий сірий** (як стрічка пейсингу; у **обох** режимах Calm on/off). У попапі — завжди повна картина: статус «waiting for limit reset», 7d-ресет **червоний бейдж** (пігулка). Порівнюй з `idle`: там синій «ready to start», а під Calm — світло-сірий (не білий) |
| `active-blocked` | **активний** blocked (#177): жива 5h-сесія (48 %) при вичерпаному 7d (100 %, `weekly_all` critical) без credits → тижневий cap блокує попри квоту 5h. За default-ON «Hide pacing bars when blocked» (#194) меню-бар показує **лише countdown, без барів** (main-вікно вичерпане). Вимкни опцію → бари повертаються (5h-рядок звичайний «on pace»). У попапі — завжди повна картина: 7d-ресет отримує **червоний бейдж** «Effective blocker» |
| `optimistic-reset` | reset-boundary (#36): 5h ресетиться через ~20 с — бар стрибає 60 %→0 % без ⏰ + форс-рефреш |
| `reset-grace` | грейс на межі ресету (ADR-0041, ADR-0045): активне 5h-вікно (поли 0–1) → **порожнє** post-reset тіло (поли 2–3: `five_hour.resets_at:null`, без `session`-ліміту — декодер сам по собі дав би `sessionIdle`) → активне знову (поли 4+). У «дірі» 5h-рядок має показувати спокійний **0 % «on pace» з rolled-forward відліком** (`Nh at …`), а меню-бар **не блимати** — **ніколи «resetting…» чи зелений бар на всю ширину** (ADR-0045). Грейс озброюється лише коли запущений процес `claude` (`claudeActive`) — інакше показується чесний idle «ready to start» одразу. Порівнюй з `idle`: там idle **справжній** і має показатися |
| `broken-reset` | зламаний `resets_at` (#167, ADR-0043): «шумний» 5h (100 %) із **непарсабельним, але непорожнім** `resets_at` (`"not-a-date"`, НЕ `null` — `null`/порожній дав би чесний `sessionIdle`, а не помилку) → меню-бар показує **⚠️ замість пейсинг-барів** (як інша помилка API), а не фейкове `<1m`. 7d — calm із валідним ресетом (не джерело помилки) |
| `calm-degraded` | calm-бари + **degraded (жовта)** service-крапка: за вимкненого «Calm colours» (#105) крапка жовта; увімкни Calm (Settings → General) — крапка **біліє** разом із барами. Кадр для перевірки гасіння service-крапки |
| `just-unblocked` | «Back to work!» edge (#160): перший пол заблокований (7d=100 %, без кредитів), далі workable (7d=40 %) → нотифікація спрацьовує один раз. Див. окрему секцію нижче |

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
| `credits-active` | Рядок «Extra usage ⟷ on pace / (well) ahead of pace» (залежно від дати місяця vs 72 %), рядок «€10.77 / €15.00 ⟷ `<reset line>`» — уніфікований формат до кінця календарного місяця в **місцевому** поясі (`15d` / `5d on Friday` / `20h at 03:00`, ADR-0043), і **бар** тим самим кольором, що іконка |
| `credits-limit-reached` | «Extra usage ⟷ limit reached», «€10.77 / €5.00 ⟷ `<reset line>`», **червоний** бар (usage форсовано в 1) |
| `credits-no-limit` | Лише «Extra usage ⟷ €10.77 spent» — **без** бару, **без** рядка ресету (unlimited, немає стелі) |

> Перевір, що суми — з валютою **€** (не `$`): форматер бере символ із коду валюти (EUR→€). Бар
> секції — той самий `PopupBarView`, що бари токенів, але **без** засічок-ticks (кредити пейсяться на
> весь місяць, без під-вікон).

### Нотифікація «Back to work!» (#160, ADR-0039)

Системна нотифікація, що спрацьовує на фронті `blocked → unblocked` (ліміт знову дозволяє роботу).
**Потребує реального `.app`** із `/Applications` — у `swift run` `UNUserNotificationCenter` не
авторизується (як launch-at-login та авто-апдейт); у dev-білді Settings показує підказку про це.

Кроки:

1. Settings → **Notifications** → увімкнути «Back to work» → підтвердити системний промпт авторизації.
2. Переконатися, що поточний час **у дозволеному вікні годин** і сьогодні **не** suppress-день.
3. Запустити `TOKENPACE_STUB=just-unblocked` (у встановленому `.app`, не `swift run`).
4. Через ~один пол після старту має з'явитися банер **«Back to work!»**.

Нотифікація **не** з'явиться (за дизайном), якщо: поточний час **поза** вікном годин; сьогодні
**suppress**-день (Fri-Sat / Sat-Sun — з урахуванням Правила A для wrap-вікна); або дозвіл на
нотифікації **не надано** (System Settings → Notifications → TokenPace).

**Рестарт-сценарій** (персистований стан): запустити `just-unblocked`, **вбити застосунок на першому
(заблокованому) полі**, знову запустити — банер має з'явитися після старту (стан «заблоковано»
переживає рестарт через `PersistedConfig.backToWorkWasBlocked`).

**Динамічна тривалість вікна:** у Settings поряд із тайм-пікерами показується «Nh window», що
оновлюється наживо при зміні пікерів (у т.ч. wrap через опівніч і `start == end` → «24h window»).

### Фрейми вибору reset-часу (#103, ADR-0029)

Фіксовані severity 5h × 7d для таблиці вибору reset-часу:

| Стуб | 5h | 7d | Нотатка |
|---|---|---|---|
| `5h-orange` | orange | green | за default-ON #94 7d calm → **одинокий центрований orange-5h** |
| `both-orange` | orange | orange | обидва ahead ~26 пт |
| `both-red` | red | red | обидва вичерпані; пізніший ресет — 7d |
| `red-orange` | red | orange | red-бар (5h) керує countdown |
| `calm5-orange7` | calm | orange (days away) | кейс, де режим reset-countdown (smart vs never) дає видиму різницю |
| `calm-both` | green | green | обидва calm; за default-ON #94 7d ховається → **одинока центрована зелена 5h** без reset-тексту (зніми чекбокс — знову дві смужки) |
| `near-reset` | orange (override) | green | ADR-0044: 5h попереду лише ~2 пт (usage 98 vs elapsed ~96 %), але ресет за **12 хв** → override робить бар **помаранчевим** (без override був би жовтий/calm), countdown зʼявляється. Перевірка динамічного порога + 20-хв override |

> Додаючи нову фічу зі своїм станом — **додай стуб і онови цю таблицю** (як зробили для #103, #94, ADR-0044).

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
сервісів у popup). Клік завжди → сторінка релізів; `whatsnew` після кліку зникає (крім форсованого
стуба — той тримає стан). У логах: `update: menu item = <state>`.

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
Гейт — **`TOKENPACE_DEVTOOLS`**
(непорожнє значення) **плюс** затиснутий ⌥ Option на пункті меню «Development tools…». Незалежить від
типу білда (dev / notarized / release): гейт — env-var, не `#if DEBUG`. Override-и **ephemeral** (не
персистяться); без env-var шар кольорів інертний (завжди дефолти).

Запуск для перевірки (auto-open обходить незручний ⌥-клік по menu-bar, як для Troubleshoot):

```sh
TOKENPACE_DEVTOOLS=1 TOKENPACE_OPEN_DEVTOOLS=1 TOKENPACE_STUB=both-orange swift run
```

→ вікно тюнера (always-on-top) відкриється саме, поруч — окреме always-on-top вікно **«Popup preview»**
з живим рендером дропдауна. Обери роль (напр. «Popup · gap orange»), посунь повзунок каналу (або
впиши 16-бітне значення) — і preview-вікно, і menu-bar іконка міняються негайно. Закриття вікна тюнера
закриває й preview. **Reset** / **Reset all** повертають дефолти,
**Copy sRGB** кладе значення в буфер, ● позначає недефолтні ролі. Без `TOKENPACE_DEVTOOLS` пункт меню
не з'являється навіть під ⌥, а `TOKENPACE_OPEN_DEVTOOLS` ігнорується.

## Що НЕ рахується за верифікацію

- **Скриншоти з тимчасового dev-only коду.** Синтетичний рендер `StatusItemView` / PNG-матриці
  доводить лише логіку малювання, а не те, що фіча працює в живому віджеті, вікні Settings і потоці
  даних. Не заявляй «працює» / `готово` на їх основі.

## Фічі, що потребують підпису

Для фіч, що залежать від підпису (launch-at-login / SMAppService, банери оновлень), потрібен
**локальний нотаризований `.app`** із `/Applications` — у dev `swift run` вони не працюють.
