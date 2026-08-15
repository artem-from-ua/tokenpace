# Документація TokenPace

Карта всієї документації проєкту. Почни звідси, якщо шукаєш, де що лежить.

Мова документації — українська (див. [ADR-0002](adr/0002-ukrainian-documentation.md)); код,
ідентифікатори й повідомлення комітів — англійська.

## Джерела істини

Чотири головні документи, з яких варто починати:

- [SPEC.md](../SPEC.md) — продуктовий спек: проблема, архітектура, UI, фази, монетизація.
- [architecture.md](architecture.md) — стисла архітектурна картина та потік даних.
- [../CLAUDE.md](../CLAUDE.md) — інструкції для AI-агента: критичні правила й вказівники.
- [adr/](adr/) — записи архітектурних рішень (незмінні; див. [adr/README.md](adr/README.md)).

## Як зробити X (процес)

- [building.md](guides/building.md) — збірка з джерел (для контриб'юторів).
- [releasing.md](guides/releasing.md) — зібрати, нотаризувати й опублікувати реліз; стиль release notes.
- [ui-verification.md](guides/ui-verification.md) — жива перевірка menu-bar / Settings змін перед PR:
  перелік стубів (`TOKENPACE_STUB=…`), сценарії без стубу, фічі, що потребують підпису.
- [guides/agent-workflow.md](guides/agent-workflow.md) — операційні правила для AI-агента:
  worktrees, гілки/PR, запуск для перевірки UI, зупинка застосунку та логи, GitHub Project.

## Довідник (що це)

- [conventions.md](reference/conventions.md) — конвенції розробки: мова, стиль, логування, версіонування.
- [users-and-goals.md](reference/users-and-goals.md) — для кого застосунок, який біль розв'язує,
  перевірка «чи сигнал корисний», дефіцитні ресурси, що користувач контролює сам.
- [menu-bar-signals.md](reference/menu-bar-signals.md) — як читати menu bar **із боку користувача**:
  чи є число, що означає гліф поруч, як читаються смужки, і чого віджет не каже.
- [ui-state-truth.md](reference/ui-state-truth.md) — джерело істини для рендерів поза застосунком:
  метрики, анатомія бару, як обчислюється колір, таблиця неможливих комбінацій.
- [bar-status-conditions.md](reference/bar-status-conditions.md) — вичерпний довідник: за яких саме
  умов кожен тип бару набуває кожного статусу/кольору, з посиланням на рядок коду.
- [usage-api-quirks.md](reference/usage-api-quirks.md) — виміряні особливості Claude usage API:
  `utilization` токенних вікон приходить **округленим до цілого відсотка** (крок — 3 хв на 5h і
  1 год 40 хв на 7d), тож дрібні стани на тижневому вікні недосяжні за побудовою.
- [log-messages.md](reference/log-messages.md) — повний перелік кожного лог-повідомлення, згрупований за файлом.
- [performance.md](reference/performance.md) — гейти пʼяти періодичних завдань в одній таблиці: що
  зупиняє screen lock, sleep, батарея, metered-мережа; які гейти відсутні.
- [architecture.md](architecture.md) — архітектура (індекс), розбита на під-сторінки:
  - [reference/architecture/overview.md](reference/architecture/overview.md) — принципи, розгортання, каденції, SPM.
  - [reference/architecture/data-flow.md](reference/architecture/data-flow.md) — полінг, токен, pacing, рендер, діаграми потоку.
  - [reference/architecture/update-system.md](reference/architecture/update-system.md) — перевірка й авто-встановлення оновлень.
  - [reference/architecture/services-and-config.md](reference/architecture/services-and-config.md) — статус сервісів, конфіг, Settings, архіватор.

## Дизайн UI

- [design/menu-bar-pixel-alignment.md](design/menu-bar-pixel-alignment.md) — піксельне вирівнювання
  в menu bar: чому `NSStatusBarButton` стоїть на пів-пойнті, як через це розмиваються краї, і чому
  скріншот цю проблему не показує.

## Рішення (чому саме так)

- [adr/](adr/) — 36 ADR (0001–0036). Індекс і конвенція повного/часткового витіснення —
  в [adr/README.md](adr/README.md).

---

> **Групування вище — за наміром читача** (як зробити / що це / чому), а не за темою. Тематичні
> підпапки — `guides/` та `reference/` (з `reference/architecture/`) — уже на місці; цей індекс
> оновлюється разом зі змінами в структурі доків.
