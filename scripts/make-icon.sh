#!/bin/bash
# Regenerates scripts/AppIcon.icns from scripts/AppIcon.svg using system
# tools only (sips + iconutil). Run after editing the SVG — the .icns is
# committed, and bundle.sh copies it into the app; it never regenerates it.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="$REPO_DIR/scripts/AppIcon.svg"
OUT="$REPO_DIR/scripts/AppIcon.icns"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ICONSET="$TMP/AppIcon.iconset"
mkdir "$ICONSET"

# Rasterise the master once at 1024, downsample for every slot — one
# rasterisation keeps anti-aliasing consistent across sizes.
sips -s format png --resampleHeightWidth 1024 1024 "$SVG" \
     --out "$TMP/master.png" >/dev/null

while read -r px name; do
  sips -s format png --resampleHeightWidth "$px" "$px" "$TMP/master.png" \
       --out "$ICONSET/$name" >/dev/null
done <<'EOF'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
EOF

iconutil -c icns "$ICONSET" -o "$OUT"
echo "wrote: $OUT"
