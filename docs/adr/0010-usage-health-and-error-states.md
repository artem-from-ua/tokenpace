---
status: accepted
date: 2026-06-22
superseded_by: [0091]
---

# ADR-0010: UsageHealth — error states (⚠️ in the menu bar + a popup banner + stale)

> **Partially superseded by [ADR-0091](0091-countdown-only-where-work-is-not-running.md).** The three
> error phases became two: the middle one ("⚠️ next to the old bars", 30–60 min) was dropped along
> with `hideBarsAfter`, and the glyph threshold is now counted in attempts —
> `UsageHealth.glyphAfter(for:)` = `max(15 min, 3 × pollInterval)` instead of a flat 30 minutes; a 429
> no longer writes `failingSince`. What still stands is `FailureReason`, "the popup warns immediately,
> with no threshold", and the two-input model itself (`UsageSnapshot` + `UsageHealth`).

## Context

Issue #12 ("Error states") makes failures visible to the user. Until now any failure
(`TokenError` / `UsageError`) was only **logged** through `AppLogger` — nothing changed in the menu
bar or the popup. The SPEC ("Error states / missing authorization") and the refinements that followed
require:

- in the menu bar — a ⚠️ icon when polling has been failing for a while;
- in the popup — an explanation of the error **immediately** (no waiting), while keeping the last
  known data (stale) with a staleness label;
- no macOS notifications.

The scope was deliberately limited to **a pure model plus UI rendering plus unit tests**: the live
polling loop that produces real errors arrives in #13 (`App.swift` is still on a mock). The extension
points were reserved in advance — `MenuBarMode` (ADR-0009 point 3) and `PopupLayout`.

Several module-boundary decisions follow — the same class as in ADR-0005/0007/0008/0009:

1. **How to feed "the state of polling" (success/failure/when it started) into the pure models**
   without mixing it into `UsageSnapshot` (the data) and without bringing a timer into pure logic.
2. **How to express failure-duration thresholds** so they are deterministic and testable without a
   clock.
3. **How to tell stale (showing old data) apart from error (showing ⚠️)** in the menu bar.
4. **How to convey the failure's reason to the view** without leaking diagnostic details (`OSStatus`,
   the HTTP code, the body).
5. **How to draw the ⚠️** in a non-template, `isFlipped` menu bar image.

## Decision

