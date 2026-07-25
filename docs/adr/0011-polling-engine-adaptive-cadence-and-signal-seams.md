---
status: superseded
superseded_by: [0032]
date: 2026-06-22
---

# ADR-0011: PollingEngine — async-цикл, адаптивний інтервал і seam'и sleep/wake/мережі

> **Заміщено [ADR-0032](0032-simplified-polling-cadence.md).** Модель інтервалу спрощено: `AdaptiveCadence`
> прибрано, база стала пласкі 3 хв, idle-оверрайд — 15 хв (замість 30), а 429-backoff більше не ескалює
> `3→6→12→15 хв`, а лише honor'ить `Retry-After`. Async-цикл, seam'и (`PollScheduler`,
> `ClaudeActivityProbe`, `NWPathMonitor`, `NSWorkspace`), `minInterval` floor і принцип «лог лише при
> зміні» з цього ADR лишаються чинними — замінено саме *правила частоти*, не архітектуру циклу.

## Контекст

Issue #13 («Sleep/wake + мережа») замінює тимчасовий mock у `AppDelegate`
([ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) §«Наслідки») живим опитуванням
usage API. Обсяг тікета вимагає: позачерговий опит одразу після пробудження Mac, паузу під час сну,
stale-стан без падінь при втраті мережі з авто-відновленням, і логування цих подій. Користувач
додав вимоги до **частоти**: за відсутності запущених сесій Claude Code — рідкісний опит (30 хв);
за активної сесії — адаптація до того, чи **змінюються** дані (немає змін → сповільнюватись, є
зміни → опитувати частіше); і **окреме лог-повідомлення на кожне рішення про зміну інтервалу**.

Постає той самий клас рішень про межі модуля, що в
[ADR-0008](0008-usageclient-pure-backoff-and-transport-seam.md),
[ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md),
[ADR-0010](0010-usage-health-and-error-states.md): де живе логіка циклу, як зробити її тестованою
без живого часу/мережі/сну, і як накласти кілька правил частоти, не зчепивши їх у клубок.

1. **Цикл vs таймер.** `Timer`/`DispatchSourceTimer` тягнуть callback-світ і ускладнюють
   `@MainActor`-ізоляцію; кодова база вже повністю `async` (`UsageClient.fetch`, `UsageTransport`).
2. **Де живе цикл.** Якщо цикл сидить у `AppDelegate`, acceptance-критерії («після wake — одразу»,
   «offline → stale + авто-відновлення») перевіряються лише оком під `swift run`.
