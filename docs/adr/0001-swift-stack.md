---
status: accepted
date: 2026-06-21
---

# ADR-0001: Swift as the project's only language

## Context

The Mac agent has to read the macOS Keychain and (in Phase 2) write to CloudKit, while the
iPhone/Watch apps read from CloudKit. Two languages were considered for the Mac agent: Swift and Go.

## Decision

Use **Swift** for the whole project — the Mac menu bar app, and later iOS/watchOS.

## Consequences

**Upsides:**

- Native access to the Keychain (Security framework) and CloudKit (CloudKit framework) — no
  workarounds.
- One stack across the project: agent, iOS app, watchOS complication.
- AppKit (`NSStatusItem`) + SwiftUI (`NSHostingView`) — declarative UI for the bars inside the
  menu bar.

**Downsides:**

- Swift daemons on macOS are somewhat less familiar to OSS contributors than a Go CLI.

**Why not Go:**

- CloudKit from Go requires the CloudKit Web Services API plus a server-to-server key (awkward, and
  that is already "almost a backend").
- No native Keychain access.