1. **A separate pure value type, `UsageHealth` (in `CCTimerKit`), as the layout factories' second
   input.** `lastSuccess: Date?` / `failingSince: Date?` / `reason: FailureReason?`. The layout
   factories gain a `make(from: UsageSnapshot?, health:, now:)` overload alongside the existing healthy
   factories (which stay unchanged and are reused by the #10/#11 tests and by loop #13). Health is
   **separate** from `UsageSnapshot`: the snapshot describes the *data*, health describes the *state of
   obtaining it*. This mirrors injecting `now` everywhere (ADR-0009): `UsageHealth` has no clock of its
   own.

2. **The thresholds are pure functions of `failureAge(now:) = now − failingSince`, fixed, with strict
   boundaries.** Three menu bar phases (refined with the user, finer than the SPEC's single 30-minute
   step):
   - `age ≤ 30 min` with a snapshot present → **stale bars** (as `.expanded`), no ⚠️ — the data is
     still fresh enough;
   - `30 min < age ≤ 60 min` → **⚠️ plus the last bars** plus the reset time (dynamic width);
   - `age > 60 min`, **or a cold start** (no snapshot) → **the ⚠️ alone** — the data is too stale, or
     there is none.

   The constants are `glyphAfter = 30*60` and `hideBarsAfter = 60*60`. The boundaries are **strict**
   (`>`), like `idleUtilizationThreshold` (ADR-0009) and `PacingModel`'s `> 90`: exactly 30:00 still
   shows bars, exactly 60:00 still shows them with bars. Covered by boundary tests.

3. **Stale renders through the existing `.idle`/`.expanded`; the error gets one new
   `MenuBarMode.error` with optional bars.** `case error(fiveHour: BarView?, sevenDay: BarView?,
   reset:, which:)` — every value is `nil` together (the ⚠️ alone) or none of them is (⚠️ plus bars).
   The menu bar does **not** distinguish stale from fresh (old bars look the same); staleness is
   visible only in the popup (its status line). There is no separate `.stale` case — it would be a
   redundant branch.

4. **The reason maps into a semantic `FailureReason` (in `CCTimerKit`); the view assembles the
   string.** `TokenError`/`UsageError` carry details that are not for the user (`OSStatus`, the HTTP
   code); `FailureReason` (`notSignedIn` / `authHTTP(status:body:)` / `timeout` / `cannotResolveHost` /
   `network` / `serverProblem` / `unknown`) is a semantic signal, like `PacingState`/`TimeToReset`.
   `init(_:)` is an exhaustive `switch` **with no `default`** (a new error case breaks the build → a
   deliberate mapping). The localized text (`warningTitle`/`warningDetail`) lives in
   `PopupViewController` (the seam, ADR-0009). `http(401/403)` → `.authHTTP`, other codes →
   `.serverProblem`. The popup shows **two lines**: a bold title (for HTTP — `Auth error (HTTP <code>)`)
   and a detail (for HTTP — the server's response body).

5. **`UsageError` was extended to carry text through to the popup.** `http(status:)` →
   **`http(status:body:)`** (the response body, `.public`-safe — it is the *response*, not the request,
   so it carries no token; truncated to `maxBodyLength`). `transport(String)` →
   **`transport(message:code:)`** with a `URLError.Code?`, so timeout / DNS / other can be told apart
   **deterministically** (rather than by parsing a `localizedDescription` string that depends on the
   locale). `URLError.Code` is `Sendable`/`Equatable`, so `UsageError` remains both.

6. **The ⚠️ is a monochrome SF Symbol, `exclamationmark.triangle`, in the font's color
   (`labelColor`) — not an emoji and not a fill.** In the font's color (like the `*` idle glyph) so it
   matches the menu bar's text and tracks the theme (resolved through the existing
   `snapshotImage(appearance:)` plus KVO infrastructure from ADR-0009 point 9). Outlined (`.triangle`,
   not `.triangle.fill`) — the exclamation mark reads even as a solid fill. It is drawn with
   `respectFlipped: true`: the view is `isFlipped`, so a plain `draw(in:)` would mirror the image
   vertically (the triangle came out upside down and "wrong"). It is centered on `rect.midY` — sharing
   a vertical center with the bar block.

7. **Popup: the error banner sits right below the title, with the blocks separated by horizontal
   rules.** `PopupLayout` gains `warning: FailureReason?` (defaulting to `nil` in the memberwise init —
   backward compatible with #11's tests and call sites), set on **any** failure (`isFailing`), with no
   30-minute threshold — the popup warns immediately (SPEC). The order in `PopupViewController`: title
   → rule → *(on failure)* the two-line banner → rule → the status lines (Last update / interval) →
   rule → the limit sections. Each rule has symmetric padding around it (`separatorPadding`).
   `lastUpdateAge` is measured from `health.lastSuccess` (staleness is visible); `rows` come from the
   stale snapshot (empty on a cold start, leaving the banner standing alone).

8. **No `UserNotifications`.** A deliberate SPEC decision: the whole signal lives in the menu bar plus
   the popup. #12 adds no system notifications.

## Consequences

- All of the error-state logic is covered by unit tests without AppKit: `UsageHealthTests` (mapping
  **every** case of `TokenError`/`UsageError`, boundary HTTP codes, the body in `.authHTTP`,
  `failureAge`, the thresholds), complemented by `MenuBarLayoutTests` (the three-phase boundaries at
  30:00 / 60:00, the cold start) and `PopupLayoutTests` (the immediate warning, stale rows,
  `lastUpdateAge`). Drawing the ⚠️ and the banner was verified by eye (`swift run` with the
  `App.demoMode` demo switch).
- `CCTimerKit` stays free of AppKit: `UsageHealth`/`FailureReason` carry only semantics; the mapping to
  colors and symbols lives in `cc-timer`. Reuse in Phase 2 is preserved.
- `UsageError` now carries more context (`body`, `URLError.Code`) — #9's existing tests were updated.
  The extension is deliberate: those fields are needed for precise user-facing text.
- Wiring this to **live** errors is #13's job: the loop builds a `UsageHealth` from real polling results
  (success → `healthy`, failure → `failingSince`/`reason`) and passes it into the same factories — #12's
  models and views stay unchanged.
- `MenuBarMode`/`PopupLayout` now cover every Phase 1 state; later rendering changes (Phase 2, SwiftUI)
  reuse the pure models and replace only the shell.

## Related

- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — the pure/shell split, appearance, and
  `MenuBarMode` left open for this `.error`.
- [ADR-0008](0008-usageclient-pure-backoff-and-transport-seam.md) — `UsageError`, extended here.
- [ADR-0007](0007-token-provider-throws-and-scope-split.md) — `TokenError`, mapped into
  `FailureReason`.
