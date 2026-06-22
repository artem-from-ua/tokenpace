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
| [0009](0009-statusitemview-pure-layout-and-thin-shell.md) | StatusItemView — чиста MenuBarLayout + тонкий AppKit-shell; idle-поріг 5% | accepted |
| [0010](0010-usage-health-and-error-states.md) | UsageHealth — стани помилок (⚠️ menu bar + банер popup + stale); пороги 30/60 хв | accepted |
