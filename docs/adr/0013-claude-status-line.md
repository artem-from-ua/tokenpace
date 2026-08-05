---
status: superseded
date: 2026-06-23
superseded_by: [0024, 0071]
---

# ADR-0013: Рядок статусу сервісів Claude у попапі (status.claude.com)

> **Superseded у частині обсягу** [ADR-0024](0024-configurable-logical-services.md): «рівно два
> фіксовані компоненти `Claude Code` + `Claude API`» замінено конфігурованими логічними сервісами
> (issue #89). Решта рішень нижче (джерело стану = лише `component.status`, інциденти не декодуються,
> cadence-підлоги, чисте ядро / тонкий shell) **лишається чинною** і реюзується ADR-0024.
>
> **Додатково переглянуто §2** [ADR-0071](0071-incident-subscriptions.md) (draft): `incidents[]`
> **тепер декодуються** — але лише як *контекст* і *об'єкт підписки*. Ядро §2 **лишається чинним**:
> джерелом стану сервісів і надалі є виключно `components[].status`; жодне поле інциденту
> (`status`, `impact`, `resolved_at`) на стан не впливає.

## Контекст

Issue #31 додає у попап рядок зі станом сервісів Claude зі сторінки
[status.claude.com](https://status.claude.com). Мета — відповісти на питання користувача «мій Claude
Code тупить — це я (ліміт/мережа) чи Anthropic?»: усе про використання попап уже показує, бракувало
другої половини — стану самих сервісів.

Джерело — JSON-ендпоінт Statuspage.io
`https://status.claude.com/api/v2/summary.json`, що віддає `status` (overall `indicator`/
`description`), `components[]` (`name` + `status`: `operational` / `degraded_performance` /
`partial_outage` / `major_outage` / `under_maintenance`), `incidents[]` (`name`, `status`,
`impact`, `components[]`) та `scheduled_maintenances[]`.

Постає той самий клас рішень про межі модуля, що в
[ADR-0008](0008-usageclient-pure-backoff-and-transport-seam.md),
[ADR-0010](0010-usage-health-and-error-states.md),
[ADR-0011](0011-polling-engine-adaptive-cadence-and-signal-seams.md): де живе парсинг/маппінг, як
зробити його тестованим без живої мережі, і як накласти **друге** джерело даних, не зчепивши його з
usage-поллінгом.

1. **Які компоненти дотичні до консольного Claude Code.** Тікет просив дослідити. `Claude Code` —
   інфраструктура продукту CLI (логін, апдейтер, роутинг моделей); `Claude API (api.anthropic.com)`
   — бекенд інференсу, куди CLI шле кожен запит (помилки `5xx`/`429`/`529` у CLI = деградація саме
   його, [docs](https://code.claude.com/docs/en/errors)). Решта (`claude.ai`, `Claude Console`,
   `Claude Cowork`, `Claude for Government`) до консольного CLI прямо не дотичні.
2. **Сигнал стану vs інциденти.** Перевірено вручну: компонент і інцидент можуть розходитися — обидва
   наші компоненти бувають `operational`, тоді як активний `major` інцидент перелічує їх у
   `components[]` (реальний кейс: призупинення доступу до Mythos 5 / Fable 5). Треба вирішити, що є
   джерелом істини для рядка.
3. **Cadence.** Це **інше** джерело, ніж usage API. Тікет прямо вимагав «окремий, **ввічливий**
   інтервал — не плутати з cadence usage». Status.claude.com — сторонній сервіс.

## Рішення

1. **Обсяг — два компоненти: `Claude Code` + `Claude API (api.anthropic.com)`.** Будь-який може
   лежати окремо (зламаний логін/роутинг при робочому API, або навпаки), тож обидва релевантні для
   відповіді «чи це Anthropic». Витягуються за **точним іменем** із `components[]`; відсутній
   компонент (Anthropic перейменувала/прибрала) → `unknown`, а не мовчазний `operational`.

2. **Джерело стану — ВИКЛЮЧНО `component.status` цих двох компонентів. Інциденти / overall /
   scheduled_maintenances НЕ декодуються взагалі.** Це навмисно й має три переваги: (а) збігається з
   кольором, який Statuspage показує біля компонента на самій сторінці; (б) автоматично ховає
   «відомі виключення» на кшталт призупинення Mythos/Fable — інцидент `major`, але компоненти
   лишаються `operational`, тож попап показує `operational` без жодного спецкоду; (в) тримає
   `StatusSummary` вузьким (одне поле `components`), без коду навколо інцидентів. `Decodable`
   ігнорує немодельовані ключі безкоштовно.

3. **Вигляд — завжди два незалежні рядки, по одному на компонент, з кольоровою крапкою-індикатором.**
   Без агрегації в «overall», без згортання: `● Claude Code: operational` / `● Claude API:
   operational`. Колір крапки = статус саме цього компонента
   (`зелена/жовта/помаранчева/червона/синя/сіра`). Маппінг `status → крапка + слово` — у view
   (`PopupViewController`, точка локалізації, ADR-0009), `CCTimerKit` несе лише семантичний
   `ServiceStatus`.

4. **Слово стану — клікабельне посилання на `https://status.claude.com`, але ЛИШЕ коли стан не
   `operational`.** На operational-рядку слово — звичайний secondary-текст без лінку (на
   статус-сторінці нема на що дивитися); на будь-якій деградації/maintenance/unknown слово стає
   лінком на статичну головну сторінку (не shortlink інциденту — інциденти ми не парсимо). Клік
   відкриває браузер. Оскільки `.link`-обробка `NSTextField` ненадійна всередині `NSMenu`-hosted
   view, клік обробляється явно (`StatusLineLabel.mouseDown` по діапазону слова + курсор-рука лише
   за наявності лінку).

5. **Холодний старт → рядків немає; збій нашого fetch → обидва `unknown` (сіра крапка).** Доки немає
   першої успішної відповіді — статус-рядки не показуються (`serviceStatus == nil`). Якщо наш запит
   до status-сторінки впав (мережа/decode), shell підставляє `StatusHealth.unknown` — чесне «не
   знаємо», а не брехливе `operational`. UI для «сервіс unknown» і «ми не змогли дізнатися» однаковий,
   тож тип не несе окремого failure-поля.

6. **Чисте ядро в `CCTimerKit` + тонкий glue — дзеркало `UsageClient`/`UsageHealth`.**
   `StatusSummary` (Decodable), `ServiceStatus`/`StatusHealth` (семантичний маппінг, без
   локалізованих рядків), `StatusClient` (`buildRequest`/`decode`/`fetch`, реюз seam'а
   `UsageTransport`, обов'язковий `User-Agent: claude-code/<version>`). HTTP-запит і таймер — у shell.
   Тести підставляють stub-transport і фікстуру `summary.json` (із інцидентом усередині — щоб
   довести, що зайві ключі ігноруються).

7. **Cadence підв'язана до usage-tick із підлогою ввічливості, а не окремий таймер.** Інтервал
   статусу = `max(floor, поточний usage-інтервал)` (`StatusCadence.interval`). На кожен `PollOutput`
   shell питає `StatusCadence.isDue(...)` і фетчить лише коли пора. Так статус **слідує** за usage,
   коли той повільний (простій/неактивність → 30 хв, обидва затихають разом), але **ніколи** не
   частіше за `floor`, навіть коли usage молотить раз на 60 с чи в 429-backoff — це й є «ввічливість»
   до стороннього сервісу. Статус **не** має власного 429-backoff і **не** впливає на usage-cadence:
   `StatusFetchError` ловиться в shell і ніколи не ескалює usage-поллінг.
   **Дві підлоги:** `floor = 5 хв` коли все operational; `problemFloor = 60 с` (наш загальний
   `minInterval`), щойно будь-який компонент **не** operational — під час інциденту сторінку варто
   стежити пильно (ескалація/відновлення стаються на хвилинній шкалі), тож підлога опускається, щоб
   швидко зловити зміну. `isDue(... hasProblem:)` отримує цей прапорець від останнього відомого стану.

8. **Кольоровий індикатор у menu bar — найлівіший елемент віджета, лише за проблеми.**
   `StatusHealth.worstProblem` повертає найсерйозніший зі станів двох компонентів (severity-порядок:
   operational < maintenance < unknown < degraded < partial < major) або `nil` коли обидва
   operational. `MenuBarLayout` несе це як `serviceProblem: ServiceStatus?` (ортогонально до `mode`);
   `StatusItemView` малює маленьку кольорову крапку зліва від смужок/гліфа, зсуваючи решту вправо.
   `nil` (усе ОК / холодний старт) → крапки немає. Колір — фіксований sRGB (image non-template):
   жовтий/помаранчевий/червоний/синій/сірий. `unknown` теж показує крапку (сіру) — чесно сигналить
   «не знаємо», не ховаючи стан.

## Наслідки

- `CCTimerKit` лишається без AppKit/Network: `StatusSummary`/`ServiceStatus`/`StatusHealth`/
  `StatusCadence`/`StatusClient` оперують лише семантикою й `Foundation`; платформенний бік
  (`URLSession`, таймінг) — у `cc-timer`. Маппінг і cadence покриті unit-тестами
  (`StatusHealthTests`, `StatusClientTests`, `StatusCadenceTests`); рядок-лінк перевіряється E2E
  через `CC_TIMER_STUB=1` (стаб віддає деградований API + інцидент — показує жовту крапку й доводить,
  що інцидент ігнорується).
- Два джерела даних ортогональні: usage-поллінг (ADR-0011) і статус-поллінг ділять `SignalHub`-ритм
  (статус хантажиться з usage-tick), але мають окремі стани, окрему обробку помилок і незалежні
  cadence-підлоги. Збій одного не зачіпає інший.
- Якщо у Фазі 2 знадобиться показ інцидентів, історія, або статус у menu-bar (не лише в попапі) —
  нове рішення → нова секція тут або окремий ADR. Поточне свідомо мінімалістичне: лише per-компонентний
  `status`.

## Пов'язані

- [ADR-0008](0008-usageclient-pure-backoff-and-transport-seam.md) — `UsageClient`/`UsageTransport`; `StatusClient` дзеркалить його структуру й реюзає transport-seam.
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — чисте ядро / тонкий shell, локалізація у view; рядок статусу слідує тому ж поділу.
- [ADR-0010](0010-usage-health-and-error-states.md) — `UsageHealth`/`FailureReason`; `StatusHealth` — його аналог для статус-домену.
- [ADR-0011](0011-polling-engine-adaptive-cadence-and-signal-seams.md) — usage-поллінг, із якого статус бере свій heartbeat і поточний інтервал.
