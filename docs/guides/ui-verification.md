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

## Стуби `TOKENPACE_STUB`

Запуск: `TOKENPACE_STUB=<name> swift run`. Стуб підміняє транспорт usage- та status-запитів
(`StubUsageTransport` у `Sources/TokenPace/PollingShell.swift`; диспетч у `App.swift`).

| Стуб | Що показує |
|---|---|
| `1` | climbing — usage повзе вгору |
| `screenshot` | стабільний кадр для скриншотів |
| `error` | auth-помилка (401) → ⚠️ |
| `idle` | «немає активної 5h-сесії» (#100): суцільний синій 5h-бар, без phantom-ресету, час падає на 7d-ресет («4d»). За default-ON «Hide 7-day bar when calm» (#94) 7d calm → **одинокий центрований idle-бар** |
| `idle-blocked` | **заблокований** idle (#158): idle 5h + 7d вичерпано (100 %) без credits → idle-бар **базовий сірий** (як стрічка пейсингу; меню-бар і попап, у меню-барі в **обох** режимах Calm on/off), у попапі статус «waiting for limit reset», а 7d-ресет — **червоний бейдж** (пігулка). Порівнюй з `idle`: там синій «ready to start», а під Calm — світло-сірий (не білий) |
| `optimistic-reset` | reset-boundary (#36): 5h ресетиться через ~20 с — бар стрибає 60 %→0 % без ⏰ + форс-рефреш |
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
| `credits-active` | Рядок «Extra usage ⟷ on pace / (well) ahead of pace» (залежно від дати місяця vs 72 %), рядок «€10.77 / €15.00 ⟷ resets in Nd/Nh» (до кінця календарного місяця, UTC), і **бар** тим самим кольором, що іконка |
| `credits-limit-reached` | «Extra usage ⟷ limit reached», «€10.77 / €5.00 ⟷ resets in …», **червоний** бар (usage форсовано в 1) |
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

> Додаючи нову фічу зі своїм станом — **додай стуб і онови цю таблицю** (як зробили для #103, #94).

## Сценарії без стубу

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

Джерело істини цього порядку/індексів — `enum SettingsSection: Int` (ADR-0042); змінюючи секції, онови
його і цей рядок разом. Detail-панелі тепер SwiftUI `Form.formStyle(.grouped)` (ADR-0042), тож паритет
grouped-inset карток доводиться скриншотами light+dark так само, як раніше для AppKit-версії.

## Що НЕ рахується за верифікацію

- **Скриншоти з тимчасового dev-only коду.** Синтетичний рендер `StatusItemView` / PNG-матриці
  доводить лише логіку малювання, а не те, що фіча працює в живому віджеті, вікні Settings і потоці
  даних. Не заявляй «працює» / `готово` на їх основі.

## Фічі, що потребують підпису

Для фіч, що залежать від підпису (launch-at-login / SMAppService, банери оновлень), потрібен
**локальний нотаризований `.app`** із `/Applications` — у dev `swift run` вони не працюють.
