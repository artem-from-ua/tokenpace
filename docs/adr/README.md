# Архітектурні рішення (ADR)

Записи архітектурних рішень проєкту. Кожен ADR незмінний; коли рішення застаріває, його запис
лишається, а в індексі номер і назва закреслюються.

| # | Назва | Статус |
|---|---|---|
| [0001](0001-swift-stack.md) | Swift як єдина мова проєкту | accepted |
| [0002](0002-ukrainian-documentation.md) | Українська як мова документації | accepted |
| [0003](0003-agent-closed-source-for-now.md) | Mac-агент поки закритий; ліцензія — відкрите питання | accepted |
| [0004](0004-build-system.md) | Збірка Фази 1 — SPM + build-скрипт; Xcode у Фазі 2 | accepted |
| [0005](0005-pacing-fractions-not-blocks.md) | PacingModel — зони у відсотках замість блоків | accepted |
| [0006](0006-reset-time-absolute-vs-relative.md) | ResetClock — абсолютний `hh:mm` для далеких ресетів, не лише відносний час | accepted |
| [0007](0007-token-provider-throws-and-scope-split.md) | TokenProvider — `throws`+enum та розбивка обсягу #8 | accepted |
| [0008](0008-usageclient-pure-backoff-and-transport-seam.md) | UsageClient — чистий backoff, інжекція токена і transport-seam | accepted |
| ~~[0009](0009-statusitemview-pure-layout-and-thin-shell.md)~~ | ~~StatusItemView — чиста MenuBarLayout + тонкий AppKit-shell; idle-поріг 5%~~ | superseded |
| [0010](0010-usage-health-and-error-states.md) | UsageHealth — стани помилок (⚠️ menu bar + банер popup + stale); пороги 30/60 хв | accepted |
| [0011](0011-polling-engine-adaptive-cadence-and-signal-seams.md) | PollingEngine — async-цикл, адаптивний інтервал і seam'и sleep/wake/мережі | accepted |
| ~~[0012](0012-configure-window-and-launch-at-login.md)~~ | ~~Вікно «Configure…» та launch-at-login (SMAppService); opt-out, best-effort на unsigned~~ | superseded |
| [0013](0013-claude-status-line.md) | Рядок статусу сервісів Claude у попапі — лише `component.status` двох компонентів, окрема ввічлива cadence | accepted |
| [0014](0014-usage-decode-resilience-on-reset-boundary.md) | UsageSnapshot — синтез вікна на межі ресету замість падіння decode (хибне «Usage API unavailable») | accepted |
| [0015](0015-no-idle-mode.md) | Прибрати компактний idle-режим — завжди смужки (крім стану помилки) | accepted |
| [0016](0016-rename-to-tokenpace.md) | Перейменування проєкту cc-timer → TokenPace — ідентифікатори, межі історії | accepted |
| [0017](0017-delegated-token-refresh.md) | Делегований refresh токена через claude CLI — замість self-refresh із write-back | accepted |
| [0018](0018-launch-at-login-notfound-recovery.md) | Відновлення launch-at-login після оновлення — `.notFound` не термінальний, `register()` арбітр | accepted |
| [0019](0019-token-read-via-security-cli.md) | Читання токена сабпроцесом `security` CLI — refresh Claude Code скидає ACL partition list, прямий `SecItemCopyMatching` промптить | accepted |
