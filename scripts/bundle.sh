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

codesign --force -s - "$APP"

echo "built: $APP"
echo "run:   open \"$APP\""
echo "tip:   cp -R \"$APP\" /Applications/ and add as a Login Item for autostart"
