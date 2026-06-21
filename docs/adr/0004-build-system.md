---
status: accepted
date: 2026-06-21
---

# ADR-0004: Збірка Фази 1 — SPM + build-скрипт; Xcode у Фазі 2

## Контекст

Menu bar app — це GUI `.app` bundle, якому потрібні `Info.plist` (`LSUIElement = true`),
code signing, notarization і (у Фазі 2) iOS/watchOS таргети. Розглядались Xcode project, чистий
SPM, і гібрид.

Трейдофи:

| Критерій | SPM | Xcode |
|---|---|---|
| git/diff | чистий маніфест | шумний `.pbxproj` |
| .app bundle | вручну (скрипт) | рідна підтримка |
| signing/notarization | ручні CLI-кроки | вбудовано |
| iOS/watchOS таргети | практично неможливо | нативно |
| CI/headless | просто `swift build` | важче (`xcodebuild`) |

## Рішення

- **Фаза 1:** Swift Package Manager + build-скрипт, що автоматизує:
  складання `.app` bundle (структура `Contents/{MacOS,Resources}` + `Info.plist`),
  `codesign --options runtime`, notarization (`xcrun notarytool submit --wait` + `xcrun stapler`).
- **Фаза 2:** приєднати Xcode project для iOS/watchOS застосунків (SPM їх не тягне). Спільну
  логіку (TokenProvider, UsageClient, PacingModel) тримати у SPM-пакеті, який підключається і до
  agent, і до Xcode-таргетів.

## Наслідки

- Чиста git-історія для логіки; bundle/sign/notarize — у версіонованому скрипті.
- Доступ до Keychain-айтема Claude Code не залежить від системи збірки (це питання ACL айтема,
  а не entitlements) — окремий ризик, перевіряється незалежно.
- Перехід на Xcode у Фазі 2 потребує міграційної роботи, але логіка вже в пакеті — врапер тонкий.
