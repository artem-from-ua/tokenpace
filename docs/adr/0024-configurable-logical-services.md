---
status: accepted
date: 2026-07-23
---

# ADR-0024: Конфігуровані логічні сервіси статусу замість двох фіксованих компонентів

> Замінює [ADR-0013](0013-claude-status-line.md) у частині обсягу («рівно два фіксовані компоненти
> `Claude Code` + `Claude API`»). Решта ADR-0013 (джерело стану = лише `component.status`, інциденти
> не декодуються, cadence-підлоги, чисте ядро/тонкий shell) лишається чинною.

## Контекст

[ADR-0013](0013-claude-status-line.md) §1 навмисно зашив обсяг у **два фіксовані компоненти**
status.claude.com — `Claude Code` + `Claude API (api.anthropic.com)` — як поля `claudeCode`/
`claudeAPI` структури `StatusHealth`, з `worstProblem` = worst-of-2 по них.

Issue #89 робить набір **конфігурованим**: користувач у вікні Configure… обирає, які логічні сервіси
моніторити. Під час уточнення вимог модель спростилася відносно початкового формулювання тікета
(замість «один перемикач `Claude Code` на два компоненти worst-of-two»):

```
[x] Claude API          ← сірий, ЗАВЖДИ on, не редагується   → монітор: "Claude API (api.anthropic.com)"
[x] Claude Code                                              → монітор: "Claude Code"
[x] Claude WEB/Desktop                                       → монітор: "claude.ai"
    (o) Chat only
    ( ) Chat and Cowork                                      → додає:  "Claude Cowork"
```

Постають рішення: як представити «логічний сервіс = група з 1–2 компонентів із worst-of-N кольором»,
де живе конфіг, як менюбар-крапка агрегує кілька сервісів, і як не зламати всіх споживачів
`StatusHealth`, зберігши поділ чисте-ядро/тонкий-shell (ADR-0009/0013).

## Рішення

1. **`StatusHealth` переходить від фіксованої пари полів до колекції `checks: [ServiceCheck]`.**
   Кожен `ServiceCheck` = семантичний `ServiceID` (`claudeAPI`/`claudeCode`/`webDesktop`) +
   `coworkEnabled` + `[ResolvedComponent]` (поіменні складові з їхнім `ServiceStatus`) + computed
   `status` = **worst-of-N** по складових через наявний `ServiceStatus.severity` (без нової
   severity-логіки). Це узагальнює ADR-0013 §3 (per-компонентний стан) до груп.

2. **`Claude API` — незмінний, завжди-увімкнений сервіс, не частина конфігу.** Він завжди перший
   `check`, безумовно — бо від нього залежить спроможність самого TokenPace викликати usage API.
   Тому **порожнього стану немає**: status.claude.com опитується завжди (щонайменше заради Claude
   API), і acceptance-критерій початкового тікета «обидва off → не опитувати» **не діє**. У
   `MonitoredServices` немає прапорця для Claude API — нема чого зберігати.

3. **Конфіг — `MonitoredServices` (чистий Codable value-тип у `TokenPaceKit`).** Два прапорці
   (`claudeCodeEnabled`/`webDesktopEnabled`) + `WebDesktopMode` (`chatOnly`/`chatAndCowork`). Обидва
   типи `Codable` заради персистентності (ADR-0023: shell `PersistedConfig` тримає їх як JSON у
   `UserDefaults`; kit лише описує форму). `WebDesktopMode` — raw-value `String` (`"chat_only"`/
   `"chat_and_cowork"`) зі стабільними ключами, і forward-compat `init(from:)` (невідомий режим →
   `.chatOnly`), як `ServiceStatus.unknown`. `MonitoredServices.init(from:)` декодує кожен ключ через
   `decodeIfPresent` + дефолт (частковий/старий blob → дефолти, не падіння), як `StatusSummary`.

4. **`from(_:config:)` і `unknown(for:)` замість `from(_:)` і `static let unknown`.** Обидва будують
   `checks` через один приватний хелпер `checks(for:statusOf:)` — єдине джерело істини про те, які
   сервіси/складові існують за конфігом; різняться лише джерелом статусу (summary vs константа
   `.unknown`). Старий безпараметричний `from(_:)` прибрано (поля `claudeCode`/`claudeAPI` зникли),
   тож тести переписані на `checks`.

