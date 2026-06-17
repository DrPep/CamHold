#!/usr/bin/env bash
# Fallback build script for environments without a working `swift build`
# (e.g. a mismatched Command Line Tools install). Produces a runnable
# .app bundle in ./build/CamHold.app.
#
# On a normal dev machine, prefer:  swift build -c release

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CamHold"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

# Pick an SDK. Users can override via SDKROOT.
# Default: prefer xcrun, but fall back to the newest *installed* SDK whose
# version is <= the running swiftc's major, so we don't hit a version mismatch
# when the Command Line Tools ship a bleeding-edge SDK with an older compiler.
pick_sdk() {
  if [[ -n "${SDKROOT:-}" ]]; then echo "$SDKROOT"; return; fi

  # Determine swiftc's target macOS major so we can reject SDKs that are newer
  # than the compiler supports (e.g. CLT ships MacOSX26 SDK alongside Swift 6.1).
  local sc_major
  sc_major="$(swiftc -print-target-info 2>/dev/null \
    | sed -n 's/.*"triple": "[^"]*macosx\([0-9][0-9]*\).*/\1/p' | head -1)"

  sdk_ok() {
    local sdk="$1"
    [[ -d "$sdk" ]] || return 1
    [[ -z "$sc_major" ]] && return 0
    local ver
    ver="$(basename "$sdk" | sed -n 's/^MacOSX\([0-9][0-9]*\).*/\1/p')"
    [[ -z "$ver" ]] && return 0          # unversioned symlink: trust it
    (( ver <= sc_major ))
  }

  # Try xcrun first, but only accept it if the SDK is compatible.
  local try
  try="$(xcrun --show-sdk-path 2>/dev/null || true)"
  if sdk_ok "$try"; then echo "$try"; return; fi

  # Otherwise pick the newest installed SDK that swiftc can actually parse.
  local root=/Library/Developer/CommandLineTools/SDKs cand
  while IFS= read -r cand; do
    if sdk_ok "$cand"; then echo "$cand"; return; fi
  done < <(ls -d "$root"/MacOSX*.sdk 2>/dev/null | sort -Vr)

  echo "build.sh: no compatible macOS SDK found for swiftc (major=$sc_major)" >&2
  return 1
}
SDK="$(pick_sdk)"
TARGET="${MACOSX_TARGET:-arm64-apple-macos13}"

echo "Using SDK:    $SDK"
echo "Using target: $TARGET"

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

swiftc \
  -sdk "$SDK" \
  -target "$TARGET" \
  -O \
  -o "$MACOS_DIR/$APP_NAME" \
  Sources/CamHold/main.swift \
  Sources/CamHold/AppDelegate.swift \
  Sources/CamHold/Preferences.swift \
  Sources/CamHold/CameraEnumerator.swift \
  Sources/CamHold/FormatSelector.swift \
  Sources/CamHold/NoopVideoOutput.swift \
  Sources/CamHold/CameraController.swift \
  Sources/CamHold/StatusItemController.swift \
  Sources/CamHold/CMIODevice.swift \
  Sources/CamHold/CMIORunningListener.swift \
  Sources/CamHold/BundleProcessProbe.swift \
  Sources/CamHold/WorkspaceAppObserver.swift \
  Sources/CamHold/AutoHoldCoordinator.swift \
  -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreMediaIO

cp Sources/CamHold/Resources/Info.plist "$APP_DIR/Contents/Info.plist"

# Ad-hoc sign so TCC (camera permission) has a stable code identity.
codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null 2>&1 || true

echo "Built $APP_DIR"
echo "Run:  open $APP_DIR   (or $MACOS_DIR/$APP_NAME for stderr logs)"
