# Performance — гейти періодичних завдань

TokenPace крутить п'ять періодичних завдань. Цей документ — одна зведена таблиця: **що саме кожне з
них зупиняє, сповільнює або взагалі не помічає**. Він відповідає на питання «чи прокидається
застосунок на замкненому Mac», «чи зжере він трафік на роздачі», «чи розрядить батарею» — без читання
п'яти різних файлів.

Це довідка про **фактичний стан коду**, не про задум. Де код розходиться з проєктним документом, це
позначено явно.

Суміжні документи: каденції й потік даних — [architecture/data-flow.md](architecture/data-flow.md);
система оновлень — [architecture/update-system.md](architecture/update-system.md); статус сервісів
і архіватор — [architecture/services-and-config.md](architecture/services-and-config.md).

## Зведена таблиця

| Гейт | Usage API | Статуси сервісів | Awaiting-input | Резервне копіювання | Авто-інсталяція оновлень |
|---|---|---|---|---|---|
| **Screen lock / скрінсейвер / display sleep** | ✅ повна зупинка, gated `pausePollingWhenScreenLocked` (default on) | ✅ непрямо | ❌ [#275](https://github.com/artem-from-ua/tokenpace/issues/275) | ✅ непрямо | ✅ непрямо |
| **System sleep / wake** | ✅ безумовно | ✅ непрямо | ❌ | ✅ непрямо | ✅ непрямо |
| **On-battery** | ❌ | ❌ | ❌ | ❌ | ✅ **defer** до підключення до мережі |
| **Low Power Mode** | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Metered network** | ❌ | ❌ | ❌ (мережі не торкається) | ❌ (пише локально) | ✅ **defer** до безлімітного зʼєднання |
| **Вільне місце на диску** | ❌ | ❌ | ❌ | ❌ | ✅ **defer**, якщо після завантаження лишиться < 5 ГБ |
| **claude CLI running** | ✅ як каденція: 180 с → 15 хв | ✅ непрямо (розтягується разом) | ❌ | ❌ | ❌ |
| **429 / `Retry-After`** | ✅ hold до вказаного часу | ✅ непрямо + власний floor 5 хв | н/д | н/д | н/д |
| **Feature toggle** | н/д (завжди ввімкнено) | н/д | `awaitingInputEnabled` (default **off**) | `archiveEnabled` + заданий `archiveDestination` | `automaticUpdateChecks` + `installUpdatesAutomatically` (обидва default **on**, opt-out) |
| **Власна каденція** | 180 с; 15 хв коли `claude` не запущено; floor 60 с | `max(5 хв, usageInterval)`; при проблемі floor 60 с | FSEvents 0.75 с + safety timer 45 с | раз на 24 год | перевірка раз на 12 год |

Позначки: ✅ — гейт діє; ✅ непрямо — власного таймера немає, завдання успадковує паузу від
usage-циклу; ❌ — гейт відсутній у коді; **defer** — не пропуск, а відкладення до наступного
heartbeat, коли умови покращаться.

## Чому половина колонок каже «непрямо»

Лише два завдання мають власний рушій: usage-полл (`AsyncStream`-цикл) і awaiting-input (FSEvents +
`Timer`). Решта три — статуси, резервне копіювання, перевірка оновлень — **не мають своїх таймерів**.
Вони висять на usage-heartbeat: кожен успішний тік `apply(_:)` по черзі питає їх «чи час?».

```plantuml
@startuml
skinparam componentStyle rectangle
skinparam defaultTextAlignment center

component "PollingEngine\n(AsyncStream-цикл)" as engine
component "AppDelegate.apply(_:)" as apply
component "pollStatusIfDue" as status
component "pollUpdateIfDue" as update
component "pollArchiveIfDue" as archive
component "AwaitingInputWatcher\n(FSEvents + Timer 45 с)" as watcher

component "ScreenLockObserver\nWorkspaceSleepWake" as park
component "UpdateInstallPlan" as instplan

park -down-> engine : .sleep / .wake
engine -down-> apply : PollOutput
apply -down-> status
apply -down-> update
apply -down-> archive
update -down-> instplan : battery / metered / disk

park -[#red,dashed]-> watcher : **немає звʼязку** (#275)

note bottom of watcher
  Єдине завдання поза
  park-механізмом
end note
@enduml
```

![Гейти періодичних завдань — хто на чому висить](https://www.plantuml.com/plantuml/svg/NPDDQzj048Rl-ok6vEAuiGkb8P13YI4f10e9ACM7ffIrD9Q5LhlBxigkZwKVrrn2VuS93IsfqzvpMlsZZhvSEHTfvzrdPcTUhOwjuyRbcM0sJQJcXcSGgamhYT85RYaG38QEorXW1ubmodFXBl6Z6uaabXdH4D833MERVDYvK48aCZwLSIBnIlP6TYd3m1dasQ3uvd_vU_zxRmUu1QoGRkv8wnCK67E7GwwrMFO-7DLi5NLHJSS4ZhlSdarFSgmWMyLFgRSwedh_gRoAdr8Z4ywIUGVZjR3Lte8dZcOxapftO-x26HgQy7LmEgTz2y_WCidGmCi3A3xLVIzgQikX83I8yeqAq_E9HJClYuoLIQtc8GO2KOzvMZT1rgVTr6OMIPCASI6uhAY4Oaq1OoKFWqWjvE1LuoySmT2MHU4v31TKc3LwYrNM4bL-kFFSqMYibbgWiNLRR5pS5blFwisDtFP7Xqouemkpf5uof0L6j8eIcxQjlzibRJ_YTeRHUqfj_AFCVjy_-3k_zglY1lnFV_kuBgxfVLzyxlUXj_lYy62FCQdet8boJcMWfXlx0VmN_uCk7vKearV-bi8LXG_5DVY__ayf4bPsCQ13xeglvNRndVGrxQx9jGZAwkoOLlJt_0C0)

Наслідок: усе, що паркує usage-цикл, автоматично паркує ще три завдання. І навпаки — якщо колись
відвʼязати статуси або архіватор у власний таймер, разом зникнуть усі park-гейти, які вони зараз
успадковують безкоштовно.

**Awaiting-input — єдиний виняток.** Він має власні тригери й до park-механізму не підключений
взагалі, тож працює при замкненому екрані та у сні. Це [#275](https://github.com/artem-from-ua/tokenpace/issues/275).

## Гейти по одному

### Screen lock / скрінсейвер / display sleep

`ScreenLockObserver` ([`PollingShell.swift:105-170`](../../Sources/TokenPace/PollingShell.swift))
слухає три пари подій: `com.apple.screenIsLocked` / `screenIsUnlocked`, `screensaver.didstart` /
`willstop`, `NSWorkspace.screensDidSleep` / `screensDidWake`. Будь-яка з них емітить `.sleep` або
`.wake` у `SignalHub`; цикл на `.sleep` іде в `waitWhileAsleep()` — жодного мережевого запиту.

Gated опцією `pausePollingWhenScreenLocked` (default **on**), яка читається **у мить події**, не
кешується — тож перемикач у Settings → General діє негайно. Див. [ADR-0032](../adr/0032-simplified-polling-cadence.md), рішення D5.

### System sleep / wake

`WorkspaceSleepWake` ([`PollingShell.swift:54-80`](../../Sources/TokenPace/PollingShell.swift)) —
той самий park-шлях, але **безумовний**: опція його не вимикає. Логіка проста: під час сну машини
мережі однаково немає.

Прокидання **не гарантує негайний полл**. `wakeRearmInterval` фетчить лише якщо кеш устиг застаріти
(минув повний інтервал з останнього успіху) — інакше короткий сон не спричиняє зайвий запит.

### On-battery, metered network, вільне місце

Три гейти, які має **тільки** авто-інсталяція оновлень. Вони живуть у чистому
[`UpdateInstallPlan.decide`](../../Sources/TokenPaceKit/UpdateInstallPlan.swift) і застосовуються в
такому порядку (перший спрацьований виграє):

1. вільне місце — після завантаження має лишитись ≥ 5 ГБ, інакше `deferInsufficientSpace`;
2. AC power — на батареї `deferOnBattery`;
3. безлімітна мережа — на metered-зʼєднанні `deferMeteredNetwork`.

Порядок навмисний: повний диск — найтвердіший фізичний блокер, немає сенсу відкладати «до розетки»,
якщо завантаження однаково не влізе.

Це **defer, не skip**: стан не персиститься, рішення переоцінюється на кожному heartbeat, тож
оновлення встановиться саме щойно умови покращаться. Користувачу причина показується реченням
«Update pending because …» — і одразу **всі** закриті гейти, а не лише перший, щоб людину не посилали
спершу ввімкнути живлення, а потім окремо виявляти metered-мережу.

Джерела фактів: `PowerSource.isOnACPower` (IOKit,
[`SystemConditions.swift:19`](../../Sources/TokenPace/SystemConditions.swift)),
`NetworkMonitor.isMetered` (`NWPath.isExpensive || isConstrained`,
[`PollingShell.swift:191-204`](../../Sources/TokenPace/PollingShell.swift)),
`DiskSpace.availableBytes` (`volumeAvailableCapacityForImportantUsage`).

**Важливо:** ці два монітори живуть у polling-шарі, але поллінг ними **не** гейтиться — вони лише
живлять рішення інсталятора. Коментар у коді фіксує це прямо: «Used only to *defer* an auto-install
download onto an unmetered link, never to gate…».

Ручний «Install now» обходить power/metered (користувач попросив явно), але **не** free-space —
жоден намір не робить безпечним заповнення диска.

### claude CLI running

`ProcessClaudeActivityProbe` ([`PollingShell.swift:237-271`](../../Sources/TokenPace/PollingShell.swift))
через `sysctl(KERN_PROC_ALL)` шукає процес з точним іменем `claude` (CLI, не Desktop). Немає
процесу → usage-каденція 15 хв замість 180 с. Це **не зупинка**: ліміти тікають незалежно від того,
чи ти зараз працюєш, тож дані все одно оновлюються, просто рідше.

### 429 / `Retry-After`

Сервер попросив зачекати — чекаємо рівно стільки, без власної ескалації. Ручний refresh скидає hold.
Статус-полл захищений окремим floor'ом 5 хв, тож 429-thrash на usage не б'є сторонню status-сторінку.

## Відсутні гейти

Свідомо або поки що не реалізовані — жодним із пʼяти завдань:

- **Low Power Mode** — `ProcessInfo.isLowPowerModeEnabled` у коді відсутній повністю. Найочевидніший
  кандидат: у цьому режимі користувач прямо просить економити, а usage-полл кожні 3 хв — помітний
  постійний фон.
- **Thermal pressure** — `ProcessInfo.thermalState` не використовується.
- **User-idle (HID)** — часу без вводу ніде не міряємо. Єдиний проксі «користувача немає» — стан
  екрана та наявність процесу `claude`.
- **On-battery / metered для поллінгу** — дані вже зібрані (див. вище), але до каденції не
  підключені. Дешевий важіль, якщо колись постане питання економії трафіку на роздачі.

## Розходження коду з документацією

[`docs/design/awaiting-input-refresh.md`](../design/awaiting-input-refresh.md) описує гейт
«feature-enabled AND screen-unlocked AND claude-running» як частину дизайну, і docstring самого
`AwaitingInputWatcher` повторює це твердження. **У коді реалізована лише перша умова.** Тип підтримує
потрібний режим через `setActive(_:)`, але єдиний кол-сайт —
[`App.swift:1721-1744`](../../Sources/TokenPace/App.swift) — вмикає вотчер беззастережно.

Тікет: [#275](https://github.com/artem-from-ua/tokenpace/issues/275). До його закриття вважай
таблицю вище єдиним достовірним описом, а design-doc — планом.

Дрібніше: docstring [`UpdateInstallPlan`](../../Sources/TokenPaceKit/UpdateInstallPlan.swift) називає
`autoInstallEnabled` «default-OFF via `PersistedConfig`», хоча фактично ключ
`installUpdatesAutomatically` читається як `?? true` — тобто **opt-out**, а не opt-in. Коментар
застарів; поведінка правильна, помилковий лише опис.
