#!/usr/bin/env bash
# Launch the Meeting Transcriber menu bar app.
# Builds an .app bundle so macOS APIs (notifications, etc.) work correctly.
#
# --build-only: Build the bundle but skip `open -W`. Used by the Pattern-C
#   E2E driver (scripts/e2e-app.sh) which deploys the bundle to a stable
#   path and launches it itself; opening the in-tree bundle there would
#   confuse macOS LaunchServices about which one to use for TCC.

set -euo pipefail

BUILD_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --build-only) BUILD_ONLY=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRANSCRIBER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/sawti-paths.sh"

export TRANSCRIBER_ROOT

SPM_DIR="$TRANSCRIBER_ROOT/app/MeetingTranscriber"
BUILD_BINARY="$SPM_DIR/.build/release/MeetingTranscriber"
HELPER_BUILD_BINARY="$SPM_DIR/.build/release/SawtiCaptureHelper"
APP_BUNDLE="$SPM_DIR/.build/MeetingTranscriber-Dev.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_BINARY="$APP_MACOS/MeetingTranscriber"
APP_HELPER="$APP_BUNDLE/Contents/Helpers/SawtiCaptureHelper"
INFO_PLIST="$SPM_DIR/Sources/Info.plist"
# shellcheck source=lib/bundle-ids.sh
source "$SCRIPT_DIR/lib/bundle-ids.sh"

# Always rebuild to pick up code changes
echo "Building Sawti app..."
cd "$SPM_DIR"
SWIFT_BUILD_FLAGS=(-c release --disable-keychain --disable-automatic-resolution)
# Opt-in fault-injection build for the mic-device-change e2e lane only
# (scripts/e2e-app.sh --mic-device-change). Compiles the issue #379
# reproduction seam in MicCaptureHandler; never set for normal/release builds.
if [ -n "${MTT_FAULT_INJECTION:-}" ]; then
    SWIFT_BUILD_FLAGS+=(-Xswiftc -DE2E_FAULT_INJECTION)
    echo "  (fault-injection build: -DE2E_FAULT_INJECTION)"
fi
swift build "${SWIFT_BUILD_FLAGS[@]}" --product MeetingTranscriber
swift build "${SWIFT_BUILD_FLAGS[@]}" --product SawtiCaptureHelper

# Which certificate to sign with, decided BEFORE the bundle is touched. Half of
# the answer is the certificate the previous build signed this bundle with,
# which lives in the main executable's embedded signature; the
# `cp "$BUILD_BINARY"` below replaces that executable with a freshly linked,
# ad-hoc signed one, after which there is no certificate left to read (measured,
# see choose_signing_identity). Reported further down, next to the codesign it
# feeds.
# shellcheck source=lib/signing.sh
source "$SCRIPT_DIR/lib/signing.sh"
choose_signing_identity "$APP_BUNDLE"

# Assemble .app bundle
mkdir -p "$APP_MACOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$SPM_DIR/Sources/Resources/SawtiLogo.png" "$APP_BUNDLE/Contents/Resources/SawtiLogo.png"
# Info.plist names the AppIcon asset, so package the same ICNS that the release
# bundle gets. Without it, Launchpad shows its generic placeholder even though
# the menu-bar PNG is present.
ICONSET_SRC="$SPM_DIR/Sources/Assets.xcassets/AppIcon.appiconset"
if [ -d "$ICONSET_SRC" ]; then
    ICONSET="$SPM_DIR/.build/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    cp "$ICONSET_SRC/icon_16x16.png"      "$ICONSET/icon_16x16.png"
    cp "$ICONSET_SRC/icon_16x16@2x.png"   "$ICONSET/icon_16x16@2x.png"
    cp "$ICONSET_SRC/icon_32x32.png"      "$ICONSET/icon_32x32.png"
    cp "$ICONSET_SRC/icon_32x32@2x.png"   "$ICONSET/icon_32x32@2x.png"
    cp "$ICONSET_SRC/icon_128x128.png"    "$ICONSET/icon_128x128.png"
    cp "$ICONSET_SRC/icon_128x128@2x.png" "$ICONSET/icon_128x128@2x.png"
    cp "$ICONSET_SRC/icon_256x256.png"    "$ICONSET/icon_256x256.png"
    cp "$ICONSET_SRC/icon_256x256@2x.png" "$ICONSET/icon_256x256@2x.png"
    cp "$ICONSET_SRC/icon_512x512.png"    "$ICONSET/icon_512x512.png"
    cp "$ICONSET_SRC/icon_512x512@2x.png" "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
fi
# Use the dev bundle identifier to keep permissions separate from release.
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEV_BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"

# Inject version from VERSION file
APP_VERSION=$(cat "$TRANSCRIBER_ROOT/VERSION" | tr -d '[:space:]')
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"

