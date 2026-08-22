---
status: partially superseded
date: 2026-07-22
superseded_by: [0117]
---

# ADR-0020: The Troubleshoot window and a diagnostics channel through a pure pipeline

> **Postscript (#475).** §3's *visibility* decision no longer holds. It made "Settings…" a normal,
> always-visible item with "Troubleshoot…" as the sole ⌥-gated one;
> [ADR-0117](0117-dropdown-actions-behind-option.md) gates **every** action item the same way and
> puts a caption where the column was. **§3's mechanism is untouched and still current** — the
> modifier-polling timer, and the two findings that force it: `isAlternate` is inert in a
> status-item menu, and an event monitor is starved by menu tracking. 0117 changed what the timer
> reveals, not how it reveals it.

> **Postscript.** §4 below says `setFrameAutosaveName` remembers the window's size/position
> between openings. This was removed: the window now opens centered by default with a fixed
> starting size every time (autosave was dropped, the starting size grew to 840×720). The reason is
> the same as for the Settings window (see the postscript on ADR-0035): a saved frame survives a
> display-configuration change and opens the window off-screen. The window remains resizable within
> a session, but its size/position are no longer persisted.

## Context

Until now, the only way to diagnose problems with usage API polling was to read `log stream` in a
terminal. The popup shows only aggregated data (health, "Updated N min ago"), and the raw API
response is discarded after decoding: `UsageClient.fetch` logged the body and returned only a
`UsageSnapshot`; the body of HTTP errors was truncated to 500 characters (`maxBodyLength`), and the
body for 429s and decode errors wasn't kept at all. Auth-token metadata (when it was read, when it
expires) was recorded nowhere: `TokenProviding.currentAccessToken` returned only a `String`, and the
`expiresAt` from the Keychain was discarded right after the validity check.

We're adding a hidden diagnostic entry point: in the status item's dropdown, the **Settings…** item
is always visible, while **Troubleshoot…** is a separate item **below it**, hidden by default and
shown only while **⌥ Option** is held down. It opens a large, resizable window with three sections
— **Update interval** (the current cadence as a duration + the time of the next update + a
force-refresh button), token metadata (read time, expiry time), and the raw last usage API response
(pretty-printed JSON or the error payload + HTTP status). The content **updates live** on every
polling cycle.