5. **Менюбар-крапка — одна, worst-of-all-enabled.** `StatusHealth.worstProblem` тепер найсерйозніший
   non-operational стан серед **усіх** складових **усіх** увімкнених сервісів (з Cowork лише в режимі
   `chatAndCowork`), або `nil`. **Сигнатура не змінилася** (`ServiceStatus?`) — тож `MenuBarLayout`,
   `StatusItemView`, `StatusCadence` і status-loop у `App` не чіпаються. Це свідомий вибір проти
   «крапка на кожен сервіс» (ширший віджет, поза обсягом): popup вже розрізняє сервіси по рядках.

6. **Popup рендерить один рядок на КОМПОНЕНТ, не на сервіс.** У dropdown кожен монітований компонент
   — окремий рядок зі своїм статусом і кольоровою крапкою: `API` завжди, далі `Code`, `WEB/Desktop`,
   і `Cowork` (коли режим `chatAndCowork`) — за увімкненими сервісами. Тобто WEB/Desktop у Cowork дає
   **два окремі рядки** (`WEB/Desktop` + `Cowork`), а не один згорнутий «with Cowork». Це свідомий
   вибір користувача: кожна складова читається окремо, без агрегації в popup. Заголовок секції popup
   — **«Claude»** (був «Claude Code»).

7. **Display-назви компонентів — у view, matching-назви — у kit** (ADR-0009/0013 seam). View мапить
   `ResolvedComponent.name` (kit-константа) на коротку мітку в `PopupViewController.displayName(_:)`:
   `Code` / `API` / `WEB/Desktop` / `Cowork` — **без «Claude»-префікса** (він у заголовку секції),
   невідома назва → сама назва (forward-safe). Matching-константи в kit стали `public`, щоб view
   робив цей мапінг за іменем компонента. **⌥-розгортання прибрано** — кожен рядок атомарний
   (один компонент), тож немає чого розгортати. Правило показу з ADR-0013 збережено: статус-рядки
   з'являються лише за реальної проблеми (`worstProblem != nil`); Claude API не робиться «завжди
   видимим» у popup. `ServiceCheck` лишається в моделі (несе `id`/`coworkEnabled`/`components` +
   computed worst-of-N `status`), але popup тепер ітерує по `components` напряму; worst-of-N живе для
   менюбар-крапки (`worstProblem`, worst-of-all по всіх компонентах).

## Наслідки

- `TokenPaceKit` лишається без AppKit: нові `ServiceID`/`ResolvedComponent`/`ServiceCheck`/
  `MonitoredServices` — семантика + `Foundation`. Маппінг і worst-of-N покриті unit-тестами
  (`StatusHealthTests` переписані на `checks`; `MonitoredServicesTests` — defaults, Codable
  round-trip, forward-compat декод). Settings-UI і персистентність — manual-verify (shell).
- **Зачеплення мінімальне завдяки збереженню `worstProblem: ServiceStatus?`**: реальні зміни —
  `StatusHealth` (модель), `PopupViewController` (ітерація + `displayName` + ⌥-підрядки),
  `from`-виклики та нове поле конфігу в `App`, `SettingsWindowController` (секції General/Monitored
  services), `PersistedConfig` (+ключ `monitoredServices`). `StatusClient`/`StatusSummary`/
  `StatusCadence`/`MenuBarLayout`/`PollingEngine` — без змін.
- **Зміна конфігу застосовується наживо**: `AppDelegate.monitoredServicesChanged` скидає застарілий
  `lastStatusHealth`, форсує негайний re-poll (через `.manualRefresh`-heartbeat) і перемальовує — щоб
  крапка/рядки відповідали новому набору сервісів у межах моменту.
- **ADR-0013 частково superseded** (обсяг двох фіксованих компонентів); його запис лишається
  незмінним, у README номер/назву закреслено, frontmatter → `superseded`, зверху — постскрипт на цей
  ADR. Решта рішень 0013 чинні й тут реюзуються.

## Пов'язані

- [ADR-0013](0013-claude-status-line.md) — попереднє рішення (два фіксовані компоненти), superseded у
  частині обсягу; джерело стану / cadence / seam-поділ звідти чинні.
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — чисте ядро / тонкий shell,
  локалізація у view; display-назви сервісів слідують тому ж поділу.
- [ADR-0023](0023-persisted-config-version-marker.md) — persistence-шар (`PersistedConfig`), який
  `MonitoredServices` розширює своїм ключем.
- Issues: #89 (цей тікет), #31 (початковий рядок статусу), #71 (persistence-фундамент).