3. **Дві осі частоти + оверрайд.** 429-backoff (#9) уже існує; адаптація за вмістом і 30-хв
   оверрайд при неактивному Claude — нові, незалежні правила. Потрібна явна модель пріоритету.
4. **Виявлення мережі.** SPEC згадує лише `NSWorkspace` для sleep/wake, але «авто-відновлення
   одразу» при поверненні зв'язку вимагає окремого сигналу — інакше offline (не 429) не ескалює
   backoff і користувач чекає до повного інтервалу.

## Рішення

1. **Async-цикл `PollingEngine.run() -> AsyncStream<PollOutput>`, не таймер.** Очікування між
   опитами — інжектований seam `PollScheduler`, що гонить `Task.sleep(interval)` проти наступного
   `PollSignal`. `.wake`/`.networkRestored` обривають сон (позачерговий опит); `.sleep` паркує цикл
   (`waitWhileAsleep`) — під час сну fetch не виконується. Стрім споживає shell на `@MainActor`;
   сам engine **не** `@MainActor`, тож тести не тягнуть головний актор.

2. **`PollingEngine` у `CCTimerKit` з чистим ядром + seam'ами — як `PollingBackoff` у ADR-0008.**
   Уся логіка рішень — чисті, детерміновані (інжектований `now`) функції:
   `advance(previous:outcome:claudeActive:now:)` (перехід стану health/backoff/adaptive),
   `effectiveInterval(_:)` (обчислення інтервалу), `intervalDecision(previous:next:)` (причина зміни
   для логу). Залежності — протоколи-seam'и: `PollScheduler`, `TokenProviding`
   (+`KeychainTokenProvider`), `ClaudeActivityProbe`, наявний `UsageTransport`. Тести підставляють
   `ManualScheduler`/`StubProbe`/`StubTokenProvider`/`StubTransport` і проганяють обидва
   acceptance-критерії в ізоляції. Тонкий shell (`cc-timer`) лишає платформенні сайд-ефекти.

3. **Дві незалежні осі частоти + жорсткий оверрайд, з явним пріоритетом.** `effectiveInterval`:
   `429-backoff (PollingBackoff) > Claude-неактивний 30-хв оверрайд > адаптивний (AdaptiveCadence)`.
   - **`PollingBackoff`** (#9, незмінений) — реагує на 429; перекриває все, бо це вказівка сервера.
   - **`AdaptiveCadence`** (новий чистий тип) — реагує на **вміст**: `unchanged()` подвоює інтервал
     `3→6→12→15 хв` (та сама прогресія, що backoff — однаковий лагідний ритм у спокої),
     `changed()` миттєво скидає до 3 хв. «Зміна» = відрізняється `utilization` 5h **або** 7d
     (рішення користувача); перший успіх (немає попереднього снапшота) рахується зміною, тож старт —
     на швидкому полу.
   - **30-хв оверрайд** — немає сесії Claude Code → опитувати рідко, незалежно від адаптивного стану.

4. **Виявлення Claude Code через `ClaudeActivityProbe` (seam); продакшн — `sysctl(KERN_PROC_ALL)`.**
   Збіг за **точним ім'ям** виконуваного файлу `claude` (CLI, що споживає ліміти підписки), не за
   підрядком — щоб не давати хибнопозитив на Claude Desktop (його гелпери звуться «Claude Helper» і
   спливають лише при `-f` match по командному рядку). Без спавну `pgrep` (немає залежності від
   шляху). Будь-яка помилка sysctl → порожній набір → «неактивний» → консервативний 30-хв інтервал.

5. **Мережа — окремий `NWPathMonitor` для сигналу, не друге джерело істини.** Перехід
   `.unsatisfied → .satisfied` дає `.networkRestored` → позачерговий опит (авто-відновлення за
   секунди, а не за повний інтервал). Монітор **не** будує health і **не** вирішує stale — це й далі
   походить лише від результату `fetch` (`UsageError.transport → FailureReason.network → failingSince`
   → фази menu bar 30/60 хв з ADR-0010). Offline-опит не падає: `fetch` повертає типізований
   `UsageError`, `advance` зберігає `lastSnapshot` (stale), backoff **не** ескалює (це не 429).

6. **Token-помилка не йде в мережу і не чіпає інтервали.** Протухлий/відсутній токен
   ([ADR-0007](0007-token-provider-throws-and-scope-split.md): stale-токен = гарантований 401 +
   спалення rate-limit) → `pollOnce` пропускає fetch, `advance` лише фіксує невдачу
   (`FailureReason(TokenError)`), не ескалюючи ні backoff, ні adaptive — щоб щойно Claude Code
   перепише свіжий токен, наступний опит його підхопив.

7. **Кожне рішення про зміну інтервалу логується з причиною; лише при реальній зміні.**
   `intervalDecision` повертає `nil`, коли інтервал не зрушив — той самий принцип «лог/перемалювання
   лише при зміні», що `StatusItemView.layout` (ADR-0009 §8), без спаму. `AppLogger.lifecycle`
   несе `.public`-рядок (`interval 3m→6m: usage unchanged …`); токени не торкаються цього шару.

8. **Логи sleep/wake/мережі — сайд-ефект shell, не покриті unit-тестами** — як малювання в
   ADR-0009. OSLog важко асертити; натомість тестується чиста `intervalDecision` (правильність
   причини й «лише при зміні»), а факт логів sleep/wake/network перевіряється вручну (`log stream`).

9. **Два незалежні запобіжники від тісного циклу запитів — `LivePollScheduler` у `CCTimerKit`
   (тестований) + жорсткий `minInterval` floor.** Планувальник — єдине, що стримує частоту запитів,
   тож він **не** живе в shell-таргеті (недосяжному для тестів), а в `CCTimerKit`: залежить лише від
   `AsyncStream<PollSignal>` і `Task.sleep`, без AppKit/Network. Інваріант: `waitForNextPoll` чекає
   **весь** інтервал, доки не прийде справжній сигнал — порожній/завершений стрім ніколи не повертає
   миттєво (через `SignalGate`, що демультиплексує стрім і резюмить очікувача рівно раз: сигналом,
   дедлайном або finish). Незалежний другий рубіж — `effectiveInterval` ніколи не повертає менше
   `minInterval = 60 с` (нижче 180 с бази, тож нормальну роботу не сповільнює): навіть зламаний
   планувальник не дасть слати частіше. Покрито тестами `LivePollSchedulerTests`
   (`emptyStreamWaitsTheFullInterval`, `engineWithRealSchedulerStaysBounded`) і
   `MinIntervalFloorTests` (`everyIntervalCombinationRespectsFloor`).

   **Урок (регрес, що стався раз):** перша реалізація планувальника жила в shell-таргеті **без
   тестів** і гонила `Task.sleep` проти сирого `AsyncStream`-ітератора, що на завершеному стрімі
   повертав `nil → .elapsed` миттєво — `waitForNextPoll` повертався без паузи, і цикл слав ~50
   запитів/с, ігноруючи навіть `Retry-After: 145s`, аж до 429. Висновок зафіксовано конструктивно:
   найкритичніший для безпеки компонент **мусить** бути в тестованому ядрі, а частотні інваріанти —
   мати незалежний жорсткий рубіж (`minInterval`), не покладаючись на коректність планувальника.

## Наслідки

- Обидва acceptance-критерії покриті unit-тестами без живого часу/мережі/сну: `wake → негайний
  опит`, `sleep → park`, `offline → stale без падінь`, `networkRestored → негайний опит`,
  `recovery → failingSince=nil`. `AdaptiveCadence` і `intervalDecision` — табличні тести.
- `CCTimerKit` лишається без AppKit/Network/Darwin — `PollingEngine`/`AdaptiveCadence` оперують лише
  семантикою; платформенні seam'и (`LivePollScheduler`, `NWPathMonitor`, `NSWorkspace`, sysctl)
  живуть у `cc-timer`. Реюз у Фазі 2 (інша частотна політика — нове рішення → нова секція/ADR).
- Дві осі частоти ортогональні: 429 і вміст не плутаються, бо `effectiveInterval` має один порядок
  пріоритету, а `cause(...)` атрибутує зміну тій осі, що справді володіє новим інтервалом.
- `LivePollScheduler` гонить `Task.sleep` із сигнальним стрімом і скасовує програшну гілку
  (`group.cancelAll()`), щоб сплячий `Task.sleep` не накопичувався. Єдиний споживач ітератора
  сигналів читається строго послідовно (`SignalReader`, `nonisolated(unsafe)`).
- Якщо у Фазі 2 з'явиться кешування (`If-Modified-Since`) або інші пороги активності/інтервалів —
  нове рішення → нова секція тут або окремий ADR.

## Пов'язані

- [ADR-0007](0007-token-provider-throws-and-scope-split.md) — `TokenError`, чому stale-токен не йде на API.
- [ADR-0008](0008-usageclient-pure-backoff-and-transport-seam.md) — `PollingBackoff`, `UsageTransport`; цей ADR розгортає «*виконання* таймера — у polling-шарі».
- [ADR-0010](0010-usage-health-and-error-states.md) — `UsageHealth`/`FailureReason`; engine будує їх із результату опиту.