This produces the same class of decision as ADR-0009…0011 (where a module's boundary lies — what's
pure, what's shell).

## Decision

1. **Diagnostics flow through a pure pipeline, not a shell-side sink.** A new type,
   `PollDiagnostics { fetch: FetchDiagnostics, token: TokenDiagnostics? }`, is built in the core
   (`pollOnce`) and flows `DiagnosedFetch` → `PollResult` → `PollOutput.diagnostics` →
   `AppDelegate` → the window — the same path health/snapshot already take. `PollState` is **not**
   touched: diagnostics describe the *last attempt*, not accumulated state; each iteration produces
   exactly one `PollOutput`, and `AppDelegate.lastOutput` already holds the latest one.

   `UsageClient.fetch` was refactored: its body moved into
   `diagnosedFetch(accessToken:now:transport:) -> DiagnosedFetch`, which in every branch (200 / 429
   / other non-2xx / decode failure / transport / non-HTTP / not-sent) builds a `FetchDiagnostics`
   with the **full** body. `fetch` became a wrapper
   (`try (await diagnosedFetch(...)).result.get()`) — its signature and every existing `FetchTests`
   test are unchanged. The 500-character cap remains only for `UsageError.http` (the popup); the
   diagnostic copy of the body is full, untruncated, and is also captured for 429s and decode errors
   (previously these bodies were lost).

   The alternative — "the window reads `TokenProvider.credentials()` / the last `UsageError`
   directly" — was rejected: it bypasses the pure pipeline, duplicates Keychain reads, and the data
   wouldn't update naturally alongside polls.

2. **Token metadata — a replacement method on the `TokenProviding` protocol; the expiry decision
   moves into the engine.** `currentAccessToken(now:) throws -> String` becomes
   `currentCredentials(now:) throws -> TokenCredentials` (`{ accessToken, expiresAt }` plus the
   predicate `isExpired(now:)`). The provider no longer **throws `.expired`** — the staleness
   decision now lives in `pollOnce` (right where the delegated refresh and its gate already live).
   The payoff:
   - **one** Keychain read per poll (the `security` subprocess, ADR-0019 — a second read would be
     redundant and race-prone);
   - `expiresAt` is available even for an **expired** token — the most valuable diagnostic case
     ("went stale at HH:MM and hasn't refreshed yet");
   - ADR-0007's contract "an expired token never goes over the network" is preserved — the engine
     now guarantees it.

   **Security:** only dates flow through `PollOutput`/the UI (`TokenDiagnostics { readAt,
   expiresAt }`) — no token strings; `TokenCredentials` deliberately carries **no** `refreshToken`
   (the secret is never pulled into the engine). `TokenError.expired` stays in the enum (the
   `FailureReason` mapping is unchanged), it's just built by the engine now, not the provider. The
   `token expired, len=<count>` log line (unchanged text) moved from
   `TokenProvider.accessTokenIfValid` into `PollingEngine.pollOnce` along with the check.

3. **Two separate menu items; ⌥ shows/hides Troubleshoot via `isHidden`, driven by a
   modifier-polling timer — not the native `isAlternate`, not `NSMenuDelegate.menuNeedsUpdate`.**
   "Settings…" is a normal, always-visible item with its own selector, `openSettings`;
   "Troubleshoot…" is a separate item directly below it with its own `openTroubleshoot`, with
   `isHidden = true` by default. While the menu is open, `optionPollTimer` reads the live ⌥ state
   and sets `troubleshootItem.isHidden`.

   **Why not the native `isAlternate` (verified — not from memory):** `NSMenu`'s alternate-item
   mechanism (the Finder "About This Mac" → "System Information…" pattern) is **inert inside a
   status-item menu** — the item doesn't toggle under the modifier. **Why not an event monitor:**
   `NSMenu` tracking spins a modal `NSEventTrackingRunLoopMode`, which starves
   `addLocalMonitorForEvents(.flagsChanged)` (verified: the monitor never fired during tracking).
   So the reveal is driven by a timer added to the `.common` run-loop modes (so it still fires
   during modal tracking), polling `NSEvent.modifierFlags` every 50 ms — `menuWillOpen` starts it,
   `menuDidClose` kills it and hides the item again.

   `keyEquivalent` is **empty** on every item — there are no shortcut glyphs (⌘, / ⌘Q) in the
   dropdown (there's also no main menu to host them). So ADR-0012 §7's note, "no default ⌘Q," still
   stands. An earlier revision of this ADR described a native alternate-swap with a ⌘,-glyph on
   "Settings…," but the implementation always used the modifier-polling path; this entry has been
   brought in line with the code.

4. **The window is at the normal level (`.normal`), not `.floating` — a deliberate departure from
   ADR-0012 §6.** Floating conflicts with a full-screen Space, and a large always-on-top window is
   hostile to the user. `styleMask` includes `.resizable`/`.miniaturizable`,
   `collectionBehavior = [.fullScreenPrimary]` (the green button → native fullscreen in its own
   Space), and `setFrameAutosaveName` remembers size/position. `NSApp.activate(ignoringOtherApps:
   true)` in `show()` is enough to bring an accessory app's window to the front. The ADR-0012 §6
   pattern for the small `.floating` Settings window still stands — this is a different class of
   window.

   **Timestamp format** — fixed, stable for bug reports: `2026-07-22 14:32:05 (Europe/Kyiv)`
   (`yyyy-MM-dd HH:mm:ss`, locale `en_US_POSIX`, an injected `timeZone` defaulting to `.current`,
   the time zone identifier in parentheses). A deliberate departure from the localized
   `ResetClock.absoluteString` — diagnostics need to be unambiguous. The time of the next update
   uses the same fixed format with a `≈` prefix (wake / network recovery can trigger a poll
   earlier).

5. **The "Update interval" section, plus a force-refresh button via a new
   `PollSignal.manualRefresh`.** The current cadence is broken out into its own window section: the
   line `Refresh interval: 3m` (a duration, from the pure `TroubleshootLayout.durationText`) above
   `Next update: ≈ <timestamp>` (the same fixed format). The **"Refresh now"** button **forces both**
   data streams to update: `AppDelegate.forceRefresh()` sends a new `PollSignal.manualRefresh`
   signal into `SignalHub` (the usage loop polls immediately — like `.wake`/`.networkRestored`)
   **and** resets `lastStatusSuccess = nil`, so the status poll, which rides the usage poll's
   heartbeat, is `isDue` again on that same immediate tick.

   Unlike `.wake`/`.networkRestored`, `.manualRefresh` **resets the active 429 backoff** to the base
   180 s: in the cycle where `waitForNextPoll` returns `.interrupted(.manualRefresh)`,
   `state.backoff` is reset (`.reset()`) **before** the immediate poll. This is a deliberate
   decision — a manual user action outweighs rate-limit caution (ADR-0008): the user accepts the
   risk of a new 429. `LivePollScheduler` carries any signal other than `.sleep` as `.interrupted`,
   so a new branch is only needed to reset the backoff; `waitWhileAsleep` ignores `.manualRefresh`
   (a sleeping Mac doesn't poll). Tests cover both the backoff reset
   (`manualRefreshResetsBackoffToBaseInterval`) and the duration format (`durationText`).

## Consequences

- `TokenPaceKit` gains two new pure types: `FetchDiagnostics`/`TokenDiagnostics`/`PollDiagnostics`/
  `DiagnosedFetch` (the diagnostics channel) and `TroubleshootLayout` (a view model, now with an
  `intervalLine` field plus the pure `durationText`). Both are free of AppKit → reusable in Phase 2,
  covered by unit tests (`UsageClientTests` — a new `diagnosedFetch` suite; `TroubleshootLayoutTests`
  — `prettyPrinted`/`timestampText`/`durationText`/`make`; `PollingEngineTests` — asserting
  diagnostics, preserving the "an expired token never goes over the network" contract, and the
  backoff reset on `.manualRefresh`). `PollSignal` gains the case `.manualRefresh` (immediate poll +
  429 backoff reset).
- `TroubleshootWindowController` (`TokenPace`) — a thin shell modeled on
  `SettingsWindowController`, but at the `.normal` level; `render(_:)` is called from
  `AppDelegate.apply(_:)` **on every poll**, so an open window updates all three sections in place
  (the body is only assigned when it changed — so selection/scroll position doesn't jump). The
  "Refresh now" button calls `onForceRefresh` → `AppDelegate.forceRefresh()`.
- **Copying the body + cursor/navigation (a later addition).** The usage-API section's header
  carries a borderless icon button (`doc.on.doc`) on the right — `copyBodyClicked` puts
  `bodyTextView.string` on `NSPasteboard.general` (the first use of `NSPasteboard` in the codebase).
  Besides the button, the body now has a **blinking cursor and arrow-key navigation**, and supports
  `⌘C`/`⌘A`/`⌘X` over a selection. This was achieved with two decisions, both stemming from the
  accessory app deliberately having no `mainMenu` (see §3):
  - The body `NSTextView` is **editable, but every change is vetoed** by the delegate
    (`shouldChangeTextIn → false`). `isEditable = false` gives neither a cursor nor arrow-key
    navigation — only editable mode enables them; the veto keeps the content unchanged
    (typing/paste/drag-insert all go through this single choke point; the programmatic
    `setAttributedString` in `render` bypasses it).
  - `⌘C`/`⌘A`/`⌘X` is handled by **`ReadOnlyTextView.performKeyEquivalent(_:)`**, matched on
    `keyCode` (layout-independent — on a Ukrainian layout the C/A keys produce "с"/"ф," so matching
    on the character would miss). Without an Edit menu these key equivalents wouldn't resolve any
    other way: the pass falls through to `noResponderFor:` → `NSBeep`, and no copy happens.
    Intercepting the same phase and returning `true` **both** performs the copy **and** silences
    the beep. `⌘X` is reduced to a copy (the view is read-only). We deliberately do **not** add
    `NSApp.mainMenu` just for `⌘C` — a menu bar row at the top of the screen shouldn't appear for a
    background accessory widget.
- **Logging:** one new line, `manual refresh requested (Troubleshoot)` (`lifecycle`, `.notice`), was
  added from `AppDelegate.forceRefresh()`; the line `token expired, len=<count>` is now emitted from
  `PollingEngine.pollOnce` rather than `TokenProvider` (text, category, and level unchanged). See
  `docs/log-messages.md`.
- ADR-0007 is partially affected: "the provider throws `.expired`" is no longer true — the decision
  moved into the engine. This doesn't invalidate ADR-0007 (the contract "an expired token never
  reaches the API" is preserved), so there's no strikethrough for it in the index; a
  postscript pointer was added here instead.
- `JSONSerialization` appears in the codebase for the first time — only to pretty-print diagnostic
  JSON (`prettyPrinted`); the app's main decode path still runs on `Codable`.
- **JSON-body syntax highlighting (a later addition).** The window's body, when it's valid JSON
  (`TroubleshootLayout.bodyIsJSON`, resolved in the tested core via `isJSON`), is colored by token.
  Parsing is a new pure type, `JSONHighlighter.tokens(in:) -> [Token]` (`NSRange` +
  `JSONTokenKind`, the same pure-core/shell split as `TroubleshootLayout` — ADR-0009): **its own
  single-pass scanner, not `NSRegularExpression`** (regex can't distinguish a key from a
  string value and breaks on escaped quotes `\"`) and **not a third-party library** (the project
  has no external dependencies). The `JSONTokenKind → NSColor` map lives in the shell
  (`TroubleshootWindowController`) using **system semantic colors** (`.systemBlue`/
  `.systemGreen`/`.systemOrange`/`.systemPurple`/`.tertiaryLabelColor`) — they adapt to light/dark
  with no manual palette. A non-JSON body (HTML/plain error payload, placeholders) stays monolithic
  monospace. This isn't a new architectural decision but a continuation of an already-documented
  section — it doesn't need its own ADR.

## Related

- [ADR-0007](0007-token-provider-throws-and-scope-split.md) — "an expired token never reaches the
  API"; the expiry decision moved from the provider into the engine (postscript there).
- [ADR-0008](0008-usageclient-pure-backoff-and-transport-seam.md) — the pure `UsageClient` and the
  transport seam, which `diagnosedFetch` extends.
- [ADR-0012](0012-configure-window-and-launch-at-login.md) §6 — the Settings window's floating
  pattern, from which this window deliberately departs (normal level + fullscreen).
- [ADR-0017](0017-delegated-token-refresh.md) — delegated refresh, whose gate now lives alongside
  the expiry decision in `pollOnce`.
- [ADR-0019](0019-token-read-via-security-cli.md) — reading the token via the `security` subprocess;
  the motivation for "one read per poll."
