# Архітектура — сервіси, конфіг і Settings

Наскрізна картина — в [overview.md](overview.md). Тут — другий незалежний потік (статус сервісів
Claude), monitored-services конфіг, persistence/міграція, вікно Settings, архіватор логів і вікно
Troubleshoot.

## Статус сервісів Claude (#31)

Другий, незалежний від usage потік: на кожен `PollOutput`, коли `StatusCadence.isDue` (інтервал =
`max(5 хв, usage-інтервал)`), агент ходить у `status.claude.com/api/v2/summary.json`, декодує лише
`components[]`, зводить у логічні сервіси (`MonitoredServices`) і малює по рядку на монітований
компонент у popup — **лише** коли є проблема. Найсерйозніша проблема → одна крапка в menu bar.

## Вікно Troubleshoot (ADR-0020)

⌥-Option-гейтований пункт «Troubleshoot…» відкриває велике resizable-вікно `.normal`-рівня з
live-оновленням щополу: update interval + токен (read/expires) + сира відповідь usage API
(претіфікований JSON / payload помилки + HTTP-статус + timestamp). Діагностика тече чистим
`PollDiagnostics` пайплайном.

## Компоненти статусу сервісів

| Компонент | Відповідальність |
|---|---|
| **StatusHealth / StatusSummary** | Чисте ядро статусу сервісів (#31, #89; `TokenPaceKit`). `StatusSummary` парсить **лише** `components[]` — `incidents`/`status` навмисно НЕ декодуються (ADR-0013), тож «відомі виключення» не шумлять. `ServiceStatus` мапить сирий рядок → семантику (+ `severity`/`isProblem`). `StatusHealth` — колекція **логічних сервісів** `checks: [ServiceCheck]` (ADR-0024): кожен = `ServiceID` + `coworkEnabled` + `[ResolvedComponent]` + computed `status` = worst-of-N. `worstProblem` → найсерйозніший стан усіх увімкнених (сигнатура `ServiceStatus?` збережена). ADR-0013, ADR-0024 |
| **MonitoredServices** | Чистий Codable value-конфіг «які логічні сервіси моніторити» (#89, ADR-0024): `claudeCodeEnabled`/`webDesktopEnabled` + `WebDesktopMode` (`chatOnly`/`chatAndCowork`). `Claude API` завжди-on, не конфігурується. Forward-compat декод (невідомий режим → `.chatOnly`). `static default` = обидва on, `chatOnly` |
| **StatusClient** | HTTP-seam status-ендпоінта (`TokenPaceKit`), дзеркало `UsageClient`: чисті `buildRequest()` (обов'язковий `User-Agent`, без auth) / `decode(from:)` окремо від `fetch(transport:)`. Будь-який збій → `StatusFetchError` → shell робить `StatusHealth.unknown` — **не** ескалює usage 429-backoff. ADR-0013 |
| **StatusCadence** | Чистий seam ввічливої частоти (`TokenPaceKit`): `interval = max(floor, usageInterval)`. Без власного таймера — хантажиться з usage-tick. **Дві підлоги:** `floor` = 5 хв (все operational); `problemFloor` = 60 с (щойно є проблема). ADR-0013 |

## Persistence, міграція, Settings, архіватор

| Компонент | Відповідальність |
|---|---|
| **PersistedConfig** | Перший persistence-шар (#71, ADR-0023) — тонка `@MainActor`-обгортка над `UserDefaults.standard`. Фаза 1 почалась з `lastRunVersion`; шов розширено ключами: `calmMenuBarColors` (#105), `resetCountdownModeMenuBar` (#103), `showServiceStatusDot` (#31), `showExtraUsage` (default-ON, #144/#146), monitored services (#89), `automaticUpdateChecks` (#37), архіватор (`archiveEnabled`/`archiveDestination`/`lastArchiveSync`, #110). Рішення про міграцію — у чистому `MigrationPlan`. ADR-0023 |
| **MigrationPlan** | Чистий предикат on-launch міграції конфігу (#71, ADR-0023): `transition(stored:current:)` → `firstRun`/`unchanged`/`upgraded(from:to:)`. Порівняння — рядкова нерівність (каркас); повний SemVer-compare відкладено. Реюз у Фазі 2 |
| **LaunchAtLogin / LaunchAtLoginController** | Чисте ядро (#14): `Status` — framework-free дзеркало `SMAppService.Status` + предикати `shouldAttemptRegister` (opt-out на `.notRegistered` **і** `.notFound`, #69). Shell-glue над `SMAppService.mainApp`: `enable()`/`disable()`, `isAppBundle` (гейт opt-out auto-register лише на `.app`, #69). ADR-0012, ADR-0018 |
| **SettingsWindowController** | Вікно «Settings…» (#14, редизайн #131 ADR-0035): single-instance `NSWindowController` з `SettingsSplitViewController` (sidebar + detail, стиль System Settings). 5 секцій grouped-inset-карток: **General** (launch-at-login, screen-lock pause #114), **Menu Bar** (calm colors #105, hide-calm-7d #94, reset-countdown radios #103, service dot #31, extra-usage credits icon #146), **Monitored Services** (#89, ADR-0024), **Session Logs** (архіватор #110, ADR-0031), **About/Updates** (#37: «Check for updates daily», «Check Now», update-рядок). Панелі — eager (`buildAllPanes`), бо `updateAvailability`/`updateArchiveStatus` кличуться з фону. ADR-0012, 0018, 0024, 0031, 0035 |
| **SettingsSplitViewController / SettingsSidebarController** | Split-каркас редизайну (#131, ADR-0035): `NSSplitViewController` із незгортаним sidebar + detail; `[Section]`-дескриптори (title + SF-Symbol + tint + builder), кеш панелей. Sidebar — source-list `NSTableView` із кольоровим SF-Symbol-чипом. ADR-0035 |
| **SettingsCard / DividerView / SettingsRow / FlippedView** | Grouped-inset-примітиви (#131, ADR-0035): layer-backed картка (`cornerRadius` 10, `addRow`/`setRow(_:hidden:)`), inset-hairline (`1/backingScaleFactor`), enum-фабрика рядків, top-origin flipped-документ. CGColor перевстановлюється в `updateLayer()` (dark/light). ADR-0035 |
| **ArchiveSyncPlan / ArchiveCadence / LogArchiver** | Архіватор логів сесій (#110, ADR-0031). Чиста `filesToCopy(source:dest:)` — новий/змінений файл (mtime **або** розмір: дописаний `.jsonl` росте), **ніколи не повертає видалень** (accumulate-only). `ArchiveCadence` — фіксовані 24 год, маркер лише на успіху. `LogArchiver` (I/O-shell) дзеркалить allow-list тек `~/.claude/` (`projects/`/`file-history/`/`plans/`) — allow-list гарантує, що `.credentials.json`/токени фізично не потраплять в архів. Повертає `Summary`. ADR-0031 |
| **ByteSize** | Чистий форматер розміру (#110, `TokenPaceKit`): `humanReadable(_:)` → ціле + бінарна одиниця, **без десяткових/локалі** (навмисно не `ByteCountFormatter`, що локалізує). Для рядка стану архіву |
| **TroubleshootLayout / JSONHighlighter / TroubleshootWindowController** | Вікно Troubleshoot (ADR-0020). `TroubleshootLayout.make(...)` → рядки трьох секцій (update interval / токен / usage-API) вичерпним `switch` над `FetchDiagnostics.Outcome`; `prettyPrinted`/`timestampText`/`durationText`. `JSONHighlighter` — контекстний токенайзер JSON (не regex — пам'ятає контекст ключ↔value, не рве на `\"`). `TroubleshootWindowController` — resizable `.normal`-вікно (не `.floating` — конфлікт із fullscreen), read-only monospace `ReadOnlyTextView`, «Refresh now» → `forceRefresh`, copy body → `NSPasteboard`. Live-оновлення щополу. ADR-0020 |
