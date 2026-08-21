---
status: accepted
date: 2026-06-21
---

# ADR-0004: Phase 1 builds with SPM plus a build script; Xcode arrives in Phase 2

## Context

The menu bar app is a GUI `.app` bundle, and it needs an `Info.plist` (`LSUIElement = true`), code
signing, notarization and (in Phase 2) iOS/watchOS targets. An Xcode project, plain SPM, and a
hybrid were all considered.

Trade-offs:

| Criterion | SPM | Xcode |
|---|---|---|
| git/diff | clean manifest | noisy `.pbxproj` |
| .app bundle | by hand (script) | native support |
| signing/notarization | manual CLI steps | built in |
| iOS/watchOS targets | practically impossible | native |
| CI/headless | just `swift build` | harder (`xcodebuild`) |

## Decision

- **Phase 1:** Swift Package Manager plus a build script that automates assembling the `.app` bundle
  (the `Contents/{MacOS,Resources}` layout plus `Info.plist`), `codesign --options runtime`, and
  notarization (`xcrun notarytool submit --wait` + `xcrun stapler`).
- **Phase 2:** attach an Xcode project for the iOS/watchOS apps (SPM cannot build them). Keep the
  shared logic (TokenProvider, UsageClient, PacingModel) in an SPM package that both the agent and
  the Xcode targets depend on.

## Consequences

- A clean git history for the logic; bundle/sign/notarize live in a versioned script.
- Access to Claude Code's Keychain item does not depend on the build system (it is a question of the
  item's ACL, not of entitlements) — a separate risk, verified independently.
- Moving to Xcode in Phase 2 takes migration work, but the logic already sits in the package, so the
  wrapper is thin.
