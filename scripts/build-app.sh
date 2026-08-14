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

# Build a universal binary (arm64 + x86_64) so the .app runs natively on both Apple Silicon and
# Intel Macs. SwiftPM has no single --arch flag like Xcode, so each slice is built per-triple and
# merged with `lipo`. Each `swift build` is a no-op once cached, so re-runs are cheap.
ARCHES=(arm64 x86_64)
SLICES=()
for arch in "${ARCHES[@]}"; do
    triple="${arch}-apple-macosx"
    echo "==> swift build -c release --triple ${triple} (this may take a while on first run)"
    swift build --package-path "${ROOT}" -c release --triple "${triple}" 2>&1 \
        | tee "/tmp/tokenpace-build-${arch}.log"
    slice_dir="$(swift build --package-path "${ROOT}" -c release --triple "${triple}" --show-bin-path)"
    slice="${slice_dir}/${APP_NAME}"
    [ -x "${slice}" ] || { echo "error: ${arch} binary not found at ${slice}" >&2; exit 1; }
    SLICES+=("${slice}")
done

echo "==> assembling ${APP}  (version ${VERSION}, build ${BUILD}, universal: ${ARCHES[*]})"
rm -rf "${APP}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"
# Merge the per-arch slices into one universal Mach-O.
lipo -create "${SLICES[@]}" -output "${MACOS_DIR}/${APP_NAME}"
echo "==> lipo archs: $(lipo -archs "${MACOS_DIR}/${APP_NAME}")"

# SwiftPM resource bundle (`Bundle.module`) — the bar-style preview thumbnails.
# `swift run` finds it beside the binary, so a missing copy here is invisible until someone opens
# Settings in a real .app. Resources are architecture-independent, so both slices produce identical
# bundles and the first one is enough — there is no lipo-style merge for resources.
# Must happen BEFORE codesign: a bundle added after signing breaks the seal.
BUNDLE_NAME="${APP_NAME}_${APP_NAME}.bundle"
BUNDLE_SRC="$(dirname "${SLICES[0]}")/${BUNDLE_NAME}"
[ -d "${BUNDLE_SRC}" ] || {
    echo "error: resource bundle not found at ${BUNDLE_SRC}" >&2
    echo "       (renamed the package/target? update BUNDLE_NAME above)" >&2
    exit 1
}
cp -R "${BUNDLE_SRC}" "${RES_DIR}/"
echo "==> bundled resources: ${BUNDLE_NAME}"

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
