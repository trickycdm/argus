#!/bin/bash
# Builds Argus and assembles a menu-bar-only .app bundle in dist/.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"   # prints the path, no rebuild

APP="$REPO_DIR/dist/Argus.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/Argus" "$APP/Contents/MacOS/Argus"
cp "$REPO_DIR/scripts/Info.plist" "$APP/Contents/Info.plist"
cp "$REPO_DIR/scripts/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign --force -s - "$APP"

# Launch Services caches the icon per bundle id, and macOS notification banners
# keep drawing whatever was registered first — so an icon added after the app's
# first launch shows as a frosted placeholder in banners while Finder looks
# fine. Dropping the record before re-registering is what actually refreshes it;
# `-f` alone updates the path but not the notification icon. Best-effort: a
# failure here doesn't invalidate the bundle.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -x $LSREGISTER ]]; then
  "$LSREGISTER" -u "$APP" 2>/dev/null || true
  "$LSREGISTER" -f "$APP" 2>/dev/null || true
fi

echo "built: $APP"
echo "run:   open \"$APP\""
echo "tip:   cp -R \"$APP\" /Applications/ and add as a Login Item for autostart"
