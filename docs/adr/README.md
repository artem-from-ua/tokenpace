# Architecture decisions (ADRs)

The project's architecture decision records — what was decided, when, and why. Each one is a record
of a moment: an **accepted** ADR is never rewritten or deleted, even once it stops describing the
current design, because the reasoning is worth as much as the outcome.

**How to read the table.** The status tells you how much of a record is still in force:

- **`accepted`** — in force as written.
- **`partially superseded → NNNN`** — mostly in force; a later ADR replaced a part of it. The
  record is **not** struck through, because you still need it. A postscript at the top of the file
  says which part went and which still stands.
- **`superseded → NNNN`** — replaced in full, and struck through in the table. Read it for the
  history, not for the current design; follow the arrow for what is in force now.
- **`draft`** — not decided yet. It describes a direction, not a commitment.
- **`rejected`** — a draft that did not take off, kept with a one-line reason.

| # | Title | Status |
|---|---|---|
| [0001](0001-swift-stack.md) | Swift as the project's only language | accepted |
| ~~[0002](0002-ukrainian-documentation.md)~~ | ~~Українська як мова документації~~ | superseded → [0116](0116-english-as-documentation-language.md) |
| [0003](0003-agent-closed-source-for-now.md) | The Mac agent stays closed for now; the license is an open question | accepted |
| [0004](0004-build-system.md) | Phase 1 builds with SPM plus a build script; Xcode arrives in Phase 2 | accepted |
| [0005](0005-pacing-fractions-not-blocks.md) | PacingModel — zones as fractions, not discrete blocks | partially superseded → [0059](0059-menu-bar-native-semantic-colours.md) |
| ~~[0006](0006-reset-time-absolute-vs-relative.md)~~ | ~~ResetClock — absolute `hh:mm` for distant resets, not relative time only~~ | superseded → [0074](0074-one-reset-format-on-both-surfaces.md) |
| [0007](0007-token-provider-throws-and-scope-split.md) | TokenProvider — `throws` plus an enum, a pure decoding layer, and splitting the scope of #8 | accepted |
| [0008](0008-usageclient-pure-backoff-and-transport-seam.md) | UsageClient — pure backoff, an injected token, and a transport seam | accepted |
| [0009](0009-statusitemview-pure-layout-and-thin-shell.md) | StatusItemView — a pure MenuBarLayout plus a thin AppKit shell | partially superseded → [0015](0015-no-idle-mode.md), [0059](0059-menu-bar-native-semantic-colours.md) |
| [0010](0010-usage-health-and-error-states.md) | UsageHealth — error states (⚠️ in the menu bar + a popup banner + stale) | partially superseded → [0091](0091-countdown-only-where-work-is-not-running.md) |
| ~~[0011](0011-polling-engine-adaptive-cadence-and-signal-seams.md)~~ | ~~PollingEngine — an async loop, an adaptive interval, and sleep/wake/network seams~~ | superseded → [0032](0032-simplified-polling-cadence.md) |
| ~~[0012](0012-configure-window-and-launch-at-login.md)~~ | ~~The "Configure…" window and launch at login (SMAppService)~~ | superseded → [0018](0018-launch-at-login-notfound-recovery.md) |
| ~~[0013](0013-claude-status-line.md)~~ | ~~Claude services status line in the popup (status.claude.com)~~ | superseded → [0024](0024-configurable-logical-services.md), [0071](0071-incident-subscriptions.md), [0119](0119-status-polling-own-cadence-and-backoff.md) |
| ~~[0014](0014-usage-decode-resilience-on-reset-boundary.md)~~ | ~~UsageSnapshot — synthesizing a window at the reset boundary instead of a decode failure~~ | superseded → [0027](0027-session-idle-no-phantom-reset.md) |
| [0015](0015-no-idle-mode.md) | Remove the compact idle mode — always show the strips | accepted |
| [0016](0016-rename-to-tokenpace.md) | Renaming the project from cc-timer to TokenPace | accepted |
| [0017](0017-delegated-token-refresh.md) | Delegated token refresh via the claude CLI | accepted |
| [0018](0018-launch-at-login-notfound-recovery.md) | Recovering launch-at-login after an update — `.notFound` is not terminal | accepted |
| [0019](0019-token-read-via-security-cli.md) | Reading the token through a `security` CLI subprocess (the partition list gets reset) | accepted |
| [0020](0020-troubleshoot-window-and-diagnostics-pipeline.md) | The Troubleshoot window and a diagnostics channel through a pure pipeline | partially superseded → [0117](0117-dropdown-actions-behind-option.md), [0119](0119-status-polling-own-cadence-and-backoff.md) |
| [0021](0021-popup-two-column-layout-and-uniform-dropdown-typography.md) | Popup — a two-column layout, ⌥-gated status, one dropdown font | accepted |
| [0022](0022-popup-bar-transparency-and-contrast-experiment.md) | Popup pacing-bar appearance — opaque monochrome bars on a solid background | partially superseded → [0059](0059-menu-bar-native-semantic-colours.md), [0060](0060-popup-native-semantic-colours.md), [0064](0064-popup-translucent-card-and-glow-bars.md) |
| [0023](0023-persisted-config-version-marker.md) | A config version marker + the tested boundary in the persistence layer | accepted |
| [0024](0024-configurable-logical-services.md) | Configurable logical services instead of two fixed status components | accepted |
| [0025](0025-check-for-updates.md) | Update checking — dual fetch path, system banner, launch-time check | partially superseded → [0036](0036-update-signals-single-dropdown-item.md), [0119](0119-status-polling-own-cadence-and-backoff.md) |
| [0026](0026-gemini-not-implemented.md) | Not implementing Gemini — no ToS-compliant path to the consumer metric | accepted |
| [0027](0027-session-idle-no-phantom-reset.md) | An honest "no active 5h session" state instead of a phantom reset | partially superseded → [0038](0038-idle-blocked-status.md), [0059](0059-menu-bar-native-semantic-colours.md), [0060](0060-popup-native-semantic-colours.md), [0074](0074-one-reset-format-on-both-surfaces.md), [0078](0078-idle-drawn-as-zero-in-both-styles.md), [0107](0107-weekly-reset-reconstructed-from-the-last-known-one.md) |
| ~~[0028](0028-hide-reset-label-when-pacing-is-calm.md)~~ | ~~Hiding the reset-time label in the menu bar when pacing is calm~~ | superseded → [0029](0029-reset-countdown-selection-by-severity.md), [0044](0044-dynamic-pacing-threshold.md) |
| ~~[0029](0029-reset-countdown-selection-by-severity.md)~~ | ~~Selecting the reset time in the menu bar by 5h × 7d states + a radio-group mode~~ | superseded → [0042](0042-settings-swiftui-form.md), [0043](0043-unified-reset-line-and-remove-resetnow.md), [0044](0044-dynamic-pacing-threshold.md), [0091](0091-countdown-only-where-work-is-not-running.md) |
| ~~[0030](0030-optimistic-reset-and-exact-timer.md)~~ | ~~An optimistic reset on an exact timer instead of a passive `.resetNow` state (⏰)~~ | superseded → [0043](0043-unified-reset-line-and-remove-resetnow.md) |
| [0031](0031-session-log-archiver.md) | Raw Claude Code session log archiver (accumulate-only) | accepted |
| [0032](0032-simplified-polling-cadence.md) | Simplified polling cadence — a 3-minute base, honor-only `Retry-After`, pause on lock | partially superseded → [0123](0123-one-line-per-error-run-and-a-floor-on-signal-driven-polls.md) |
| [0033](0033-automatic-update-install.md) | Automatic update install — a custom minimal installer, not Sparkle | partially superseded → [0036](0036-update-signals-single-dropdown-item.md) |
| ~~[0034](0034-hide-calm-seven-day-bar.md)~~ | ~~Hiding the calm 7d strip in the menu bar (an option, default-on)~~ | superseded → [0086](0086-tri-state-calm-bar-hiding.md) |
| [0035](0035-settings-window-sidebar-grouped-inset.md) | Settings window — sidebar navigation and grouped-inset cards | partially superseded → [0040](0040-native-system-metrics-no-hardcoded-ui.md), [0042](0042-settings-swiftui-form.md), [0069](0069-settings-window-height-resizable.md) |
| [0036](0036-update-signals-single-dropdown-item.md) | Auto-update signals — a single dropdown item, no notifications; auto-install default-ON | accepted |
| [0037](0037-extra-usage-credits-model.md) | Money credits model (extra usage) — `spend` as primary, trigger and pacing like the token bars | accepted |
| [0038](0038-idle-blocked-status.md) | Idle "blocked" — a gray bar, "waiting for limit reset", and one blocking red reset | partially superseded → [0105](0105-color-advice-governs-pacing-bars-only.md) |
| [0039](0039-back-to-work-notification.md) | "Back to work!" notification — the blocked→unblocked edge, quiet hours, opt-in | partially superseded → [0113](0113-back-to-work-tracks-the-subscription-quota.md) |
| [0040](0040-native-system-metrics-no-hardcoded-ui.md) | A native UI look via system mechanisms, not hardcoded metrics | partially superseded → [0042](0042-settings-swiftui-form.md), [0059](0059-menu-bar-native-semantic-colours.md), [0069](0069-settings-window-height-resizable.md) |
| [0041](0041-idle-grace-on-reset-boundary.md) | A grace period at the reset boundary — suppress the false 5h idle right after a reset | partially superseded → [0045](0045-honest-reset-boundary-grace.md) |
| [0042](0042-settings-swiftui-form.md) | The Settings window — SwiftUI Form.grouped instead of hand-drawn AppKit | partially superseded → [0069](0069-settings-window-height-resizable.md) |
| [0043](0043-unified-reset-line-and-remove-resetnow.md) | A unified "time to reset" line in the dropdown, plus removing `.resetNow` | partially superseded → [0091](0091-countdown-only-where-work-is-not-running.md) |
| [0044](0044-dynamic-pacing-threshold.md) | A dynamic yellow→orange pacing threshold, plus a 20-minute orange override | accepted |
| [0045](0045-honest-reset-boundary-grace.md) | An honest reset boundary — a rolled-forward grace plus an activity-based trigger | accepted |
| ~~[0046](0046-dev-color-tuner-override-layer.md)~~ | ~~A centralized `ColorStore` override layer for the dev color tuner~~ | superseded → [0106](0106-remove-dev-color-tuner-and-dissolve-colorstore.md) |
| [0047](0047-live-stub-selector.md) | A live stub selector — rebuilding the polling engine at runtime | accepted |
| [0048](0048-red-reset-badge-while-credits-cover.md) | A red reset badge when the subscription limit is exhausted but credits are covering it | accepted |
| ~~[0049](0049-blocked-reset-mode.md)~~ | ~~A separate `MenuBarMode.blockedReset` for the "countdown only" widget~~ | superseded → [0063](0063-unified-pause-hides-bars.md) |
| [0050](0050-extra-usage-notification.md) | The "Now using Extra Usage Credit" notification — the not-spending→spending front, shared infrastructure with ADR-0039 | accepted |
| ~~[0051](0051-blocked-pause-glyph.md)~~ | ~~An orange "pause" glyph before the bars in the fully blocked state~~ | superseded → [0063](0063-unified-pause-hides-bars.md) |
| ~~[0052](0052-shared-prod-env-flag-resolver.md)~~ | ~~A shared resolver for prod-visible env flags (`ProdEnvFlag`)~~ | superseded → [0053](0053-devtools-flag-via-defaults.md) |
| [0053](0053-devtools-flag-via-defaults.md) | Gate dev-tools via `UserDefaults` (`defaults`), not an env var | accepted |
| [0054](0054-mas-present-if-installed-helper.md) | Mac App Store distribution via a present-if-installed helper | draft |
| [0055](0055-ipc-file-darwin-bookmark.md) | The app↔helper IPC channel — file + read-write bookmark + Darwin notification | draft |
| [0056](0056-thin-helper-thick-app-build-flavors.md) | Thin helper / thick app — the target split and build flavors | draft |
| [0057](0057-token-provider-io-into-helper.md) | Moving `TokenProvider`'s I/O half into the helper | draft |
| [0058](0058-helper-distribution-homebrew.md) | Distributing the helper via a Homebrew tap | draft |
| [0059](0059-menu-bar-native-semantic-colours.md) | Menu-bar widget — native semantic colours, not statusline-fixed sRGB | partially superseded → [0106](0106-remove-dev-color-tuner-and-dissolve-colorstore.md) |
| [0060](0060-popup-native-semantic-colours.md) | A unified palette — system semantic colours shared by the menu bar and the popup (except the Claude brand) | partially superseded → [0064](0064-popup-translucent-card-and-glow-bars.md) |
| [0061](0061-far-behind-blue-pacing-zone.md) | The "far behind" blue pacing zone + the "Work harder" option | partially superseded → [0062](0062-configurable-bar-presentation.md), [0081](0081-weekly-capacity-gate-for-blue.md), [0115](0115-no-blue-on-per-model-windows.md) |
| ~~[0062](0062-configurable-bar-presentation.md)~~ | ~~Configurable pacing-bar presentation — bar style, Calm mode, far-behind threshold~~ | superseded → [0076](0076-pressure-scale-for-marker-less-bar.md), [0080](0080-per-surface-bar-style.md), [0081](0081-weekly-capacity-gate-for-blue.md), [0098](0098-ruler-split-identify-always-explain-on-option.md), [0112](0112-appearance-presets-preview-apply-commits.md) |
| ~~[0063](0063-unified-pause-hides-bars.md)~~ | ~~A single "Pause icon hides bars" toggle instead of two independent blocking options~~ | superseded → [0090](0090-menu-bar-answers-can-we-work.md) |
| [0064](0064-popup-translucent-card-and-glow-bars.md) | The popup — unconditionally translucent, a Control Center card, rebuilt bars with glow | accepted |
| [0065](0065-macos-widgetkit-widget-architecture.md) | macOS WidgetKit widget architecture — App Group snapshot, shared rendering, deep link into the dropdown | draft |
| [0066](0066-detect-sessions-awaiting-input.md) | Detecting Claude Code sessions that are awaiting the user's input | accepted |
| [0067](0067-local-usage-journal.md) | Local usage journal (append-only JSONL) | partially superseded → [0123](0123-one-line-per-error-run-and-a-floor-on-signal-driven-polls.md) |
| [0068](0068-credits-in-use-marker-anatomy.md) | Anatomy of the "credits in use" marker — a pill with a knocked-out currency glyph | partially superseded → [0114](0114-extra-usage-is-one-name.md) |
| [0069](0069-settings-window-height-resizable.md) | The Settings window — height-resizable, vertical zoom, a validated persistent frame | accepted |
| [0070](0070-smooth-bar-colour-transitions.md) | Smooth pacing-bar color transitions — the project's first animation | partially superseded → [0073](0073-awaiting-icon-reserved-slot-and-slide.md) |
| [0071](0071-incident-subscriptions.md) | status.claude.com incidents in the popup, and subscribing to their updates | accepted |
| ~~[0072](0072-dropdown-section-visibility.md)~~ | ~~Three-state dropdown section visibility instead of boolean toggles~~ | superseded → [0087](0087-above-zero-section-visibility.md) |
| [0073](0073-awaiting-icon-reserved-slot-and-slide.md) | A reserved slot for the awaiting-hand icon, and its slide from below — the first motion animation | accepted |
| [0074](0074-one-reset-format-on-both-surfaces.md) | One "time to reset" format on both surfaces — the 90-minute threshold is gone | accepted |
| [0075](0075-reset-label-reserved-slot.md) | A reserved slot for the reset label — keyed on presence, with centered text | accepted |
| [0076](0076-pressure-scale-for-marker-less-bar.md) | A scale for the marker-less bar — against time remaining (Pressure), not against the window | partially superseded → [0078](0078-idle-drawn-as-zero-in-both-styles.md), [0079](0079-centred-zero-gauge-scale.md), [0101](0101-pressure-is-the-gauge-ahead-half.md) |
| [0077](0077-settings-toolbar-segmented-back-forward.md) | ‹ › in the Settings toolbar — one item, a separated NSSegmentedControl | accepted |
| [0078](0078-idle-drawn-as-zero-in-both-styles.md) | Idle draws as zero in both styles — track + pill, marker only in Progress | accepted |
| [0079](0079-centred-zero-gauge-scale.md) | Gauge — a fourth style with zero in the middle, showing unspent budget | partially superseded → [0080](0080-per-surface-bar-style.md), [0101](0101-pressure-is-the-gauge-ahead-half.md) |
| [0080](0080-per-surface-bar-style.md) | Bar style is chosen separately for each surface | accepted |
| [0081](0081-weekly-capacity-gate-for-blue.md) | Blue is gated by the week's headroom; the far-behind zone's width is fixed | partially superseded → [0105](0105-color-advice-governs-pacing-bars-only.md), [0115](0115-no-blue-on-per-model-windows.md) |
| [0082](0082-sidebar-icon-size-pinned-to-large.md) | Settings sidebar icon size is pinned to Large | accepted |
| [0083](0083-live-dropdown-preview-in-settings.md) | A live dropdown preview next to the Settings window | partially superseded → [0099](0099-appearance-nests-its-two-surfaces.md) |
| [0084](0084-settings-drill-in-child-pages.md) | Settings child pages — drill-in, not sidebar rows | accepted |
| [0085](0085-provider-monitoring-model.md) | Usage collection and service monitoring are two different things | partially superseded → [0119](0119-status-polling-own-cadence-and-backoff.md) |
| ~~[0086](0086-tri-state-calm-bar-hiding.md)~~ | ~~Hiding a calm bar — a three-way choice instead of a boolean~~ | superseded → [0090](0090-menu-bar-answers-can-we-work.md) |
| ~~[0087](0087-above-zero-section-visibility.md)~~ | ~~The `aboveZero` mode for dropdown sections, and why credits lose `nonCalm`~~ | superseded → [0100](0100-dropdown-style-tiles-and-retired-option-segment.md), [0104](0104-appearance-named-for-behaviour-on-three-layers.md) |
| [0088](0088-settings-hosting-safe-area-and-manual-separator.md) | The Settings detail pane — safe area is cut at the hosting boundary, the toolbar rule is driven by the controller | accepted |
| [0089](0089-gauge-centre-tick-calm-tone.md) | The Gauge center tick — in the calm-fill tone, 1 pt taller | accepted |
| [0090](0090-menu-bar-answers-can-we-work.md) | The menu bar answers one question — can we work | partially superseded → [0091](0091-countdown-only-where-work-is-not-running.md) |
| [0091](0091-countdown-only-where-work-is-not-running.md) | A countdown only where work isn't running | partially superseded → [0128](0128-menu-bar-repeats-a-block-per-provider.md) |
| [0092](0092-extra-usage-own-ruler.md) | The credits bar — its own scale, with labeled month boundaries | accepted |
| ~~[0093](0093-bar-style-picked-by-picture.md)~~ | ~~The menu bar's bar style is picked by picture, not by word~~ | superseded → [0097](0097-bar-style-preview-rendered-at-runtime.md), [0100](0100-dropdown-style-tiles-and-retired-option-segment.md) |
| [0094](0094-provider-row-brand-badge.md) | The provider row gets a brand badge, the Providers chip becomes a puzzle piece | accepted |
| [0095](0095-own-resource-bundle-lookup.md) | We look up the resource bundle ourselves, not through `Bundle.module` | accepted |
| [0096](0096-zero-tick-on-pressure.md) | A zero tick on Pressure too — centered on the zero pill, dimmed | accepted |
| [0097](0097-bar-style-preview-rendered-at-runtime.md) | The bar style preview is rendered at runtime, not shipped as snapshots | partially superseded → [0132](0132-popup-bars-pin-the-vibrant-appearance-in-one-seam.md) |
| [0098](0098-ruler-split-identify-always-explain-on-option.md) | The bar ruler splits in two — identify always, explain under ⌥ | accepted |
| [0099](0099-appearance-nests-its-two-surfaces.md) | `Appearance` is one pane again, and the two surfaces are its child pages | partially superseded → [0112](0112-appearance-presets-preview-apply-commits.md) |
| [0100](0100-dropdown-style-tiles-and-retired-option-segment.md) | The dropdown picks a style by picture, and the `With ⌥ Option` segment goes away | partially superseded → [0104](0104-appearance-named-for-behaviour-on-three-layers.md) |
| [0101](0101-pressure-is-the-gauge-ahead-half.md) | Pressure is the right half of Gauge, and the scale coefficient is gone | accepted |
| [0102](0102-stand-by-line-for-the-seven-day-bar.md) | A "stand by … for green" line — the cost of waiting out the 7-day bar | accepted |
| [0103](0103-weekly-utilization-reconstructed-from-the-five-hour-counter.md) | Weekly `utilization` is reconstructed from the five-hour counter | accepted |
| [0104](0104-appearance-named-for-behaviour-on-three-layers.md) | Appearance is named for behavior — on all three layers at once | accepted |
| [0105](0105-color-advice-governs-pacing-bars-only.md) | `Colors tell me` governs pacing bars only | partially superseded → [0111](0111-degraded-dot-is-yellow-on-every-surface.md) |
| [0106](0106-remove-dev-color-tuner-and-dissolve-colorstore.md) | Removing the dev color tuner and dissolving `ColorStore` | accepted |
| [0107](0107-weekly-reset-reconstructed-from-the-last-known-one.md) | The weekly reset is reconstructed from the last known one, not estimated from the clock | accepted |
| [0108](0108-extra-usage-one-anatomy-and-per-bar-style-caption.md) | "Extra usage" has one anatomy for every state, each bar labels its own scale under ⌥ | accepted |
| [0109](0109-centred-style-renamed-to-balance.md) | The centered bar style is called **Balance**, not Gauge | accepted |
| [0110](0110-legend-is-a-static-page-rendered-by-the-live-code.md) | Legend — a static page rendered by the live code | accepted |
| [0111](0111-degraded-dot-is-yellow-on-every-surface.md) | The `degraded` dot is yellow on all three surfaces | accepted |
| [0112](0112-appearance-presets-preview-apply-commits.md) | Appearance presets — a click is a preview, only `Apply` commits | accepted |
| [0113](0113-back-to-work-tracks-the-subscription-quota.md) | "Back to work!" tracks the subscription quota, not the ability to work | accepted |
| [0114](0114-extra-usage-is-one-name.md) | "Extra usage" — one name across every surface | accepted |
| [0115](0115-no-blue-on-per-model-windows.md) | Blue never applies to per-model windows; `sev` is recomputed by migration | accepted |
| [0116](0116-english-as-documentation-language.md) | English as the documentation language | accepted |
| [0117](0117-dropdown-actions-behind-option.md) | Every dropdown action sits behind ⌥ Option, announced by a caption | accepted |
| [0118](0118-activity-from-session-journals.md) | Claude Code activity is read from session journals, not the process table | accepted |
| [0119](0119-status-polling-own-cadence-and-backoff.md) | Status polling gets its own heartbeat and a per-source 429 backoff | accepted |
| [0120](0120-status-records-carry-their-provider.md) | `status` journal records carry their provider, and the archive is backfilled | accepted |
| [0121](0121-github-as-a-status-only-provider.md) | GitHub as a status-only provider — one group, two plates, and a dot that only appears while calm | accepted |
| [0122](0122-comments-are-read-every-session.md) | Comments are priced per read | accepted |
| [0123](0123-one-line-per-error-run-and-a-floor-on-signal-driven-polls.md) | One line per error run, and a wall-clock floor on signal-driven polls | accepted |
| [0124](0124-journal-records-carry-their-provider.md) | Every journal record carries its provider, and error runs never merge across providers | accepted |
| [0125](0125-codex-as-a-status-provider.md) | Codex as a status provider — statuses from the component feed, incidents from the page's own backend, and an age that is never invented | accepted |
| [0117](0117-dropdown-actions-behind-option.md) | Every dropdown action sits behind ⌥ Option, announced by a caption | partially superseded → [0126](0126-settings-and-quit-stay-visible-by-default.md) |
| [0127](0127-codex-quota-from-the-app-server.md) | Codex quota from a short-lived `app-server` process, with window durations as data rather than enum cases | partially superseded → [0129](0129-ready-to-start-is-gated-on-the-account-reached-flags.md) |
| [0128](0128-menu-bar-repeats-a-block-per-provider.md) | The menu bar repeats a block per provider, with the status dot pinned rightmost | accepted |
| [0129](0129-ready-to-start-is-gated-on-the-account-reached-flags.md) | A Codex read that reports the limit reached at zero usage is malformed data, not a quota state | accepted |
| [0130](0130-one-usage-record-with-a-windows-array.md) | One usage record with a windows array, so any provider fits | accepted |
| [0131](0131-issue-label-and-title-taxonomy.md) | Issue labels and titles as prefixed axes | accepted |
| [0132](0132-popup-bars-pin-the-vibrant-appearance-in-one-seam.md) | Popup bars pin the vibrant appearance in one seam shared by the live bar and every specimen | accepted |
| [0133](0133-release-falls-back-to-osize-only-after-the-compiler-crashes.md) | The release build falls back to `-Osize` only after `-O` has actually crashed the compiler | accepted |
| [0134](0134-app-icon-from-a-committed-icon-composer-build.md) | The app icon ships as a committed `actool` build of an Icon Composer source, with Liquid Glass off | accepted |

