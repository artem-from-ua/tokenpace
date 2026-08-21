---
status: accepted
date: 2026-07-26
---

# ADR-0037: Money credits model (extra usage) — `spend` as primary, trigger and pacing like the token bars

> Decisions made during spike [#142](https://github.com/artem-from-ua/tokenpace/issues/142) (the live
> API shape) and a product interview; the decode model + pacing were implemented in
> [#143](https://github.com/artem-from-ua/tokenpace/issues/143). UI — menu bar
> [#144](https://github.com/artem-from-ua/tokenpace/issues/144) / dropdown
> [#145](https://github.com/artem-from-ua/tokenpace/issues/145). Epic — [#141](https://github.com/artem-from-ua/tokenpace/issues/141).

## Context

The Claude Code subscription has **paid top-up credits** ("usage credits" / extra usage): once a user
hits a plan limit, further spend can draw from a money balance (in the account's currency), optionally
capped by a monthly limit (`Monthly spend limit`). TokenPace needs to show this:

- in the **menu bar** — an international currency glyph that appears only when the user is **currently
  actually spending credits**; its color follows pacing and is gated by `calmMenuBarColors`;
- in the **dropdown** — a separate "Extra usage" section with amount spent, the limit, and pacing
  status.

Until now the decoder (`UsageSnapshot`, [ADR-0014](0014-usage-decode-resilience-on-reset-boundary.md))
deliberately **ignored** the `spend` / `extra_usage` blocks — they were silently tolerated as unknown
keys.

Spike #142 captured **5 live states** of `GET /api/oauth/usage` (the maintainer's account, EUR
currency), varying `Monthly spend limit`: out-of-credits, enabled-within-limit, near-cap,
limit-below-spent (an overshoot), unlimited. The verbatim bodies are saved as regression fixtures in
`UsageClientTests.swift`. This data surfaced several non-obvious facts that call for a pinned decision.

### What the API showed

Two parallel blocks; **`spend` is newer and cleaner**, `extra_usage` is older with extra fields:

```jsonc
"spend": {
  "used":  {"amount_minor": 1077, "currency": "EUR", "exponent": 2},   // a money OBJECT
  "limit": {"amount_minor": 1500, "currency": "EUR", "exponent": 2},   // a money object OR null (unlimited)
  "percent": 72, "severity": "normal", "enabled": true,
  "cap": {"money": {…}, "credits": null},                              // or null
  "balance": null, "auto_reload": null                                 // ALWAYS null on this endpoint
},
"extra_usage": {
  "is_enabled": true, "monthly_limit": 1500,       // a scalar (minor units), or null
  "used_credits": 1077.0,                           // = spend.used; the source of truth for what was spent
  "utilization": 71.8,                              // a float %, or null when there's no limit
  "currency": "EUR", "decimal_places": 2,
  "spend_limit_reached": false, "credits_ever_enabled": true, …
}
```

Key observations from the spike:

1. **Money is `{amount_minor, currency, exponent}` objects** (`spend.used`, `spend.limit`,
   `spend.cap.money`), not scalars. `extra_usage.monthly_limit` is the opposite — a bare number in
   minor units.
2. **The currency is not USD** — the maintainer's account is in EUR. Hardcoding `$` is not an option.
3. **The server caps `percent` / `utilization` at 100** — at spent 10.77 / limit 5.00 it returns
   `percent: 100`, not 215. The real overshoot is only visible through `spend_limit_reached` plus
   comparing `used_credits` against `limit`.
4. **When the money limit is exceeded, the server sets `spend.enabled: false`** (plus
   `spend_limit_reached: true`, `disabled_reason: "org_level_disabled_until"`) — credits auto-disable.
5. **`balance` / `auto_reload` are always `null`** across every state. The current balance shown by
   Claude's web UI (€10.00) **does not arrive** via `/api/oauth/usage` — walking the whole payload tree
   found nothing. It lives on a different (billing / member-dashboard) endpoint, unreachable from
   TokenPace. **Verified in both auto-reload states** (2026-07-26): turning Auto-reload on in Settings
   (UI "On") **does not change the payload** — `balance`/`auto_reload`/`cap.credits` stay `null`; a
   field existing in the schema does not mean the data exists.

5-bis. **`cap` duplicates `limit`; `cap.credits` is always `null`.** In every state `spend.cap.money`
   **equals** `spend.limit` (the same spend ceiling — the monthly money limit), while `cap.credits`
   (a ceiling in *credits*, not money) is always `null`. So **there is no point triggering on `cap`** —
   it carries no signal beyond `limit`, which we already use (`used/limit`). `cap.credits != null` is a
   hypothetical future case — a "ceiling in credits" — that we have not observed; out of scope.

## Decision

1. **`spend` is the primary source; `extra_usage` supplements it.** We model `spend` (the cleaner,
   structured-money block). From `extra_usage` we take only what `spend` lacks: `used_credits` (the
   source of truth for what was spent — it duplicates `spend.used`), `decimal_places`,
   `spend_limit_reached`, `currency` as a fallback.

2. **Money is a separate Kit type, `{amount_minor: Int, currency: String, exponent: Int}`**, not a
   `Double`. Money precision matters; a float would introduce rounding errors. Formatting the amount
   (accounting for `exponent` / `decimal_places` and currency) happens in the view (shell); the type
   itself stays AppKit-free.

3. **Tolerant decode** in the style of [ADR-0014](0014-usage-decode-resilience-on-reset-boundary.md):
   `decodeIfPresent` plus forward-compat defaults, the new field in the memberwise init with a default
   of `nil`. A missing or unrecognized shape of `spend`/`extra_usage` **does not break** the snapshot
   (as before). Existing fixtures keep passing unchanged.

4. **The icon trigger is `spend.enabled == true` OR `spend_limit_reached == true`** (not just
   `enabled`). Rationale: the server flips `enabled` off at exactly the moment the money ceiling is
   exceeded (fact 4) — i.e., exactly when the "you've hit the money ceiling" signal matters most. A
   rule keyed on `enabled` alone would hide the icon at that very moment. Display is additionally
   gated by real credit usage (at least one baseline limit — 5h/7d/scoped — exhausted, which is when
   spend actually draws from credits).

5. **The icon color is computed the SAME WAY as the token bars — `usage` vs `time`, the server's
   `spend.severity` is IGNORED.** `CreditsPacing.barLayout(...)` returns the same `BarLayout` as the
   5h/7d bars, so the view paints the icon with the same `PopupBarView.aheadColor(usage:time:)`: green
   (on pace) → yellow (slightly ahead) → orange (well ahead) → **red only once the limit is actually
   hit**. The axes:
   - `usageFraction = used_credits / limit`;
   - **`timeFraction` = the fraction of the calendar month elapsed, from 00:00 UTC on the 1st.** The
     money window is the calendar month in UTC — confirmed by the official [Anthropic Spend Limits API
     docs](https://platform.claude.com/docs/en/manage-claude/spend-limits-api) ("monthly spend resets
     at 00 UTC on the first of each calendar month"). The API **gives no** reset time for money
     (fact 5-bis: `spend`/`extra_usage` carry no time fields), so `timeFraction` is computed locally
     (`monthElapsedFraction`, TZ injected, defaulting to UTC — unlike the token windows, whose reset
     time `ResetClock` shows in the **local** TZ). `spend_limit_reached` (or `used >= limit`) forces
     `usageFraction = 1` → `aheadColor` returns red. This is deliberately NOT a separate severity
     formula with a "% of ceiling" threshold — the color stays consistent with the rest of pacing 1:1.
     Calm-color suppression under `calmMenuBarColors` applies as it does for the bars (#105).

6. **The pacing baseline is the LIMIT only. Balance-based logic is out of scope.** Since `balance` is
   unavailable (fact 5), any "relative to balance" computation is impossible:
   - **a limit is set** → pacing relative to the limit (`used / limit` × month elapsed), just like the
     ordinary bars;
   - **no limit is set** (unlimited, `limit == null`) → **no pacing / no bar**, just the amount spent
     (no ceiling → no `usageFraction` → `barLayout` returns `nil`).
   Balance / auto-reload / top-ups — **a separate future feature**, once (and if) we find a data source.

7. **The pure/shell split — as everywhere** ([ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md)):
   the decode model and pure `CreditsPacing` (trigger + `barLayout` usage-vs-time +
   `monthElapsedFraction`) live in `TokenPaceKit` (AppKit-free, unit-tested); mapping `BarLayout` →
   color (the shared `aheadColor`), the currency SF Symbol, and amount formatting live in the shell
   (`StatusItemView` / `PopupViewController`).

## Consequences

- **Decode becomes richer but stays backward compatible.** Old payloads without `spend`/`extra_usage`
  (and every existing test fixture) decode unchanged — the new field is optional.
- **The icon honestly signals a limit overshoot** (red/exhausted even when the server has turned
  `enabled` off), instead of disappearing at the moment it matters most.
- **No dependency on server-side severity** — a smaller surface for regressions if the server changes
  its internal thresholds; the cost is that our own thresholds must be kept consistent with the bars
  (one source — `PacingSeverity`).
- **Currency-agnostic**: the amount always carries `currency`+`exponent`, the icon is a generic
  currency glyph (e.g. `coloncurrencysign` ¤), not `$`. Works for EUR and any other account currency.
- **A deliberate gap: no balance.** For now TokenPace does not show the current balance / auto-reload —
  even when Claude's web UI does. This is a documented endpoint limitation, not an oversight. Once
  access to a balance source appears, it gets its own ADR.
- **The money window's `resets_at`** was not observed as a separate payload field (the web UI shows
  "Resets Aug 1"); the source for the reset time behind the "time to reset limit" line in the dropdown
  is worked out in #145 — if no source exists, the line is omitted. This does not block the decode
  model.

## Alternatives considered

- **Trust the server's `spend.severity`** — rejected: opaque thresholds, inconsistency with the rest of
  the pacing colors, and a dependency on server-side changes (72%→normal, 98%→critical observed — noted
  for reference, not used).
- **Keep money as a `Double` (in major units)** — rejected due to rounding errors; structured money is
  exact and matches the API's own shape.
- **Implement balance-based computation from an estimate** — rejected: no balance data exists, and any
  estimate would be a fabrication that misleads on exactly the topic of money.
