---
status: accepted
date: 2026-07-25
---

# ADR-0033: Авто-встановлення оновлень — власний мінімальний інсталятор, не Sparkle

> Доповнює [ADR-0025](0025-check-for-updates.md) (перевірка оновлень), **не заміщає** його: сигнальна
> частина (банер / пункт меню / рядок «Download») лишається чинною і слугує fallback-ом, коли
> авто-встановлення вимкнене або не спрацювало.

## Контекст

ADR-0025 додав **перевірку** оновлень, але не встановлення: коли знайдено новіший тег, TokenPace
показує банер, пункт меню з синьою крапкою і рядок «Update available: vX.Y.Z — Download», а по кліку
відкриває сторінку релізу. Заміну `.app` користувач робить **вручну** — качає нотаризований `.zip`,
розпаковує, перетягує в `/Applications`.

Остап (@kintecus) запропонував додати опційне **авто-встановлення** — чекбокс «Install updates
automatically», за яким TokenPace сам доводить оновлення до кінця. Епік —
[#125](https://github.com/artem-from-ua/tokenpace/issues/125), фази —
[#122](https://github.com/artem-from-ua/tokenpace/issues/122),
[#123](https://github.com/artem-from-ua/tokenpace/issues/123),
[#124](https://github.com/artem-from-ua/tokenpace/issues/124).

Ключове рішення — **як** встановлювати. Заміна виконуваного bundle — привілейована операція зі
значною поверхнею атаки, тож постають питання: писати власний інсталятор чи взяти Sparkle
(де-факто стандарт non-App-Store auto-update); як гарантувати, що завантажений bundle справді наш;
як зробити заміну атомарною; як не зламати наявний pure-core / thin-shell розкол і політику нульових
залежностей.

## Рішення

### 1. Власний мінімальний інсталятор, а не Sparkle

Обрано **власний** інсталятор. Порівняння:

| Критерій | Власний | Sparkle |
|---|---|---|
| Runtime-залежність | немає (лише системні `codesign`/`spctl`/`ditto` + `URLSession`) | перша third-party залежність у `Package.swift` |
| Appcast | не потрібен — джерело вже є (GitHub Releases API через `GitHubReleaseClient`, включно з приватним-репо шляхом `gh`) | потрібен `appcast.xml` + його хостинг |
| Підпис оновлення | наявний ланцюг Apple (нотаризація + Developer ID), яким уже підписаний release-артефакт | окремі EdDSA-ключі паралельно до нотаризації |
| Відповідність ADR | тримає pure-core/thin-shell (ADR-0009/0023), закритий агент (ADR-0003) | тягне зовнішній UI/логіку, обходить decision-seam підхід |
| UI | наш нативний банер/Settings-рядок | власний UI Sparkle (конфлікт із наявним) |

Sparkle вирішив би atomic replace / relaunch / delta «з коробки», але ціна — перша зовнішня
залежність, окремий appcast-hosting, друга система ключів і чужий UI — надмірна для одного menu-bar
застосунку, що вже має половину інфраструктури (`UpdateFetcher`, `GitHubReleaseClient`,
`SemanticVersion`, cadence, Settings-секцію). Власний інсталятор переюзовує **ланцюг довіри Apple**
замість власної PKI і не додає залежностей — це вирішальна перевага.

### 2. Розкол pure-core / thin-shell

Уся розгалуженість рішень — у `TokenPaceKit` (чисте, тестоване), увесь I/O — у тонкому shell:

- **Kit (чисте):** `GitHubRelease.assets[]` (розширений декодер, `browser_download_url`);
  `UpdateAssetSelector.selectZIP(from:)` — вибір version-named `.zip` asset із HTTPS-guard;
  `UpdateInstallPlan.decide(release:currentVersion:isAppBundle:autoInstallEnabled:)` — зведення всіх
  умов «ставити зараз?» в один вердикт (`.install` / `.skipNotNewer` / `.skipNoAsset` /
  `.skipNotAppBundle`).
- **Shell (I/O):** `UpdateInstaller` за протокольним seam-ом + stub — `download` (двошляховий:
  `gh release download` за `TOKENPACE_GH_AUTH` для приватного репо, інакше анонімний `URLSession`),
  `verify` (`codesign`/`spctl`/Team ID сабпроцеси, як `GHReleaseFetcher`), `unzip` (`ditto -x -k`),
  `replaceInstalled` (`FileManager.replaceItemAt`), `relaunch` (`NSWorkspace.openApplication` +
  `NSApp.terminate`).

Це той самий поділ, що `ArchiveSyncPlan` (чисте) / `LogArchiver` (I/O) в ADR-0031.

### 3. Безпекові інваріанти (обов'язкові)

1. **HTTPS-only** — не-`https` `browser_download_url` відкидається ще на pure-стадії вибору asset.
2. **Верифікація перед заміною** — `codesign --verify --deep --strict` + звірка **Team ID
   `S5A4U9798Y`** (головний захист від підміни: навіть валідно підписаний, але чужий bundle
   відхиляється) + Gatekeeper `spctl --assess --type execute` (нотаризація/stapling).
3. **Downgrade/replay-guard** — ставити лише коли `UpdateComparison.isNewer` == true; рівна/старіша
   версія → no-op (уже контракт `checkForUpdate`, авто-install гілка його не обходить).
4. **Атомарність** — новий bundle повністю розпакований і верифікований у tmp *до* єдиної атомарної
   `replaceItemAt` з backup-іменем. Перерваний download/unzip не торкається `/Applications`;
   перерваний swap лишає або цілий старий, або цілий новий `.app`, ніколи побитий.
5. **Права на `/Applications`** — якщо запис неможливий (bundle/тека належать root) → error +
   fallback на ручний Download. Привілейований хелпер (SMJobBless) — **свідомо поза обсягом MVP**,
   окремий майбутній тікет.
6. **Relaunch безпечно** — лише після успішної заміни; якщо запуск нового bundle не вдався, поточний
   процес **не** термінується (новий уже на диску, наступний launch його підхопить).
7. **Приватний репо → download через `gh`** — репо наразі приватний, тож анонімний
   `browser_download_url` віддає 404. Коли встановлено `TOKENPACE_GH_AUTH`, asset качається
   `gh release download` (локальні креденшали мейнтейнера), як і читання release-JSON у
   `GHReleaseFetcher`. Публічний репо → анонімний `URLSession`.

### 3a. Environment defer-гейти (лише для встановлення)

Три умови середовища відкладають **встановлення** (не перевірку — check їде за 12-год каденцією
незалежно): **вільне місце** (після завантаження має лишитись ≥ 5 GB, `minFreeBytesAfterDownload`),
**AC power** (не качати/замінювати на батареї — ризик розряду посеред заміни), **unmetered network**
(не витрачати ~МБ на capped-з'єднанні). Це `defer…`-вердикти (не `skip`): оновлення валідне, просто
чекає кращих умов, і **наступний heartbeat переоцінює** — стану персистити не треба. Факти
(`DiskSpace`, `PowerSource`, `NetworkMonitor.isMetered`) читаються в shell і інжектяться в чистий
`UpdateInstallPlan.decide`. **Forced-запуск** (dry-run) оминає AC/metered — мейнтейнер попросив явно —
але **не** free-space (жоден намір не робить безпечним заповнення диска).

### 4. Гейт на реальний `.app` + opt-in default-OFF

Усі шляхи інсталятора гейтяться `LaunchAtLoginController.isAppBundle` — той самий дискримінатор
реального `.app`, що вже використовують `UpdateNotifier` і launch-at-login. `swift run` → повний
no-op. Опція `PersistedConfig.installUpdatesAutomatically` — **opt-in, default-OFF** (ідіома
`object(forKey:) as? Bool ?? false`, як `archiveEnabled`); Settings-чекбокс «Install updates
automatically» **вкладений** під «Check for updates automatically» (немає сенсу авто-ставити без
перевірки) й enabled лише коли батько увімкнений **і** ми реальний `.app` у `/Applications`.

### 5. Контракт імені asset

Інсталятор шукає version-named нотаризований `.zip` — `TokenPace-<X.Y.Z>.zip` (реальний патерн
release-артефакту; `build-app.sh` пакує `TokenPace.zip`, а version-named ім'я надається в release-
процесі, див. `docs/releasing.md`). Цей контракт зафіксовано в `docs/releasing.md`, бо на нього
спирається чистий `UpdateAssetSelector`.

### 6. Фазування (жорсткий порядок)

Поверхня довіри зростає поступово, кожна фаза — окремий PR після живої верифікації:

- **Фаза 1** (#122): декодер `assets[]` + `UpdateAssetSelector` + `UpdateInstallPlan` + opt-in ключ і
  вкладений чекбокс — **нічого не замінюється**, лише логується вердикт.
- **Фаза 2** (#123): `download`/`verify`/`unzip` під **dry-run** гейтом (`TOKENPACE_UPDATE_DRYRUN`) —
  качає й верифікує без заміни.
- **Фаза 3** (#124): `replaceInstalled` + `relaunch` + авто-тригер у `handleUpdateFound`.

## Наслідки

- **Fallback завжди є**: будь-який фейл (download / verify / unzip / replace / права) логується й
  падає у наявний сигнальний банер + рядок «Download». Фіча ніколи не гірша за поточну сигнальну
  поведінку ADR-0025.
- **Верифікаційні env-стуби**: додаються `TOKENPACE_UPDATE_DRYRUN` (Фаза 2) і `TOKENPACE_UPDATE_TARGET`
  (Фаза 3, націлити на тестову копію поза `/Applications`) — до сімейства `TOKENPACE_STUB`/
  `TOKENPACE_FAKE_LATEST`. Занесені в `CLAUDE.md`.
- **Обмеження середовища**: повний флоу працює лише на **нотаризованому `.app` із `/Applications`**;
  `swift run` — no-op. Тест руйнівний (замінює й перезапускає застосунок), тож верифікується
  багаторівнево — dry-run → тестова копія поза `/Applications` → реальна пара релізів (див. issues).
- **Тестова межа** (ADR-0009): чисте ядро (`UpdateAssetSelector`, `UpdateInstallPlan` з усіма
  гейтами, розширений декодер) покрите unit-тестами; shell (`UpdateInstaller`) — вручну на живому
  `.app`. Повний ланцюг **верифіковано наживо end-to-end**: нотаризований білд vN, реальний реліз
  vN+1 → gh-download → verify (Team ID + Gatekeeper) → **атомарна заміна** тестової копії (через
  `TOKENPACE_UPDATE_TARGET`, поза `/Applications`) → **relaunch** на нову версію; замінений bundle
  лишився валідним (`codesign`/`spctl` accepted).
- **Не-`/Applications` розміщення** та привілейована заміна — свідомо поза MVP; за потреби —
  майбутній ADR про SMJobBless-хелпер.

## Пов'язані

- [ADR-0025](0025-check-for-updates.md) — перевірка оновлень, яку цей ADR доповнює (сигнальна частина
  лишається fallback-ом); переюзовуються `UpdateFetcher`/`GitHubRelease`/`SemanticVersion`/
  `UpdateComparison`/`GitHubReleaseClient`.
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — чисте ядро / тонкий shell, за яким
  розділено `UpdateInstallPlan`/`UpdateAssetSelector` (kit) і `UpdateInstaller` (shell).
- [ADR-0031](0031-session-log-archiver.md) — той самий pure/shell розкол
  (`ArchiveSyncPlan`/`LogArchiver`) і opt-in default-OFF ідіома в `PersistedConfig`.
- [ADR-0023](0023-persisted-config-version-marker.md) — `PersistedConfig`, розширений ключем
  `installUpdatesAutomatically`.
- [ADR-0004](0004-build-system.md) — `build-app.sh` (нотаризований version-named `.zip`), джерело
  довіри, на яке спирається `verify`.
