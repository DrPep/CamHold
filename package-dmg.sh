#!/usr/bin/env bash
# Package build/CamHold.app into a mountable .dmg with a drag-to-Applications
# install layout.
#
# Usage:  ./package-dmg.sh          (runs build.sh first if the .app is missing)
# Output: build/CamHold-<version>.dmg

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CamHold"
VOL_NAME="$APP_NAME"
APP_DIR="build/$APP_NAME.app"
STAGE_DIR="build/dmg-stage"
PLIST="$APP_DIR/Contents/Info.plist"

if [[ ! -d "$APP_DIR" ]]; then
  echo "No $APP_DIR found — running build.sh first."
  ./build.sh
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo 1.0)"
DMG_PATH="build/${APP_NAME}-${VERSION}.dmg"
TMP_DMG="build/${APP_NAME}-${VERSION}.tmp.dmg"

rm -rf "$STAGE_DIR" "$DMG_PATH" "$TMP_DMG"
mkdir -p "$STAGE_DIR"

# Copy the app (preserve perms / symlinks / xattrs).
ditto "$APP_DIR" "$STAGE_DIR/$APP_NAME.app"

# The drag-to-install affordance: a symlink to /Applications in the DMG root.
ln -s /Applications "$STAGE_DIR/Applications"

# Build a read-write DMG we can arrange, then convert to compressed read-only.
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE_DIR" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$TMP_DMG" >/dev/null

MOUNT_DIR="$(mktemp -d -t camhold-dmg)"
hdiutil attach "$TMP_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -noautoopen >/dev/null

# Arrange the Finder window so the user sees the app next to the Applications
# symlink as soon as the DMG mounts. Failures here are non-fatal — the DMG
# still installs correctly without the cosmetic layout.
osascript <<EOF || true
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 760, 480}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set position of item "$APP_NAME.app" of container window to {150, 180}
    set position of item "Applications" of container window to {410, 180}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

sync
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet
rmdir "$MOUNT_DIR" 2>/dev/null || true

hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$TMP_DMG"
rm -rf "$STAGE_DIR"

# Ad-hoc sign the DMG itself so Gatekeeper has a stable identity to check.
codesign --force --sign - "$DMG_PATH" >/dev/null 2>&1 || true

echo "Built $DMG_PATH  ($(du -h "$DMG_PATH" | cut -f1))"
echo "Open: open \"$DMG_PATH\""
