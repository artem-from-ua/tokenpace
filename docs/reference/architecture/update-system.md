# Архітектура — система оновлень

Наскрізна картина — в [overview.md](overview.md). Тут — перевірка релізів, авто-встановлення й
єдиний update-пункт дропдауна. Ланцюг рішень: ADR-0025 (перевірка) → ADR-0033 (встановлення) →
ADR-0036 (сигнальний UX). Перші два частково витіснені 0036 — див.
[../../adr/README.md](../../adr/README.md).

## Перевірка оновлень (ADR-0025)

Чек іде через GitHub releases: анонімний HTTPS (`HTTPUpdateFetcher`) або `gh`-subprocess
(`GHReleaseFetcher`, поки репо приватне — гейт `TOKENPACE_GH_AUTH`). Семвер-порівняння —
`SemanticVersion`; будь-яка помилка парсингу → жодного фантомного оновлення.

**Каденція чеку** — фіксовані 12 год плюс безумовний чек при старті:

```plantuml
@startuml
title Update check cadence (UpdateCheckCadence, ADR-0025)
[*] --> LaunchCheck : app start\n(unconditional)
LaunchCheck --> Idle : marker lastUpdateCheck advanced
Idle --> Checking : isDue(lastCheck, now)\n≥ 12h since last attempt
Checking --> Idle : advance marker\n(on EVERY attempt, even 404)
Idle : re-checks gated by 12h
Checking : GitHubReleaseClient.checkForUpdate
@enduml
```