# Inject git commit hash into Info.plist
GIT_HASH=$(git -C "$TRANSCRIBER_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
/usr/libexec/PlistBuddy -c "Add :GitCommitHash string $GIT_HASH" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :GitCommitHash $GIT_HASH" "$APP_BUNDLE/Contents/Info.plist"

cp "$BUILD_BINARY" "$APP_BINARY"
# SwiftPM links Sparkle through @rpath. Match the release bundle layout so the
# development app can load the updater framework at launch too.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY"
if [ ! -x "$HELPER_BUILD_BINARY" ]; then
    echo "ERROR: SwiftPM did not build SawtiCaptureHelper" >&2
    exit 1
fi
mkdir -p "$(dirname "$APP_HELPER")"
cp "$HELPER_BUILD_BINARY" "$APP_HELPER"

SPARKLE_FRAMEWORK="$SPM_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    echo "ERROR: Sparkle.framework was not resolved by SwiftPM" >&2
    exit 1
fi
APP_FRAMEWORKS="$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$APP_FRAMEWORKS"
rm -rf "$APP_FRAMEWORKS/Sparkle.framework"
ditto "$SPARKLE_FRAMEWORK" "$APP_FRAMEWORKS/Sparkle.framework"

# Licences for the third-party code and weights this bundle redistributes. The
# dev app is not distributed, but scripts/e2e-app.sh deploys it, so keeping it
# identical to a release bundle is what makes an e2e run evidence about the
# thing users get. Fatal here, unlike the model below: a missing licence file in
# the repo is a repo bug, not an unreachable download.
# shellcheck source=lib/bundle-licenses.sh
source "$SCRIPT_DIR/lib/bundle-licenses.sh"
install_third_party_licenses "$APP_BUNDLE/Contents/Resources"

# LocalVQE echo-cancellation model, the same resources build_release.sh bundles,
# so the dev app (which scripts/e2e-app.sh deploys) can exercise the feature.
# Non-fatal here and fatal there: an unreachable download must not stop someone
# running the dev app for unrelated work. Stderr is deliberately not silenced —
# that is where a checksum mismatch reports itself, and "model unavailable"
# alone would hide a poisoned cache.
# shellcheck source=lib/localvqe-resources.sh
source "$SCRIPT_DIR/lib/localvqe-resources.sh"
if [ "${SAWTI_SKIP_OPTIONAL_MODEL_FETCH:-0}" = "1" ]; then
    echo "  Skipping the optional LocalVQE model fetch; echo cancellation will find no model."
elif ! install_localvqe_resources "$APP_BUNDLE/Contents/Resources"; then
    echo "  WARNING: LocalVQE model unavailable; echo cancellation will find no model."
fi

# Code-sign so macOS keeps its permission grants across rebuilds.
# Uses SHA-1 hash to avoid "ambiguous identity" errors with duplicate names.
#
# Signing happens WITH the Homebrew entitlements, the same set build_release.sh
# uses: without them the dev build carries no entitlements at all, so anything
# gated on one behaves differently here than in a release build, notably the
# time-sensitive consent prompt (issue #543).
#
# Which certificate, and why, is choose_signing_identity's call: the one this
# bundle already carries, else the Developer ID, else the first the keychain
# lists, with a note that grants made against another certificate will not
# apply. TCC binds a grant to the certificate's leaf SHA-1, so say which rule
# chose and which certificate it is. Without this the build log shows only a
# hash, and the whole reason that choice exists is that the wrong certificate
# is invisible until the app silently records nothing.
if [ -n "$CHOSEN_IDENTITY" ]; then
    echo "  Signing identity: $CHOSEN_IDENTITY_REASON"
    printf '%s\n' "$CHOSEN_IDENTITY_LISTING" | sed 's/^/    /'
fi
# $DEV_ENTITLEMENTS is that same path, named once in the library so this build
# and any later re-sign of the deployed bundle cannot drift apart (issue #609).
prepare_signing "$APP_BUNDLE" "$DEV_ENTITLEMENTS" "$DEV_BUNDLE_ID" "$CHOSEN_IDENTITY"
if [ -n "$SIGNING_IDENTITY" ]; then
    codesign --force --sign "$SIGNING_IDENTITY" --identifier "$DEV_BUNDLE_ID" \
        --entitlements "$DEV_ENTITLEMENTS" "$APP_HELPER"
else
    codesign --force --sign - --identifier "$DEV_BUNDLE_ID" \
        --entitlements "$DEV_ENTITLEMENTS" "$APP_HELPER"
fi
codesign --verify --strict "$APP_HELPER"
if [ -n "$SIGNING_IDENTITY" ]; then
    # Failure is fatal and its stderr is kept. This used to be `2>/dev/null && echo`,
    # which hid both: a bad entitlements path left the bundle completely UNSIGNED
    # with no diagnostic, and every lane that rsyncs it then loses its TCC grants.
    codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$SIGNING_ENTITLEMENTS" "$APP_BUNDLE" \
        || { echo "codesign failed for $APP_BUNDLE (identity $SIGNING_IDENTITY, entitlements $SIGNING_ENTITLEMENTS)" >&2; exit 1; }
    echo "  Signed with: $SIGNING_IDENTITY (+ entitlements)"
else
    # Not fatal: a contributor without a certificate can still run the app.
    # Always replace a prior bundle signature with a fresh ad-hoc signature;
    # otherwise newly assembled resources and binaries can sit under an old
    # CodeDirectory and fail strict verification or LaunchServices checks.
    # Ad-hoc signing does not preserve TCC grants across rebuilds.
    codesign --force --sign - --identifier "$DEV_BUNDLE_ID" \
        --entitlements "$SIGNING_ENTITLEMENTS" "$APP_BUNDLE"
    echo "  WARNING: no certificate identity is available; bundle is ad-hoc signed"
    echo "  and microphone / screen-capture TCC grants may need to be re-authorized."
fi
verify_signing "$APP_BUNDLE"

if [ "$BUILD_ONLY" = true ]; then
    echo "Bundle ready: $APP_BUNDLE"
    exit 0
fi

echo "Starting Sawti..."
echo "  TRANSCRIBER_ROOT=$TRANSCRIBER_ROOT"

# Launch via `open` so macOS LaunchServices properly registers the app
# (required for notification permissions, etc.).
# The app discovers the project root by walking up from the executable.
sawti_open_app "$APP_BUNDLE" -W
