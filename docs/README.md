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
