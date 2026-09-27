#!/bin/bash
# build-app.sh — assemble TokenPace.app from a release SwiftPM build.
# CLT-only friendly; no full Xcode required.
# Signs with Developer ID when available; produces an unsigned app otherwise.
# Output: ./build/TokenPace.app  (already covered by .gitignore)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="TokenPace"
OUT_DIR="${ROOT}/build"
APP="${OUT_DIR}/${APP_NAME}.app"
CONTENTS="${APP}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RES_DIR="${CONTENTS}/Resources"
PLIST_IN="${ROOT}/scripts/Info.plist.in"

# Version from VERSION file (strip whitespace); build number from git commit count.
VERSION="$(tr -d ' \t\n\r' < "${ROOT}/VERSION")"
BUILD="$(git -C "${ROOT}" rev-list --count HEAD 2>/dev/null || echo 1)"

# The `--sdk` override macOS 27 needs (empty everywhere else) — see scripts/swift-sdk-flags.sh for
# why. Shared with the pre-commit hook rather than reimplemented, so the two cannot disagree about
# which SDK this machine builds with.
#
SDK_FLAGS=()
while IFS= read -r flag; do
    SDK_FLAGS+=("${flag}")
done < <("${ROOT}/scripts/swift-sdk-flags.sh")

# Build a universal binary (arm64 + x86_64) so the .app runs natively on both Apple Silicon and
# Intel Macs. SwiftPM has no single --arch flag like Xcode, so each slice is built per-triple and
# merged with `lipo`. Each `swift build` is a no-op once cached, so re-runs are cheap.
ARCHES=(arm64 x86_64)
SLICES=()
for arch in "${ARCHES[@]}"; do
    triple="${arch}-apple-macosx"
    # Reset per arch: a fallback that one slice needed must not silently de-optimise the next one.
    OPT_FLAGS=()
    echo "==> swift build -c release --triple ${triple} (this may take a while on first run)"
    # `${SDK_FLAGS[@]+"${SDK_FLAGS[@]}"}` rather than a plain `"${SDK_FLAGS[@]}"`: `/bin/bash` on macOS
    # is 3.2, where splatting an **empty** array raises `unbound variable` under `set -u` — measured,
    # and it would break the build on exactly the machines that need no SDK override. The `+` form
    # expands to nothing when the array is empty, and to every element, individually quoted, when not.
    # `-O` first, and `-Osize` only if the compiler itself dies — so a toolchain that builds fine keeps
    # shipping the faster binary, and nothing here depends on which macOS is running.
    #
    # Swift 6.4's SIL optimizer crashes on this package at `-O`: `swift-frontend` takes an
    # EXC_BAD_ACCESS (a pointer-authentication failure) inside `SimplifyCFG::tryJumpThreading`, and the
    # driver then reports it as `unable to open dependencies file (…-primary.d)` — the crash kills the
    # frontend before it writes that side output, so the message names the symptom, not the cause. The
    # crash report is in ~/Library/Logs/DiagnosticReports/swift-frontend-*.ips.
    #
    # `-Osize` is a first-class production mode, not a diagnostic fallback — swift.org: "-Osize is meant
    # for most production code" — so a release built this way is one we can ship. It inlines less
    # aggressively, which is what steers the optimizer off the crashing path.
    if ! swift build --package-path "${ROOT}" -c release --triple "${triple}" \
            ${SDK_FLAGS[@]+"${SDK_FLAGS[@]}"} 2>&1 \
            | tee "/tmp/tokenpace-build-${arch}.log"; then
        echo "==> -O failed; retrying ${arch} with -Osize (Swift 6.4 SimplifyCFG crash)"
        OPT_FLAGS=(-Xswiftc -Osize)
        swift build --package-path "${ROOT}" -c release --triple "${triple}" \
            ${SDK_FLAGS[@]+"${SDK_FLAGS[@]}"} "${OPT_FLAGS[@]}" 2>&1 \
            | tee "/tmp/tokenpace-build-${arch}.log"
    fi
    slice_dir="$(swift build --package-path "${ROOT}" -c release --triple "${triple}" \
        ${SDK_FLAGS[@]+"${SDK_FLAGS[@]}"} ${OPT_FLAGS[@]+"${OPT_FLAGS[@]}"} --show-bin-path)"
    built="${slice_dir}/${APP_NAME}"
    [ -x "${built}" ] || { echo "error: ${arch} binary not found at ${built}" >&2; exit 1; }
    # **Copy the slice out before the next arch overwrites it.** `--show-bin-path` returns the *same*
    # `Products/Release` directory for every `--triple` on the xcbuild backend (measured on Swift 6.4),
    # so collecting paths and merging at the end silently lipo'd the last arch with itself — `lipo: same
    # architectures (x86_64) found` and no universal binary. Each slice gets its own filename here.
    #
    # Assert the slice really is the arch we asked for: with one shared output directory, a stale or
    # mis-targeted binary is otherwise indistinguishable from a fresh one, and `lipo -create` would
    # happily produce a bundle missing an architecture.
    got="$(lipo -archs "${built}")"
    [ "${got}" = "${arch}" ] \
        || { echo "error: expected ${arch} at ${built}, found '${got}'" >&2; exit 1; }
    slice="${OUT_DIR}/slice-${arch}"
    mkdir -p "${OUT_DIR}"
    cp "${built}" "${slice}"
    SLICES+=("${slice}")