## Maintaining this index

**Creating or changing anything under `docs/adr/` — read
[writing-adrs.md](../guides/writing-adrs.md) first.** The numbering, the frontmatter, the sections
of a body, and the shape of a supersession postscript are decided there; start a new record from
[TEMPLATE.md](TEMPLATE.md). This file is the index; that one is the procedure. What follows is only
the part that governs the table above.

**The Title column is the ADR's H1, verbatim — nothing else.** It drifted: cell by cell the column
stopped being a title and became a summary of the Decision section, until the average row passed
1 kB, the worst reached 5.2 kB, a stray fragment split the table's markup mid-row, and six rows
carried an unescaped `|` that silently broke their column count. None of that prose was unique —
every supersession it described was already written, in more detail, in the postscript of the ADR
it described. A second copy of a fact is a copy that drifts from the first, which is how one index
came to spell the same status eleven different ways.

- **Title** — the H1 text, minus the `ADR-NNNN:` prefix and the `(draft)` marker.
- **Status** — one of exactly five: `accepted`, `draft`, `rejected`, `superseded → NNNN`,
  `partially superseded → NNNN`. No prose, no parenthetical reason, no "what exactly." **Every
  number in it is a link** — the arrow is what a reader follows out of this table.
- **What was superseded, and what still stands, goes in the ADR's own postscript**, not here.

