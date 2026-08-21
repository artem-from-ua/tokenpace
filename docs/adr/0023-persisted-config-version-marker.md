---
status: accepted
date: 2026-07-23
---

# ADR-0023: A config version marker + the tested boundary in the persistence layer

## Context

Issue #71 lays down the **first persistence layer** in the project: before it,
`grep -r UserDefaults Sources` returns nothing — no `UserDefaults`, `@AppStorage`, or any settings
written to disk. The only thing "remembered" between launches was system state (the `SMAppService`
login item, via `LaunchAtLoginController`) and the Troubleshoot window's frame
(`setFrameAutosaveName`), not the app's own config.

The need: keep, in the saved config, **the version that last wrote the parameters**
(`lastRunVersion`), so a newer build can compare "last saved version" against "current" and, if
needed, run key migrations or clean up system state (e.g., remove stale login items left over from
the old name `cc-timer`) **before** the config starts being used.

This raises the same class of module-boundary decision as in
[ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md),
[ADR-0010](0010-usage-health-and-error-states.md),
[ADR-0011](0011-polling-engine-adaptive-cadence-and-signal-seams.md): where the side-effecting part
lives (`UserDefaults`), where the pure, tested logic lives, and how to keep them uncoupled.

This ticket's scope is deliberately narrow: **only the version marker + a migration scaffold**.
There are no real migrations yet; a broader typed config store is out of scope (a separate future
ticket). The key decision to pin down is where to draw the tested boundary, so this first bit of
persistence doesn't bring uncovered logic into the project.

## Decision

1. **The pure part — the migration decision predicate — lives in `TokenPaceKit`
   (`MigrationPlan`) and is covered by tests.** A framework-free `enum` with no `Foundation` I/O:
   `transition(stored:current:)` classifies a startup into `firstRun` / `unchanged` /
   `upgraded(from:to:)`, and `needsMigration(_:)` decides whether there's anything to run. This is
   the same split as `LaunchAtLogin` (pure predicates) vs. `LaunchAtLoginController` (the
   `SMAppService` glue): the semantics and the decision live in the kit, reusable in Phase 2 and
   testable without a live store.

2. **The side-effecting part — a `UserDefaults` wrapper — lives in the `TokenPace` shell
   (`PersistedConfig`) and is verified manually.** `UserDefaults.standard` is a system singleton
   that can't be cleanly injected or mocked (like `SMAppService`), so the code that reads/writes it
   stays in the executable target and is manual-verified by convention
   ([ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) § "Consequences"). The wrapper is
   minimal: one key, `lastRunVersion` (String), with `get`/`set`. This is a seam a future ticket
   will extend with other keys (e.g., the monitored-services config, #89), not a universal store
   built ahead of need.

3. **`lastRunVersion == nil` is treated as `firstRun` — a fresh install or a pre-versioning
   build.** A missing key means the parameters have never been written under a version marker: this
   is either the first launch after this ticket landed, or an upgrade from a build that had no
   persistence at all. Either way, there's nothing to migrate — we just write the current version.
   We deliberately do **not** introduce a separate "first launch" persistence flag: the `nil` marker
   is enough, and it doesn't interfere with future post-update migrations (unlike a "do this once,
   ever" flag would).

4. **The migration hook is the very first action in `applicationDidFinishLaunching`, before the UI
   or polling are created.** `AppDelegate.runConfigMigrationsIfNeeded()` reads `lastRunVersion`,
   classifies it via `MigrationPlan.transition`, logs the outcome (`AppLogger.lifecycle`, three
   states), and **writes the current version back**. Placing it first guarantees that a future
   migration has time to clean up state the rest of startup depends on, before that code reads it.
   Structurally this mirrors `registerLaunchAtLoginIfNeeded()` — the same class of lifecycle
   helper.

5. **Version comparison is currently a plain string inequality (`stored != current`), not a
   SemVer ordering.** For a scaffold with no real migrations yet, this is enough: `.upgraded` fires
   on any difference and carries both ends (`from`/`to`), so a future migration can key off the
   exact transition. Full SemVer comparison ("migrate only if `old < X.Y.Z`") is deferred until the
   first real migration that needs it. A "downgrade" (an older build running than the one that wrote
   the config) is deliberately left as plain `.upgraded` — not a special case.

## Consequences

- `TokenPaceKit` stays free of dependencies: `MigrationPlan` operates only on semantics; the
  platform side (`UserDefaults`) lives in `TokenPace`. The predicate is covered by unit tests
  (`MigrationPlanTests`); the wrapper and the hook are manual-verify.
- A scaffold with no real migrations means `needsMigration` currently gates no actual work anywhere
  — the `.upgraded` branch only logs. This is deliberate: the extension point is ready, and the
  ticket that needs steps will add them (the first real migration/cleanup, e.g., old `cc-timer`
  login items — #69).
- **Logging** (`AppLogger.lifecycle`, `.notice`): "config: first run, no prior version (X)" /
  "config: version unchanged (X)" / "config: version X → Y, running migrations." The version is
  `.public` (a safe diagnostic string, not a secret). Entries added to `docs/log-messages.md`.
- **To verify (manual):**
  - First launch after an update (empty `lastRunVersion`) → the "first run, no prior version" log;
    `defaults read com.artem-n.tokenpace lastRunVersion` shows the current version.
  - A second launch of the same version → the "version unchanged" log.
  - Launching a build with a different version (or a spoofed `lastRunVersion`) → the "version X → Y,
    running migrations" log.

## Related

- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — the pure-core / thin-shell split
  and manual-verify for side-effecting glue; the persistence layer follows the same split.
- [ADR-0010](0010-usage-health-and-error-states.md) — `UsageHealth` as an example of a pure value
  type with states; `MigrationPlan.Transition` is its analog for the migration domain.
- Issues: #71 (this ticket), #69 (an example of system state a future migration could clean up —
  stale login items), #89 (the first consumer that will extend `PersistedConfig` with a config
  key).
