---
status: draft
date: 2026-10-09
supersedes: [0070]
---

# ADR-0135: Colour tweens are kept per drawing appearance, and a watchdog bounds the frame timer

> **Draft.** Gated on [#554](https://github.com/artem-from-ua/tokenpace/issues/554) being closed, which happens once the reporter confirms that the release carrying this fix no longer burns CPU on their two-display Mac.

> **Supersedes §4 and §6 of [ADR-0070](0070-smooth-bar-colour-transitions.md)** in part: §6's "a theme flip snaps through `finishAll()`" is replaced by D2, and §4's "the timer only exists during a transition" is now enforced by D3 instead of being assumed.

## Context

A user reported TokenPace 0.118.0 at a steady ~43% CPU on a MacBook Pro with a second display, 9 h 49 min of CPU time over 3.7 days ([#554](https://github.com/artem-from-ua/tokenpace/issues/554)). Their `sample` and `spindump` showed the ADR-0070 frame timer firing forever, each frame rebuilding the dropdown, and the button's `effectiveAppearance` KVO being called from `-[NSStatusItem _updateReplicant:]` → `-[NSView setAppearance:]`.

On a Mac with more than one display, AppKit draws the status item for every other display's menu bar by setting that bar's appearance on the button, snapshotting it, and restoring it within one call. Menu-bar lightness follows each display's wallpaper, so the two bars can resolve one semantic colour to two different sRGB values. The KVO handler snapped every tween (`finishAll()`, ADR-0070 §6) and re-rendered under the other appearance. That retargeted the shared colour tweens, and the restore retargeted them back. Every frame set `button.image`, which triggered the next snapshot, so the timer never settled. The maintainer reproduced it with a Sidecar display, a dark wallpaper on one display and a light one on the other: 0.118.0 rose to 35–40% CPU at once, and stayed there.

The loop came from two assumptions in ADR-0070. One tween key has one target per frame, which stops holding once the same element is drawn under two appearances. And a theme flip is the only reason the button's appearance changes, which stops holding once AppKit changes it on its own for snapshots.

## Decision

### D1. One set of colour tweens per drawing appearance

`ColorAnimator` keeps an `AppearanceScopedTweens` (in `TokenPaceKit`): one `ColorTweenSet` per appearance name, chosen by `NSAppearance.currentDrawing()` at the `resolve` call, which always runs inside the draw. A snapshot for another display's bar reads and writes its own set and never retargets this display's. The first draw in a new appearance adopts its colour without animating, as any first sight of a key does. Scalar tweens (the awaiting hand's presence) are not scoped: a presence is the same number in every appearance.

### D2. A real appearance change drops the sets; a snapshot does nothing to them

The button's KVO no longer calls `finishAll()`. It still re-renders the image synchronously, because the image taken under the other appearance is what that display shows. Whether the change was real is decided in a `DispatchQueue.main.async` check: by then AppKit has restored the button, so a name that still differs from the last settled one is this display's own bar flipping. That, and any change of `NSApp.effectiveAppearance` (the system theme, which the dropdown follows even when the menu bar does not), drops every colour set. The next draw of each element adopts its colour, which is the snap §6 asked for, without a set from the old theme lingering for the 45 s stale window and fading from a pre-flip colour if the theme flips back.

### D3. A watchdog bounds the frame timer

If the timer has run for more than 5 s without settling, the watchdog finishes every tween, stops the timer and pauses transitions. A real transition lasts 0.8 s, and only data flipping several times a second could keep a healthy timer alive for 5 s. While paused, both `resolve` overloads return their target without touching the tween state. The pause is 60 s, doubling on each further trip up to 1 h; the count starts over after an hour without a trip, measured from the end of the last pause. The check runs on the timer's own tick, because the render path returns early before the first poll.

### D4. Diagnostics that survive without a live stream

Each trip is logged once at `.error`: a broken invariant, persisted so it can be collected afterwards with `log show` from a machine the maintainer cannot reproduce on. The line names the trip number, how long the timer ran, the retarget count, the last retargeted key, the appearance names that held tweens and how many button appearance changes the episode saw. Button appearance changes are summarised at `.notice` at most once per 10 minutes; one per change would flood the log on a multi-display Mac.

## Consequences

- On a multi-display Mac whose menu bars differ, the timer runs only for the 0.8 s of a real transition, and each display shows the colours resolved for its own bar.
- A legitimate fade or hand slide on the main display is no longer cut short by every replicant snapshot.
- While the watchdog's pause is active (60 s up to 1 h), colour changes and the awaiting hand snap instead of animating. That only happens after the invariant has already broken.
- The 5 s limit has one known false positive: `TOKENPACE_AWAITING_CYCLE` set below about 1 s keeps the hand sliding continuously and trips the watchdog in that stub.
- Every animation frame still rebuilds the dropdown even when it is closed, which is most of a frame's cost. That is left to a follow-up; this record bounds how long frames can run, not what one costs.
- If two menu-bar appearances ever resolve colours differently under the same appearance name, D1 cannot separate them. The watchdog line logs the names, so such a case would be visible rather than silent.

## Related

- [ADR-0070](0070-smooth-bar-colour-transitions.md): the transitions and the frame timer this record bounds.
- [ADR-0073](0073-awaiting-icon-reserved-slot-and-slide.md): the awaiting hand's slide, a scalar tween left unscoped.
- [#554](https://github.com/artem-from-ua/tokenpace/issues/554): the report.

## Verification

With a Sidecar display, a dark wallpaper on one display and a light one on the other: 0.118.0 holds 35–40% CPU, while this build under `TOKENPACE_STUB=color-cycle` uses CPU only during each 0.8 s transition. Colours fade smoothly on both displays, each in its own bar's tones, and a system Light/Dark flip snaps the dropdown and the menu bar at once.
