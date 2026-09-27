---
status: accepted
date: 2026-09-27
---

# ADR-0133: The release build falls back to `-Osize` only after `-O` has actually crashed the compiler

## Context

`swift build -c release` stopped producing a binary on Swift 6.4 (`swiftlang-6.4.0.34.1`,
macOS 27.0). It reported:

```
error: unable to open dependencies file (…/Objects-normal/arm64/TokenPace-primary.d)
error: SwiftDriver\ Compilation\ Requirements TokenPace normal arm64 … failed
```

**That message names the aftermath, not the cause.** The `.d` is a side output; `swift-frontend`
crashes before writing it, and the driver then notices the file is missing. The crash reports in
`~/Library/Logs/DiagnosticReports/swift-frontend-*.ips`, timestamped to each build attempt, say what
happened:

```
exception:   EXC_BAD_ACCESS (SIGKILL) — KERN_INVALID_ADDRESS
             (possible pointer authentication failure)
termination: PAC_EXCEPTION
faulting:    swift::SILType::isTrivial(swift::SILFunction const&) const
             SimplifyCFG::tryJumpThreading(swift::BranchInst*)
             SimplifyCFG::run() → SILPassManager::runFunctionPasses
             swift::runSILOptimizationPasses(swift::SILModule&)
```

A bug in the SIL optimizer. `SimplifyCFG` is an optimization pass, which is why debug builds were
unaffected and only release died — and why the failure looked like a build-system problem for as long
as nobody opened the crash logs.

It is **not** the macro-plugin problem the same toolchain also has. From the macOS 27 SDK on,
SwiftUI's `@State` is an attached macro whose plugin ships only inside Xcode.app, and CLT-only
machines need an older SDK for it ([building.md](../guides/building.md#swiftui-macros-on-macos-27)).
That one Xcode would fix. This one it would not: Xcode ships the same `swift-frontend`, and the
failing release invocation loads no plugins at all. Conflating the two cost this session a wrong
conclusion — "the release path needs Xcode or an older macOS" — which was recorded in the guide
before the crash logs were read, and is now corrected there.

Two flags were verified to build the package: `-Osize`, and
`-Xllvm -sil-disable-pass=simplify-cfg`. A third option — do nothing and ship releases from another
machine — was live, since the project's minimum target is macOS 15 and the maintainer's own build
must keep working there.

## Decision

### D1. Try `-O`, and use `-Osize` only when the compiler has actually failed

[`scripts/build-app.sh`](../../scripts/build-app.sh) runs the ordinary `-O` release build first. Only
if that command fails does it retry the same slice with `-Xswiftc -Osize`, announcing it in the log.

**The gate is the observed failure, not a version check.** Nothing keys off the macOS release, the
Swift release or the SDK: a toolchain without the bug takes the first path and ships the faster
binary, and a fixed toolchain returns to `-O` with no edit here. On macOS 15 the release builds
exactly as it did before this ADR.

### D2. `-Osize`, not a disabled optimizer pass

`-Osize` is a first-class production mode — [swift.org](https://www.swift.org/blog/osize/): "-Osize
is meant for most production code" — with a lower inlining threshold, which is what steers the
optimizer off the crashing path. `-Xllvm -sil-disable-pass=simplify-cfg` also builds and is recorded
in [building.md](../guides/building.md), but it turns off a pass the pipeline runs many times over,
which is a wider blast radius than lowering an inlining threshold.

### D3. The fallback is per architecture

The flag is reset at the top of each `--triple` iteration, so a fallback one slice needed cannot
silently de-optimize the other. Both currently take it; that is an observation, not an assumption the
script encodes.

### D4. Each universal slice is copied aside and asserted

`swift build --show-bin-path` returns the **same** `Products/Release` directory for every `--triple`
on this backend (measured). Collecting paths and merging at the end therefore lipo'd the last
architecture with itself — `lipo: same architectures (x86_64) found` — and produced a single-arch
bundle. Each slice is now copied to its own filename as it is built, asserted with `lipo -archs` to
be the architecture requested, and the merged binary is asserted to carry every entry of `ARCHES`.

This defect is independent of D1: it predates the fallback and would have shipped a single-arch
bundle regardless.

## Consequences

The release path works on the maintainer's machine again, with no Xcode and no second machine —
signed, notarized, stapled, `spctl` accepting it as `Notarized Developer ID`.

**Releases built on an affected toolchain are `-Osize` binaries.** swift.org documents no correctness
difference, and the cost is less aggressive inlining; for a menu-bar widget that polls every few
minutes it is not a measurable cost, and no benchmark was run to claim otherwise. But the shipped
artifact is no longer what `-O` would have produced, and that is worth knowing when reading a
performance report.

**Two releases built from the same commit on different machines can differ in optimization level.**
That is the direct price of gating on observed behaviour instead of pinning a flag, and it is
deliberate: the alternative is de-optimizing every future release to work around a bug that will be
fixed upstream.

**A log line that reads like a failure is now the normal path.** `-O failed; retrying … with -Osize`
appears in every release build on an affected toolchain. The guide says so, but anyone reading the
log without that context sees an error and a build that nevertheless succeeded.

**The upstream bug is unreported and unfixed.** No matching signature was found on the Swift forums,
the Apple developer forums, GitHub or Reddit; the nearest is
[swiftlang/swift#92192](https://github.com/swiftlang/swift/issues/92192), the same
`SimplifyCFG`/jump-threading area but a different platform and failure mode. Until it is filed and
fixed, this fallback is the whole mitigation, and no one is tracking a version to remove it at.

## Verification

Full [`scripts/build-app.sh`](../../scripts/build-app.sh) from a cleared release cache:

```
==> -O failed; retrying arm64 with -Osize (Swift 6.4 SimplifyCFG crash)
==> -O failed; retrying x86_64 with -Osize (Swift 6.4 SimplifyCFG crash)
==> lipo archs: x86_64 arm64
==> notarization complete
```

On the resulting bundle:

- `lipo -archs` → `x86_64 arm64`
- `otool -l … LC_BUILD_VERSION` → `minos 15.0` on **both** slices, so the deployment target is
  unchanged and the app still runs on macOS 15
- `spctl -a -t exec -vv` → `accepted`, `source=Notarized Developer ID`

## Related

- [ADR-0004](0004-build-system.md) — SwiftPM plus a build script rather than an Xcode project.
- [building.md](../guides/building.md) — the crash trace, the second workaround, and the separate
  `@State` macro-plugin problem that does need an older SDK.
