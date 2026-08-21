---
status: superseded
superseded_by: [0116]
date: 2026-06-21
---

> **Superseded by [ADR-0116](0116-english-as-documentation-language.md).** English is now the
> language of everything in the repository and on GitHub. This record is kept in Ukrainian on
> purpose: an accepted ADR is immutable, and translating it would rewrite the decision as it was
> made. Only its status changed.

# ADR-0002: Українська як мова документації

## Контекст

Глобальне правило користувача за замовчуванням вимагає англійської для репо-артефактів
(README, docs, ADR). Для цього проєкту користувач прямо попросив вести **всю документацію
українською**.

## Рішення

Уся документація проєкту (`README`, `SPEC`, `docs/`, ADR) — **українською**. Код, ідентифікатори,
повідомлення комітів і API-поля лишаються англійською/в оригіналі.

## Наслідки

- Пряма інструкція користувача для цього проєкту перекриває глобальний дефолт.
- Контриб'ютори, що не читають українською, спираються на код та ідентифікатори (англійські).
- Технічні терміни й ідентифікатори API не перекладаються (`five_hour`, `resets_at` тощо).