![PlantUML Diagram](https://www.plantuml.com/plantuml/svg/JP1DJiCm48NtFiKi4vIWK9LD5wWeBJyIgqWW8SfY6eyQgyuaYYT57863S35EWkqKbEtp-_mzU-q41nbRgyI89NZkDGf1tL1zX1erSKsGJ6aPmdBAChZTL7bHBAvJzNRn3db-0qyuSjt45gm0-nxYvJjEVDwnDc8wHfkgUJ60ZzgRLz3YSAG1B3gP2G7r2RrHgrWB_PWRFdZ6kCr8IK1Yc05t7-cEVxw-uMhHW3DXVpW65A6s5_KFpyndnNc17zmnR5-srUiVbG6TY65PB5DrPWRAuoyvEFYf6lQVmQXcs-wDF8pxYYoXez8QOhcCo5qtJ0zKQsBjF_yN)

## Єдиний update-пункт дропдауна (ADR-0036)

`UpdateMenuState` — чиста машина станів **єдиного** пункту меню (#130), що замінила банер
`UpdateNotifier` (жодних `UserNotifications`). `evaluate(...)` → семантичний `Item`-enum за
пріоритетною таблицею; будь-яка версія, новіша за встановлену, витісняє «what's new».

```plantuml
@startuml
title UpdateMenuState — single dropdown item
[*] --> hidden
hidden --> updateFailed : lastFailedInstallVersion == latest
hidden --> updateAvailable : latest > installed\n(auto-install OFF)
hidden --> updatePending : latest > installed\n(auto-install ON)
hidden --> whatsNew : pendingWhatsNewVersion set
updatePending --> updateFailed : install error
updatePending --> whatsNew : installed & relaunched
updateFailed --> updatePending : retry (newer seen)
whatsNew --> hidden : dismissed
note right of updateFailed
  priority: failed > available
  > pending > whatsNew
  any newer version pre-empts whatsNew
end note
@enduml
```

![PlantUML Diagram](https://www.plantuml.com/plantuml/svg/ZLBDJiCm3BxdANn26r9VODAgSQd4WGq90GVW48YtHagTod5NxSP3y8Gy2MPjLwhjm2cExU_7SLP9B4jJ1IDU0i9ZxQpW7LBp81h0z-SN94yxBJcEjOijWHUipClr6sHP3gLt3ibqnp7J72aAwmCwM42mIRhBBQbO24_8oKU2vL9hWadEmJTx1TXt5LtqFP23x-3eNcbc6ubPdu1DKSpFEUwHd1h_7yDwGj2MLj8QMyNM7Sjpdncy9nGpbRam-S2Ep94ljF-HEJc3As0Cjg6F4fsP45uQZL7u03F25bbD8StDYNNSZZOwdogVad9IrBMotvK2SJknR01gzf6z71QmxKHpiCCkj9mFxm6ZUqrREa1dOT-_JysOOLLB6jiK2B_QPgMHVhWV)

Колір і текст — у view (`AppDelegate`, переюзує `PopupViewController.dotColor`: 🔴 `.majorOutage`
для failed / 🔵 `.underMaintenance` для pending).

## Рішення про авто-встановлення (ADR-0033)

`UpdateInstallPlan.decide(...)` — один вердикт «ставити зараз?» за впорядкованими гейтами.
Environment-гейти (місце / живлення / metered) — **лише для встановлення**, не для check-шляху;
`.defer…` переоцінюється наступним heartbeat, `.skip…` — settled.

```plantuml
@startuml
title Auto-install decision gates (UpdateInstallPlan.decide)
start
if (auto-install enabled?) then (no)
  #FDE8E8:skip: auto-install-off;
  stop
else (yes)
endif
if (newer than installed?) then (no)
  #FDE8E8:skip: not-newer;
  stop
else (yes)
endif
if (running as .app in /Applications?) then (no)
  #FDE8E8:skip: not-app-bundle;
  stop
else (yes)
endif
if (matching version-named .zip asset?) then (no)
  #FDE8E8:skip: no-asset;
  stop
else (yes)
endif
if (free space ≥ 5 GB after download?) then (no)
  #FFF8E1:defer: insufficient-space;
  stop
else (yes)
endif
if (on AC power?) then (no)
  #FFF8E1:defer: on-battery;
  stop
else (yes)
endif
if (network un-metered?) then (no)
  #FFF8E1:defer: metered-network;
  stop
else (yes)
endif
#E8F5E9:install:\ndownload → unzip → verify\n→ replace → relaunch;
stop
@enduml
```

![PlantUML Diagram](https://www.plantuml.com/plantuml/svg/XPEnJiCm48RtFCL9NTB1HGoLIZhG0YbYOs7huiRdrgfpjcA7gZm04Yllm8lrIRYO8XK1wNPA_l_xdV-SMOYoYMrjisYYHPYtqGb3_DHQK5YPO1p1MaOCa3zvnSF3rzj7AsdKAHGEiqJ9Z8PSdWAGvCgYkXv2t211JcwO0GmMT-Mad1HXQtm1fmRXj9wo8aJdCxG18TzZ66P8okY49znXmpH9SFISmPEB8fdwkKrBP6WDCi18Uizmk9XxRqqb8pSGpcQmIQnQKXRxWsePgqsNz8nDrwqWMQE2qOln71umdaaIITIVeHj425vM28Ut3nZ3_Gr87RauvNPadVnTsM8nAIyBXHgRecksrTfK1YcAnEdFuniolmNlkEL-C7_kIaO-oFxSbkFEDLjeITJ8yZzs_8Dx58cZxt_ue9minkLLSRmxnPA-6u73wpldTMle9jwEqVibTNE3tgOkqsnbIzLccgM06MFvv_a4)

## Компоненти системи оновлень

| Компонент | Відповідальність |
|---|---|
| **SemanticVersion / UpdateComparison** | Чистий семвер-парсер (#37, `TokenPaceKit`, ADR-0025). `SemanticVersion(_:)` парсить `vX.Y.Z`/`X.Y.Z` консервативно (рівно 3 числові компоненти; суфікс `-beta`/`+meta` відкидається), `Comparable`. `UpdateComparison.isNewer(tag:than:)` → `false` на будь-якій помилці парсингу (контракт «ніколи не смикати на смітті») |
| **GitHubRelease / GitHubReleaseClient** | HTTP-seam GitHub-релізу (#37, ADR-0025). `GitHubRelease` (Decodable) парсить `tag_name`/`html_url` + `assets[]` (forward-compat). `checkForUpdate(using:currentVersion:)` — fetch → decode → `isNewer`, повертає реліз лише якщо новіший, будь-яка помилка (в т.ч. 404) → `nil`. Транспорт абстрагований на `UpdateFetcher` (не `UsageTransport`), бо один шлях — subprocess |
| **UpdateAssetSelector / UpdateInstallPlan** | Чисті seam-и авто-встановлення (#122, `TokenPaceKit`, ADR-0033). `selectZIP(from:)` вибирає version-named `.zip` (`TokenPace-<X.Y.Z>.zip`), відкидає не-HTTPS. `decide(...)` — впорядковані гейти (opt-in → newer → real `.app` → asset → free space ≥5 GB → AC power → unmetered) → `.install` / `.skip…` / `.defer…`. Факти інжектяться з shell |
| **UpdateCheckCadence** | Чистий seam частоти update-чеку (#37, ADR-0025) — фіксований 12-год інтервал (не прив'язаний до usage-cadence). Shell також перевіряє **безумовно при старті**; маркер `lastUpdateCheck` радиться на **кожній** спробі (навіть 404) |
| **UpdateMenuState** | Чиста машина станів **єдиного** update-пункту (#130, `TokenPaceKit`, ADR-0036). `evaluate(...)` → `Item`-enum (`hidden`/`updateFailed`/`updateAvailable`/`updatePending`/`whatsNew`) за пріоритетною таблицею. Колір/текст — у view. **Замінив `UpdateNotifier`** (банер видалено). ADR-0036 |
| **GHReleaseFetcher / ShellEnvironment** | `gh`-subprocess-конформер `UpdateFetcher` (#37, ADR-0025) — `gh api repos/…/releases/latest`, таймаут 20 с, stdout захоплюється, середовище успадковується (`gh` потребує keyring). Обирається коли встановлено `TOKENPACE_GH_AUTH`. `ShellEnvironment` читає цю env-змінну з rc-файлів login-шелла (`SMAppService` стартує без шелла). `StubUpdateFetcher` — `TOKENPACE_FAKE_LATEST` |
| **UpdateInstaller** | Тонкий I/O-shell авто-інсталятора (#123, ADR-0033) за seam-ом `AppUpdateInstalling`. Пайплайн off-main: **download** (двошляховий: `gh release download` за `TOKENPACE_GH_AUTH` / анонімний `URLSession`) → **unzip** (`ditto -x -k`) → **verify** (`codesign --verify` + звірка Team ID через `codesign -dv` + Gatekeeper `spctl`) → **replace** (атомарний `replaceItemAt` з backup) → **relaunch**. Fail-safe (не кидає). `TOKENPACE_UPDATE_DRYRUN` зупиняє після verify; `TOKENPACE_UPDATE_TARGET` перенаправляє заміну на тестову копію |
| **PowerSource / DiskSpace / NetworkMonitor.isMetered** | Shell-факти середовища для defer-гейтів (#123/#124, ADR-0033). `isOnACPower` — IOKit-read (fail-open → `true`). `availableBytes` — `volumeAvailableCapacityForImportantUsage`. `isMetered` — `path.isExpensive \|\| path.isConstrained`. Гейтять **лише встановлення**, ніколи не check-шлях |
