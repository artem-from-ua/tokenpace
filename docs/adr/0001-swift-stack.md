---
status: accepted
date: 2026-06-21
---

# ADR-0001: Swift як єдина мова проєкту

## Контекст

Mac-агент має читати macOS Keychain і (у Фазі 2) писати в CloudKit, а застосунки iPhone/Watch —
читати з CloudKit. Розглядались дві мови для Mac-агента: Swift і Go.

## Рішення

Використовуємо **Swift** для всього проєкту — Mac menu bar app, а згодом iOS/watchOS.

## Наслідки

**Плюси:**

- Рідний доступ до Keychain (Security framework) і CloudKit (CloudKit framework) — без обхідних
  шляхів.
- Один стек на весь проєкт: agent, iOS app, watchOS complication.
- AppKit (`NSStatusItem`) + SwiftUI (`NSHostingView`) — декларативний UI смужок усередині
  menu bar.

**Мінуси:**

- Swift-демони на macOS трохи менш звичні OSS-контриб'юторам, ніж Go CLI.

**Чому не Go:**

- CloudKit з Go вимагає CloudKit Web Services API + server-to-server ключ (складно, і це вже
  «майже бекенд»).
- Немає рідного доступу до Keychain.
