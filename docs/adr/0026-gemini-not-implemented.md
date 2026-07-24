---
status: accepted
date: 2026-07-24
---

# ADR-0026: Gemini не імплементуємо — немає ToS-сумісного шляху до споживацької метрики

## Контекст

Епік #60 досліджує розширення TokenPace за межі Anthropic на інших вендорів із **вікнами
використання** (rolling N-годин / тиждень). Першою ціллю обрали **Gemini** (#93) — у нас є тестер із
підпискою (@kintecus), тож розвідку робили на його маку з його креденшалами.

Питання розвідки: чи можемо ми **локально, read-only, без скрейпінгу** читати ліміти Gemini так, як
читаємо для Claude Code, і як безпечно рефрешити токен.

Передумова фічі **підтвердилася**: споживацький Gemini з 2026-05-20 (Google I/O) має **5-годинне
rolling + тижневе** вікно, змодельоване за ChatGPT/Claude
([support.google.com/gemini/answer/16275805](https://support.google.com/gemini/answer/16275805) —
«Your limit refreshes every 5 hours until you reach your weekly limit»). Ліміти **compute-based** і
динамічні: Google публікує лише множники за тарифами (AI Plus 2×, Pro 4×, Ultra 5×/20×), не
абсолютні числа, і «may change without notice». Переглянути — лише в UI: `gemini.google.com` →
Settings → Usage Limits. **Офіційного API для читання власного споживацького usage немає.**

Розвідка виявила **дві незалежні площини** доступу, і жодна не дає одночасно «правильна метрика +
ToS-сумісно + надійно».

### Площина A — OAuth / Code Assist (`retrieveUserQuota`)

Санкціонований токеном шлях, який робить **сам gemini-cli**
([google-gemini/gemini-cli](https://github.com/google-gemini/gemini-cli), перевірено по source):

- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
  (`packages/core/src/code_assist/server.ts`); відповідь — `buckets[]` з `remainingFraction`,
  `resetTime`, `modelId` (`types.ts`) — формально ідеально для пейсингу.
- Авторизація — `Bearer` OAuth `access_token` з `~/.gemini/oauth_creds.json` (0600 plaintext) або
  новішого Keychain-item `gemini-cli-oauth`/`main-account`. `expiry_date` — epoch ms.
- Команда `/stats` (alias `/usage`) показує remaining/limit/reset per-model.
- **Важливо: `refresh_token` НЕ ротується** при рефреші (google-auth-library `oauth2client.ts:878`
  безумовно перезаписує відповідь старим токеном; gemini-cli при збереженні теж лишає старий). Тобто
  самостійний refresh із боку TokenPace **не зламав би** сесію gemini-cli — це знімає головне
  занепокоєння плану (крок 5). Гонка можлива лише при **записі** назад, читання безпечне.

**Але площина A читає «не той» лічильник.** `retrieveUserQuota` віддає квоту **Code Assist / CLI-агента**
(per-model buckets + Google One credits), а не споживацький лічильник додатку. gemini-cli **жодного
разу** не торкається `gemini.google.com` (0 згадок у репо). Мейнтейнер gemini-cli прямо каже, що
навіть у самому CLI «there's no way … to see your daily quota — at least, not yet». Ба більше,
`v1internal` — **недокументований, непідтримуваний** ендпоінт (у практиці віддає 403/SERVICE_DISABLED),
тож і сам по собі «documented means» не задовольняє.

### Площина B — споживацький cookie-replay (`jSf9Qc` batchexecute)

Єдиний шлях до **правильної** метрики (web/app 5h + тиждень). Наскрізний експеримент (@kintecus,
на його маку) підтвердив, що технічно **працює**: розшифрувати Chrome-кукі ключем `Chrome Safe Storage`
з Keychain → дістати `__Secure-1PSID`/`__Secure-1PSIDTS` → зіскрейпити `SNlM0e`/`bl`/`f.sid` зі
сторінки `gemini.google.com/usage` → зіграти внутрішній RPC `batchexecute?rpcids=jSf9Qc`. `fraction`
збігся з UI до відсотка, `reset_epoch` — до хвилини, окремо для 5h і тижневого вікна.

**Проте цей шлях програє за кожною віссю:**

- **ToS.** Gemini Apps Help прямо каже: «The Google Terms of Service and the Generative AI Prohibited
  Use Policy apply to Gemini Apps». Google ToS «Don't abuse our services» забороняє «using automated
  means to access content», «bypassing our systems or protective measures», «reverse engineering our
  services». Google APIs ToS: «You will only access an API by the means described in the documentation
  of that API». Cookie-replay внутрішнього RPC потрапляє під **усі** ці пункти одночасно.
- **Ризик блокування акаунтів.** Мейнтейнери reverse-eng клієнтів (`dsdanielpark/Bard-API`,
  `dsdanielpark/Gemini-API`) **самі** попереджають: «excessive or commercial usage may result in
  restrictions on your Google account». Задокументованого першоджерельного *перманентного* бану суто
  за read-only cookie-replay ми не знайшли (лише попередження + тимчасові rate-limit/CAPTCHA), але
  відсутність доказу — не доказ безпечності.
- **Крихкість.** `__Secure-1PSIDTS` ротується кожні ~10–20 хв (клієнти рефрешать примусово); RPC-id
  (`jSf9Qc` тощо) Google ротує без попередження; запуск клієнта може **знеедити власну browser-сесію**
  користувача в Gemini. Механіка розшифровки Chrome-кукі теж «inherently brittle across Chromium
  changes» (коментар у `SweetCookieKit`).
- **Немає prior-art.** Найближчий аналог TokenPace — **CodexBar** (steipete, ~18.9k⭐, MIT) — читає
  Gemini через **площину A** (OAuth/Code Assist), Antigravity — через локальний `127.0.0.1`-пробінг;
  cookie-механіку (`SweetCookieKit`) застосовує **лише до Claude і Cursor, ніколи до Gemini**. Усі, хто
  читає споживацькі кукі, — **повноцінні чат-клієнти**, жоден не read-only usage-reader. Тобто
  `jSf9Qc`-usage-шлях — це **net-new reverse engineering** внутрішнього RPC, без бази, на яку зіпертися.

## Рішення

**Gemini наразі НЕ імплементуємо.** Головний аргумент — **ризик блокування Google-акаунтів наших
користувачів**: єдиний шлях до правильної (споживацької) метрики — площина B — прямо порушує Google
ToS, а мейнтейнери споріднених інструментів самі попереджають про можливі обмеження акаунта. Ризик
неприйнятний для застосунку, що працює на реальних акаунтах користувачів, тим більше без офіційного
API, стабільного контракту чи prior-art.

Площину A (OAuth/Code Assist) теж не беремо: вона **читає інший лічильник** (квоту CLI-агента, не
додатку), тож не дає обіцяної фічі, і сама спирається на недокументований `v1internal`.

Це рішення **лише про Gemini**, не про multi-vendor загалом. Напрямок #60 лишається живим —
**наступний кандидат — OpenAI Codex** (5h + тижневе вікно, локальний токен у `~/.codex/`), який треба
дослідити окремим тікетом за тим самим лекалом розвідки.

## Наслідки

- #93 закривається як *not planned* із підсумковим вердиктом; #60 (епік multi-vendor) лишається
  **відкритим** — Codex ще попереду.
- Vendor-абстракцію (провайдер = endpoint + auth source + usage decode + window model), окреслену в
  #60, **не будуємо зараз** — її вводитиме той вендор, який реально пройде розвідку (ймовірно Codex).
- Якщо колись Google **офіційно** відкриє API для споживацького usage — рішення переглядається; до
  того часу cookie-replay-канал закритий за дизайном.
- Позитивний технічний висновок для *будь-якого* майбутнього OAuth-вендора: якщо його CLI не ротує
  `refresh_token` (як gemini-cli), делегований refresh не обов'язковий — можливий і безпечний
  самостійний refresh на читання (пор. делегований підхід для Claude, [ADR-0017](0017-delegated-token-refresh.md)).

## Пов'язані

- [ADR-0017](0017-delegated-token-refresh.md) — делегований refresh токена (Claude); тут зафіксовано,
  що для gemini-cli самостійний refresh був би безпечним (refresh_token не ротується).
- [ADR-0019](0019-token-read-via-security-cli.md) — читання секретів через `security` CLI; аналогічний
  Keychain-доступ був би потрібен і для gemini-cli-креденшалів, якби ми йшли площиною A.
- #60 — епік multi-vendor (лишається відкритим, наступний кандидат — Codex).
- #93 — розвідка Gemini (закрита цим рішенням).