**Strikethrough marks a fully superseded record — and only that.** The number and title are struck
when `status: superseded`; a partially superseded ADR is not struck, because it is still mostly in
force and still meant to be read. Its `partially superseded → NNNN` status already says what
changed, and striking it through would tell the reader to skip a record they need.

The row follows from the file's frontmatter, with nothing left to judge:

| Frontmatter | Status in the index | Struck through |
|---|---|---|
| `status: accepted`, no `superseded_by` | `accepted` | no |
| `status: accepted` + `superseded_by: [NNNN]` | `partially superseded → [NNNN](NNNN-….md)` | no |
| `status: superseded` + `superseded_by: [NNNN]` | `superseded → [NNNN](NNNN-….md)` | yes |
| `status: draft` | `draft` | no |
| `status: rejected` | `rejected` | no |

A **partial** supersession keeps `status: accepted` — the decision mostly still holds, and calling
it `superseded` would be inaccurate — but gains `superseded_by: [NNNN]` and a postscript drawing
the line between what was replaced and what still stands. Examples:
[0025](0025-check-for-updates.md) and [0033](0033-automatic-update-install.md), both partially
superseded by [0036](0036-update-signals-single-dropdown-item.md).

**The lifecycle** is `draft → accepted → (superseded)`, with a `draft → rejected` branch. `draft`
is the only status that may be rewritten: once an ADR is accepted it is immutable, and a decision
that stops holding is replaced by a new record rather than edited in place.
