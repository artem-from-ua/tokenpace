# Architecture

Product details live in [SPEC.md](../SPEC.md). The architectural description is split across four
pages by area (the file grew into one large document and became hard to navigate):

- [reference/architecture/overview.md](reference/architecture/overview.md) — principles, deployment
  topology (Phase 1 vs Phase 2), the cadence family, the SPM layout, the component map.
- [reference/architecture/data-flow.md](reference/architecture/data-flow.md) — the Phase 1 data flow:
  polling, reading the token and the delegated refresh, the pacing model, menu bar and popup
  rendering, the optimistic reset, session-idle, error states. **Diagrams:** cadence, pause/wake,
  refresh, reset timer, idle, health.
- [reference/architecture/update-system.md](reference/architecture/update-system.md) — checking for
  and auto-installing updates, the single update item in the dropdown. **Diagrams:** check cadence,
  `UpdateMenuState`, install gates.
- [reference/architecture/services-and-config.md](reference/architecture/services-and-config.md) —
  Claude service status, monitored services, persistence/migration, the Settings window, the log
  archiver, Troubleshoot.

> This is an index page. When you change a module, update the matching `architecture/` sub-page in the
> same commit (the "docs are part of code" rule — see [../CLAUDE.md](../CLAUDE.md) and
> [guides/agent-workflow.md](guides/agent-workflow.md)).
