---
status: accepted
date: 2026-07-06
---

# ADR-0016: Renaming the project from cc-timer to TokenPace

## Context

The name `cc-timer` ("Claude Code timer") is tightly bound to a single vendor, while the product
is moving toward vendor-neutral pacing of token windows across different LLM agents (#60). We need
a name that signals "pacing token/usage windows" without naming a specific provider.

Shortlist (#60): `AgentPace`, `TokenPace`, `LLMeter`. **TokenPace** was chosen — "token" is a common
unit across all LLM vendors. Availability was checked on 2026-07-04: GitHub / npm / PyPI / App
Store are free; the `.io` / `.ai` / `.dev` domains are free (`.com` / `.app` are taken). A trademark
search wasn't done — that's a separate step before publishing to the App Store.

What remained open was exactly how to break the name down into identifiers: the bundle id
(`dev.tokenpace.*` based on an unregistered domain, or an existing personal prefix), the
executable target's casing, and the fate of the local notarytool profile.

## Decision

A full rebrand in Phase 1 (#61) with the following identifiers:

| What | Was | Becomes |
|---|---|---|
| Product / display name | cc-timer | **TokenPace** |
| SwiftPM package / executable target | `cc-timer` | `TokenPace` (`swift run TokenPace`) |
| Library (target + namespace enum) | `CCTimerKit` | `TokenPaceKit` |
| Test target | `CCTimerKitTests` | `TokenPaceKitTests` |
| Bundle ID | `com.artem-n.cc-timer` | `com.artem-n.tokenpace` |
| os_log subsystem (= bundle id, an invariant) | `com.artem-n.cc-timer` | `com.artem-n.tokenpace` |
| Transport stub env var | `CC_TIMER_STUB` | `TOKENPACE_STUB` |
| Pre-commit hook bypass env var | `CC_TIMER_SKIP_SWIFT_HOOK` | `TOKENPACE_SKIP_SWIFT_HOOK` |
| notarytool profile (local Keychain) | `cc-timer-notary` | `tokenpace-notary` |
| GitHub repository | `artem-from-ua/cc-timer` | `artem-from-ua/tokenpace` |
| Release archive | `cc-timer-X.Y.Z.zip` | `TokenPace-X.Y.Z.zip` |

Key choices:

- **The bundle id stays on the personal prefix** (`com.artem-n.tokenpace`), not
  `dev.tokenpace.*`: the domain `tokenpace.dev` isn't registered, so a reverse-DNS id built from it
  would be a fiction. While the product isn't in the App Store, changing the bundle id later is
  cheap; doing it now against an unclaimed domain is risk with no payoff.
- **The executable target is TitleCase `TokenPace`**: the macOS app convention
  (`TokenPace.app/Contents/MacOS/TokenPace`), not CLI-style lowercase.
- **History is not rewritten**: mentions of `cc-timer`/`CCTimerKit` in ADRs 0006–0015 (in the
  Context/Decision/Consequences bodies) stay as an unaltered record of the codebase's state at the
  time of the decision. Only living docs are renamed (README, SPEC, architecture, building,
  conventions, log-messages, releasing).
- **The Keychain service `"Claude Code-credentials"` is left untouched** — that's the item name
  created by the Claude Code CLI itself; it isn't derived from our app's name.

## Consequences

- **Breaking for the library:** the `CCTimerKit` product disappears — every `import CCTimerKit`
  changes to `import TokenPaceKit`. The code rename was done atomically in a single PR, so the
  build never breaks midway.
- **An orphaned login item:** `SMAppService.mainApp` registers by bundle id, so the old
  `com.artem-n.cc-timer` registration stays in System Settings → Login Items after installing
  TokenPace.app — it's removed by hand along with the old `.app`. There's no migration code
  (deliberately: a one-time manual step for a single user). The app doesn't use `UserDefaults`, so
  there's no other state loss.
- **The notarytool profile has to be recreated by hand** (`xcrun notarytool store-credentials
  tokenpace-notary …` with a new app-specific password) — otherwise notarization in `build-app.sh`
  silently gets skipped. The old `cc-timer-notary` profile is harmless and can stay.
- **Old releases are not renamed:** the `cc-timer-*.zip` assets for v0.11.0 and earlier stay as
  they are; GitHub keeps a redirect from the old repository URL.
- Mentions in the bodies/comments of GitHub issues (open and closed) are cleaned up as a separate
  step after the merge, except for historical quotes (e.g., the naming comment in #60).
