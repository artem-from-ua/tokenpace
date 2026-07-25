# Архітектура

Деталі продукту — у [SPEC.md](../SPEC.md). Архітектурний опис розбито на чотири сторінки за областю
(файл розрісся до одного великого документа й став важким для навігації):

- [reference/architecture/overview.md](reference/architecture/overview.md) — принципи, топологія
  розгортання (Фаза 1 vs Фаза 2), родина каденцій, SPM-розкладка, мапа компонентів.
- [reference/architecture/data-flow.md](reference/architecture/data-flow.md) — потік даних Фази 1:
  полінг, читання й делегований refresh токена, pacing-модель, рендер menu bar і popup,
  оптимістичний ресет, session-idle, стани помилок. **Діаграми:** каденція, пауза/wake, refresh,
  reset-таймер, idle, health.
- [reference/architecture/update-system.md](reference/architecture/update-system.md) — перевірка й
  авто-встановлення оновлень, єдиний update-пункт дропдауна. **Діаграми:** check cadence,
  `UpdateMenuState`, install-гейти.
- [reference/architecture/services-and-config.md](reference/architecture/services-and-config.md) —
  статус сервісів Claude, monitored services, persistence/міграція, вікно Settings, архіватор
  логів, Troubleshoot.

> Це індекс-сторінка. Змінюючи модуль, онови відповідну під-сторінку `architecture/` у тому самому
> коміті (правило «docs are part of code» — див. [../CLAUDE.md](../CLAUDE.md) та
> [guides/agent-workflow.md](guides/agent-workflow.md)).
