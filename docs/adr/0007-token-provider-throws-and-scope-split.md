---
status: accepted
date: 2026-06-22
---

# ADR-0007: TokenProvider — `throws`+enum, чистий шар декодування і розбивка обсягу #8

> **Постскриптум (2026-07-06):** частину про **fallback-refresh (PR 8b)** — самостійний
> `refresh_token` grant + write-back у Keychain через `SecItemUpdate` — замінено на делегований
> refresh через `claude` CLI. Див. [ADR-0017](0017-delegated-token-refresh.md). Решта рішень цього
> ADR (розбивка 8a/8b, `throws`+`TokenError`, чистий `decode(from:)`, «протухлий токен не йде на
> API») лишається чинною — тому запис у цілому **не** застарілий і в індексі не закреслюється.

## Контекст

Issue #8 описує `TokenProvider` як «читання OAuth-токена з Keychain **+ fallback-refresh**». Це два
дуже різні за ризиком шматки:

- **Читання + декодування + валідність** — локальне, детерміноване, не торкається мережі й не може
  зашкодити робочому токену. Формат айтема підтверджено фактично (`security find-generic-password`):
  `class: genp`, `svce: "Claude Code-credentials"`, payload — JSON з обгорткою `claudeAiOauth`
  (`accessToken`, `refreshToken`, `expiresAt` у **мілісекундах**, `scopes`, `subscriptionType`,
  `rateLimitTier`); `acct` — ім'я користувача, **системозалежне**.
- **Fallback-refresh** — головний техризик Фази 1 (SPEC «Відкриті питання», рядки 270–273, 287):
  `refreshToken` може бути одноразовим і **інвалідувати живий робочий токен**, тож перевіряється
  лише на *тестовому* Max-акаунті; точні `client_id` / refresh endpoint / форма PKCE **не
  підтверджені**. Писати робочий код навколо невідомих констант передчасно.

Окремо постало питання стилю помилок. Наявна чиста логіка (`ResetClock.parse`, `PacingModel`)
повертає optional / clamped-значення, бо там **єдина** причина відмови — «не парситься». У
`TokenProvider` причин кілька й вони несумісні (немає айтема / ACL відмовив / інший `OSStatus` /
зламаний JSON / токен протух), і кожна веде до **іншої реакції** (пояснити «Always Allow» vs
«запустіть Claude Code» vs чекати на свіжий токен).

Це той самий клас рішення про межі модуля, що й [ADR-0005](0005-pacing-fractions-not-blocks.md) і
[ADR-0006](0006-reset-time-absolute-vs-relative.md): свідомо вирішуємо, що модуль робить, а що —
сусідній шар.

## Рішення

1. **Розбити #8 на два PR.** PR 8a (цей) — читання + декодування + валідність; повністю чистий,
   юніт-тестований, безпечний. PR 8b — fallback-refresh, після перевірки на тестовому акаунті.
   8a розблоковує `UsageClient` (#9) негайно, не чекаючи на ризиковану мережеву частину.

2. **`throws` + типізований `enum TokenError`** замість optional. Кейси: `itemNotFound`,
   `accessDenied(OSStatus)`, `keychainError(OSStatus)`, `malformedData`, `expired`. `Result`
   відкинуто: проєкт асинхронний (UsageClient — async/await), `throws` природно компонується з
   `async throws` без `.get()`-обгорток.

3. **Чистий шар `decode(from data:) throws` окремо від Keychain I/O.** Увесь розбір формату
   (обгортка `claudeAiOauth`, `expiresAt` ms→`Date`, відсутні опційні поля) тестується юнітами без
   Keychain — це ядро acceptance-критеріїв. Keychain I/O (`SecItemCopyMatching`, матч **лише за
   service**) — тонка обгортка, що мапить `OSStatus` у `TokenError`; не юніт-тестується (ручна
   перевірка).

4. **Протухлий токен ніколи не йде на API.** Поки немає refresh (8a),
   `currentAccessToken(now:)` кидає `.expired` і **не повертає** старий `accessToken` — це уникає
   гарантованого 401 і марного палення rate-limit. Polling-шар (#9/#13) трактує `.expired` як
   «чекати на свіжий токен» і періодично перечитує Keychain, поки Claude Code (запустившись) не
   перезапише айтем. `TokenProvider` лишається stateless і таймера не тримає.

## Наслідки

- Безпечна частина мерджиться й розблоковує #9, не блокуючись ризикованим refresh.
- UI може розрізнити причини відмови (`accessDenied` → інструкція «Always Allow»; `itemNotFound` →
  «запустіть Claude Code»; `expired` → очікування) замість одного безликого `nil`.
- `decode(from:)` повністю покрито unit-тестами (валідний payload, ms→Date, відсутні поля, без
  обгортки, garbage, порожні дані, `expiresAt` рядком); контракт «не віддавати протухлий токен»
  теж під тестом через `accessTokenIfValid(_:now:)`.
- Токен ніколи не логується: `AppLogger.keychain` несе лише `.public`-діагностику (`OSStatus`,
  довжина токена, факт `expired`).
- PR 8b додасть `refreshAndStore` (async, інжектований transport), чисту `buildRefreshRequest`
  (тестовану: POST, `application/x-www-form-urlencoded`, `grant_type=refresh_token`) і `writeBack`
  через `SecItemUpdate`, не переписуючи 8a. Якщо `refreshToken` виявиться одноразовим або
  endpoint/client_id зафіксуються — це нове рішення → нова секція тут або окремий ADR.
- Ручна перевірка діалогу ACL (unsigned-білд: один раз чи повторюється) лишається поза автотестами
  (acceptance #8) і не блокує merge чистих тестів.
