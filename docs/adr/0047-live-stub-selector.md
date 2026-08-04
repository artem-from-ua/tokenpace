---
status: accepted
date: 2026-07-30
---

# ADR-0047: Живий селектор стубів — перебудова polling-engine у рантаймі

## Контекст

Стуб-сценарії (`TOKENPACE_STUB=…`) — головний спосіб верифікації UI-станів: ~24 канонічні кадри
(`climbing`, `both-red`, `credits-active`, `reset-grace`, …). Активний сценарій читався з середовища
**один раз при старті** (`AppDelegate.stubName`) і «запікався» у транспорт: великий `switch` у
`startPolling` (~24 кейси) конструював `StubUsageTransport(mode:)`, а вибір token-provider/refresher
теж робився з `stubName`. Побачити інший сценарій означало **вбити застосунок і перезапустити** з
іншою env-змінною. Це болісно за наявності color-tuner (#185), який хочеться ганяти по різних рівнях
pacing без рестарту.

Мета (#187): додати в те саме dev-only вікно **Development tools…** (з #185) випадайку, що перемикає
джерело даних наживо — menu-bar іконка й popup оновлюються протягом одного циклу полінгу.

Це не суто UI: активний сценарій вплетений у побудову `PollingEngine`, а engine недоступний для правки
after-the-fact.

## Розглянуті варіанти

1. **Обгортка `SwitchableUsageTransport`.** Незмінний зовні транспорт із мутабельним «внутрішнім»
   стубом; swap міняє внутрішній і шле `.manualRefresh`. Але перемикання сценарію змінює **не лише
   транспорт**: token provider (`StubTokenProvider` vs `KeychainTokenProvider`/`ExpiredStubTokenProvider`)
   і refresher (`nil` vs `ClaudeCLIRefresher`) теж. Вони — незмінні `let` на `PollingEngine`, поза
   тим самим seam'ом. Обгортка накрила б лише транспорт → на кожному переході stub↔реальна-мережа
   все одно потрібен повний teardown. Додає тип і складність, не усуваючи teardown.
2. **Перебудова engine (обране).** `pollTask?.cancel()` + повторна побудова блоку engine із новим
   сценарієм, тоді `.manualRefresh` для негайного полу.

## Рішення

**Перебудовувати весь `PollingEngine` при перемиканні** — виділено `buildAndRunEngine(for:)`, спільний
для старту й live-swap. Він тягне транспорт/провайдер/refresher зі **`StubScenario`** і запускає новий
`pollTask`. `switchScenario(_:)` (кличе випадайка) робить teardown+rebuild і форсить `.manualRefresh`.

**`StubScenario` — єдине джерело істини.** Новий `CaseIterable`-реєстр (за зразком `ColorRole`, 0046):
`rawValue` кожного кейса — точний `TOKENPACE_STUB`-id (`"1"`, `"both-red"`, …), тож
`StubScenario(rawValue:)` дає env-сумісність безкоштовно; `displayName`/`summary` — підписи для
випадайки; `makeTransport()` згортає колишній ~24-кейсовий `switch`. І launch-шлях
(`launchScenario = StubScenario(rawValue: env ?? "") ?? .realNetwork`), і випадайка читають один реєстр
— **немає дубльованого списку кейсів** (критерій приймання). Описи (вимога мейнтейнера) живуть на
`summary`, поряд із маппінгом на `Mode`, тож не розсинхронізуються.

**`SignalHub` видає свіжий стрім на кожен engine.** `AsyncStream` — **single-consumer**: після того як
перший engine почав споживати `signals.stream`, новий scheduler на тому самому стрімі сигналів не
отримає. `SignalHub.newStream()` створює новий `AsyncStream`+continuation, завершує попередній і
перемикає `send(_:)` на актуальний continuation (під `NSLock`). Спостерігачі (`WorkspaceSleepWake`,
`ScreenLockObserver`, `NetworkMonitor`) шлють у `send` не переймаючись, який engine активний — завжди
дістають чинний continuation. Це найтонша деталь: без неї live-swap мовчки перестав би реагувати на
sleep/wake/network.

**Гейт — той самий `TOKENPACE_DEVTOOLS`, що й у 0046.** Випадайка живе у вже-гейтованому вікні; поза
dev-tools реєстр інертний (launch-шлях далі читає env для мейнтейнерських прогонів). Bridge
window→app — closure `onStubChange` (дзеркалить `ColorStore.onChange`); app→window —
`setCurrentScenario(_:)` для передвибору активного сценарію (в т.ч. заданого через env).

## Наслідки

- **+** Перемикання ~25 станів у місці, без рестарту — швидша візуальна верифікація, зручний прогін
  color-tuner по рівнях pacing.
- **+** Один реєстр `StubScenario` замість inline-switch + розкиданих коментарів; описи й маппінг —
  поряд.
- **+** Свіжий `StubUsageTransport` на кожен вибір природно скидає лічильник `calls`, тож
  послідовнісні сценарії (`stale-error`, `reset-grace`, `optimistic-reset`, `just-unblocked`)
  відтворюються з полу №1 при повторному виборі.
- **−** Кожен swap рве й перебудовує engine + `pollTask` (не найлегша операція), але трапляється лише
  при dev-виборі; на нормальному запуску шлях незмінний (один `buildAndRunEngine` на старті).
- **−** `SignalHub` став `@unchecked Sendable` з `NSLock` навколо continuation (був `let stream`);
  плата за коректну повторну підписку.
- Правило: додаючи стуб-сценарій — додай кейс у `StubScenario` (rawValue = env-id, `displayName`,
  `summary`, `makeTransport`) і онови перелік у `docs/guides/ui-verification.md`. Inline-switch більше
  немає — все проходить через реєстр.

## Постскриптум: env-резолюція більше не веде в живу мережу (#267)

Рішення чинне — реєстр і випадайка й далі читають одне джерело, — але сам однорядковий маппінг,
процитований вище (`launchScenario = StubScenario(rawValue: env ?? "") ?? .realNetwork`), виявився
небезпечним і замінений.

`init?(rawValue:)` дає `nil` на будь-якому рядку поза реєстром, а `?? .realNetwork` цей `nil` мовчки
схлопував у «нема стуба». Оскільки `case realNetwork = ""` і був id живої мережі, **«нічого не
задано» і «задано нісенітницю» ставали нерозрізненними**: помилка в одну літеру (`TOKENPACE_STUB=healthy`
замість `all-green`) перемикала застосунок у повністю живий режим — справжній Keychain, реальні
запити, живі `~/.claude`-дерева, — і при цьому виглядала як звичайний стубовий прогін.

Що змінилось:

- `realNetwork` дістав непорожній id — **`"real"`**. Живу мережу тепер треба просити на імʼя;
  порожній рядок перестав бути валідним id.
- Резолюція винесена в `StubResolution` (`TokenPaceKit`, чисте ядро за ADR-0009) і покрита тестами;
  `StubScenario.resolve(env:isAppBundle:)` — тонка обгортка над нею.
- Невідоме значення (і порожнє) деградує в **`screenshot`**, а не в live, і пише `.notice` зі списком
  валідних id. Дефолт у dev-збірці — теж `screenshot`; встановлений `.app` без env лишається живим.
- Резолюція повертає ще й ознаку «вибір був явний», яку читає гейт awaiting-input watcher'а
  (див. постскриптум в ADR-0066).

Правило з «Наслідків» доповнюється: id нового кейса має бути **непорожнім і унікальним** —
`StubResolution.idsAreResolvable` перевіряє це `assert`-ом на `validIDs`.
