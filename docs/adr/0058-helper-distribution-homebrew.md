---
status: draft
date: 2026-08-01
---

# ADR-0058 (draft): Дистрибуція helper'а через Homebrew tap

> **Чернетка (draft).** За гейтом #E0. Фіксує install-канал helper'а й «detect, never install» UX.

## Контекст

Helper ([ADR-0054](0054-mas-present-if-installed-helper.md)) — окремий opensource продукт, який
ставить **сам користувач**; MAS-застосунок його лише детектить (2.4.5(iv) — не завантажує/встановлює
сам). Треба обрати найпростіший канал встановлення **під нашу аудиторію**.

Аудиторія — **користувачі Claude Code**, тобто розробники, що вже живуть у терміналі й мають `gh`,
Homebrew, npm. Для них `brew install` — рідне середовище, не бар'єр.

## Рішення

**Основний канал — Homebrew cask через власний tap:**
`brew install --cask artem-n/tap/tokenpace-helper`. Одна команда, notarized, оновлення через
`brew upgrade` безкоштовно. **Cask** (не formula), бо helper — підписаний бандл + LaunchAgent, не
збірка з джерел. **Fallback** — пряме notarized-завантаження з GitHub Releases (для не-Homebrew
користувачів); це ж — артефакт, на який вказує cask.

**npm/npx — відкинуто як основний**: попри те, що аудиторія має npm, це поганий носій для підписаного
macOS LaunchAgent (пакет був би лише завантажувачем notarized-артефакту з GitHub) — зайва
supply-chain поверхня без виграшу. Можливий тонкий convenience-wrapper пізніше, не зараз.

**MAS-застосунок лише детектить + інструктує** (рівно як Spark: «run `spark` to verify»):

```plantuml
@startuml
title ADR-0058: Install-flow helper'а (detect, never install)
start
:MAS-app стартує (standalone:\nстатус сервісів + таймери);
if (bookmark виданий + свіжий status.json?) then (так)
  :повний UI з персональним pacing;
  stop
else (ні)
  :показати non-nagging affordance\n«Personal usage → Learn more»;
  :користувач копіює команду\nbrew install --cask …/tokenpace-helper;
  note right
    App НЕ запускає brew.
    Лише показує команду
    + copy-кнопку (2.4.5-iv).
  end note
  :користувач сам ставить helper;
  :helper пише перший status.json;
  :користувач клікає «Connect»;
  :пояснювальна панель\n(«app читає лише числа, не токен»);
  :pre-navigated NSOpenPanel →\nfolder-scoped read-write bookmark;
  :live-детект перемикає UI\nна «connected ✓»;
  :повний UI з персональним pacing;
  stop
endif
@enduml
```

![PlantUML Diagram](https://www.plantuml.com/plantuml/svg/dLIxJXj15EttAswNjM0T50KfCaL0IOEK1mgYSpDuhyt6ovtLx62K3cCfK20YvK6Jf4tZPeLm03z0yXVC_09VaZkp9YIHaYALFVTnxZddNdivrqBfdUqqq8bE4LQUleeM5XOVrM2LE9McKJELkx25QORgdYaWZ55ZGyy3OGSL96LL9V0uGUtvodeaiWnir-wRmkxPVTkp7o7aDCKYbOIrEisIBjNbIZEmU-RKdd3un9p27BYikJHZdxYeB0L94y9DATlRGhN1d9eBSyOL4_wyTELTrss--oSFqZjvzNKkwN45z1OIX1vlM0a0QkRQN350sRgn2kOSECHp6EIAmuKPsIEV7aCc6WcrbhWjrp8BCCqHGZEn9tT8GsuuTrBC1P2aY4IhnJqWcasfOa4DhDEqluQAwOWKTdBHGhXv-nwUeL04srBXTBJauORcogbrtjWUKopi0RYWkMPdZjb3_nXxtMUsLwTDXRkt_aCKDKJUXfkzR_UrR2CnTupAhJbuaXf19QqjpG-05TwG-Me-WIFF0tWFJWeFSQ1LNsC-Cvb3Cu0xeNwLlzFmfNFGaDcRY3CJnzSCRG_21zM7rSKewLGS75BiEVnLAHCesFBoCjo6ENS4Tm9gvLT7vYShjxN3FvV-JpD7V2Qbpcd_YIJYGxwrdqNQTynYOezT_UmC2ZV7IHsuG9t2QTzVzu4Zw87CQ4R8nxhyBER1DRWhThuDp6GwglWXcKA-a4xI4XfZUB7-CaDQ4uIfEuawDMKQeufoDfFJ2aKSxQg45tTx-XuaJJeOyVqF67_0Lk_FhE37cCqevMsiridJd_ORfKv6lFdouHUr__ihe3Xf1ilymNyQFm00)

Helper (не-sandboxed) **зберігає власний auto-updater** ([ADR-0033](0033-automatic-update-install.md)
/ [ADR-0025](0025-check-for-updates.md)) для GitHub-download користувачів; для Homebrew-встановлених
це belt-and-suspenders (оновлює `brew upgrade`).

## Наслідки

- **Одна `brew`-команда** — install-story вирішена для основної аудиторії; оновлення helper'а через
  `brew upgrade`.
- **App ніколи не запускає `brew`/не встановлює helper** (2.4.5(iv)) — лише показує команду з
  copy-кнопкою + пасивно детектить наявність через IPC. «Learn more» відкриває GitHub у браузері.
- **Пасивний детект** — застосунок не може тихо stat'нути теку до першого bookmark-гранту (sandbox),
  тож flow обов'язково проходить через явний «Connect» + `NSOpenPanel`.
- Потрібен окремий tap-репозиторій + CI, що бампить cask на кожен реліз helper'а.
- Референси: [ADR-0031](0031-session-log-archiver.md) (log archiver → helper),
  [ADR-0025](0025-check-for-updates.md)/[ADR-0033](0033-automatic-update-install.md) (updater →
  helper), [ADR-0055](0055-ipc-file-darwin-bookmark.md) (bookmark-flow).
