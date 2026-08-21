---
status: draft
date: 2026-08-01
---

# ADR-0058 (draft): Distributing the helper via a Homebrew tap

> **Draft.** Gated on #E0. Records the helper's install channel and the "detect, never install"
> UX.

## Context

The helper ([ADR-0054](0054-mas-present-if-installed-helper.md)) is a separate open-source product
that **the user** installs themselves; the MAS app only detects it (2.4.5(iv) — it doesn't
download/install it itself). We need to pick the simplest install channel **for our audience**.

The audience is **Claude Code users** — developers who already live in the terminal and have `gh`,
Homebrew, npm. For them, `brew install` is native territory, not a barrier.

## Decision

**The primary channel is a Homebrew cask via our own tap:**
`brew install --cask artem-n/tap/tokenpace-helper`. One command, notarized, updates via
`brew upgrade` for free. **A cask** (not a formula), because the helper is a signed bundle +
LaunchAgent, not a build from source. **Fallback** — a direct notarized download from GitHub
Releases (for non-Homebrew users); this is the same artifact the cask points at.

**npm/npx — rejected as the primary channel**: despite the audience having npm, it's a poor carrier
for a signed macOS LaunchAgent (the package would just be a downloader for the notarized artifact
on GitHub) — extra supply-chain surface with no upside. A thin convenience wrapper later is
possible, not now.

**The MAS app only detects + instructs** (exactly like Spark: "run `spark` to verify"):

```plantuml
@startuml
title ADR-0058: The helper install flow (detect, never install)
start
:MAS app starts (standalone:\nservice status + timers);
if (bookmark granted + fresh status.json?) then (yes)
  :full UI with personal pacing;
  stop
else (no)
  :show a non-nagging affordance\n"Personal usage → Learn more";
  :user copies the command\nbrew install --cask …/tokenpace-helper;
  note right
    The app does NOT run brew.
    It only shows the command
    + a copy button (2.4.5-iv).
  end note
  :user installs the helper themselves;
  :helper writes the first status.json;
  :user clicks "Connect";
  :an explanatory panel\n("the app reads only numbers, not the token");
  :pre-navigated NSOpenPanel →\nfolder-scoped read-write bookmark;
  :live detection flips the UI\nto "connected ✓";
  :full UI with personal pacing;
  stop
endif
@enduml
```

![PlantUML Diagram](https://www.plantuml.com/plantuml/svg/ZLCnRjmm4EprYeKg2RREHX03mRc83QSv8B6DsExKyAILn1or5CYLBjUboWEIDdKUTY_9af8Tfqj5KhCSpiokhZmhnsDl4jPi4Au_V2xEpo_UhU6nG-ZG3EX0arGP0usnUyXgPApu50YdlrYUHA9a_Udw0TGmG3nwo6IbMXbBk2x9evjqXG7aqSC9iExH-VmoqGraMsjtlN8xQ9qYnbhmng7lblBL5s_fVGxS8K5sG9yd0Ejc565F6zXhxa34IeqoCAXAKtif1PxjaA3n21dPUCDtua81MIf8jQtKWMeQwsf55PQKtZ-JZ5wr2CVlF-0ZAaVGMuTfu5oFOWGgEsZqGOvi-rvibhHrk7-9goWgvNTm_FRxZEqEIKHXCKSQMCWoWjDjntA0c7S8hhP2Udlt26ua27oh26yOB9a31FN_F1hH4p4aUWwm7PcjnFDczNPrKUWf3xUHwlZQY_H5uSopD5cslKSpeOyMbwzxftansMZd-NKlNaLXTBNpaDvO8fcDEIH5W5y7eqYnTGTf2Q4fAKjvCUfGrNusHME_bTHFWyhuLimhpIFFu50QDUbMXPcuVRWRaEu3MMXDIOqrDRh2Yts10saHHSFpE4KIeoU4UNArvDCOFSokdZObiOMqcgKBnV7Npzd0_uqMrRf9hcIHd-WF)

The helper (non-sandboxed) **keeps its own auto-updater**
([ADR-0033](0033-automatic-update-install.md) / [ADR-0025](0025-check-for-updates.md)) for
GitHub-download users; for Homebrew-installed ones this is belt-and-suspenders (`brew upgrade`
handles it).

## Consequences

- **One `brew` command** — the install story is solved for the primary audience; helper updates
  via `brew upgrade`.
- **The app never runs `brew`/never installs the helper** (2.4.5(iv)) — it only shows the command
  with a copy button + passively detects presence via IPC. "Learn more" opens GitHub in the
  browser.
- **Passive detection** — the app cannot silently stat the folder before the first bookmark grant
  (sandbox), so the flow must go through an explicit "Connect" + `NSOpenPanel`.
- A separate tap repo + CI is needed, bumping the cask on every helper release.
- References: [ADR-0031](0031-session-log-archiver.md) (log archiver → helper),
  [ADR-0025](0025-check-for-updates.md)/[ADR-0033](0033-automatic-update-install.md)
  (updater → helper), [ADR-0055](0055-ipc-file-darwin-bookmark.md) (the bookmark flow).