done

echo "==> assembling ${APP}  (version ${VERSION}, build ${BUILD}, universal: ${ARCHES[*]})"
rm -rf "${APP}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"
# Merge the per-arch slices into one universal Mach-O.
lipo -create "${SLICES[@]}" -output "${MACOS_DIR}/${APP_NAME}"
rm -f "${SLICES[@]}"
echo "==> lipo archs: $(lipo -archs "${MACOS_DIR}/${APP_NAME}")"
# Assert the merge produced both, rather than trusting that it did: a bundle silently missing an arch
# runs fine on the machine that built it and fails on the other kind.
for arch in "${ARCHES[@]}"; do
    lipo -archs "${MACOS_DIR}/${APP_NAME}" | tr ' ' '\n' | grep -qx "${arch}" \
        || { echo "error: ${APP_NAME} is missing the ${arch} slice" >&2; exit 1; }
done

# No resource bundle to copy: the target ships no resources (the bar-style previews are rendered at
# runtime). If that ever changes, the copy has to land in `Contents/Resources/` and happen BEFORE
# codesign — a bundle added after signing breaks the seal — and it must be asserted non-empty, since
# `cp -R` of an empty directory succeeds and fails only later, in the UI. See
# docs/reference/conventions.md.

# Info.plist with version/build substituted from template.
sed -e "s/__VERSION__/${VERSION}/g" -e "s/__BUILD__/${BUILD}/g" \
    "${PLIST_IN}" > "${CONTENTS}/Info.plist"

# PkgInfo — legacy but harmless; content is APPL + four question marks.
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# Validate the generated plist (fail fast on malformed XML).
plutil -lint "${CONTENTS}/Info.plist"

# --- Optional code signing (only when a Developer ID Application identity exists) ---
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -oE '"Developer ID Application: [^"]+"' | head -1 | tr -d '"' || true)"

if [ -n "${IDENTITY}" ]; then
    echo "==> codesign --options runtime  (identity: ${IDENTITY})"
    codesign --force --options runtime --timestamp \
             --sign "${IDENTITY}" "${APP}"
    codesign --verify --strict --verbose=2 "${APP}"

    # --- Optional notarization (requires a stored notarytool keychain profile) ---
    # Create the profile once with:
    #   xcrun notarytool store-credentials tokenpace-notary --apple-id <id> --team-id <TEAMID>
    if xcrun notarytool history --keychain-profile tokenpace-notary >/dev/null 2>&1; then
        echo "==> notarize (notarytool submit --wait); this can take several minutes"
        ZIP="${OUT_DIR}/${APP_NAME}.zip"
        ditto -c -k --keepParent "${APP}" "${ZIP}"
        xcrun notarytool submit "${ZIP}" \
              --keychain-profile tokenpace-notary --wait
        xcrun stapler staple "${APP}"
        rm -f "${ZIP}"
        echo "==> notarization complete"
    else
        echo "==> notarization skipped (no 'tokenpace-notary' notarytool profile found)"
    fi
else
    echo "==> signing skipped (no Developer ID identity found) — producing UNSIGNED app"
    echo "    Gatekeeper tip: right-click -> Open, or:"
    echo "    xattr -dr com.apple.quarantine \"${APP}\""
fi

echo ""
echo "==> done: ${APP}  (version ${VERSION}, build ${BUILD})"
