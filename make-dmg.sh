#!/bin/bash
set -euo pipefail

VERSION=$(cat VERSION)
APP_PATH=".build/Relay.app"
DMG_NAME="Relay-v${VERSION}.dmg"
DMG_FINAL=".build/${DMG_NAME}"
DMGBUILD="$HOME/Library/Python/3.9/bin/dmgbuild"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: $APP_PATH not found. Run ./build-app.sh --release first."
    exit 1
fi

if [ ! -f "$DMGBUILD" ]; then
    echo "Error: dmgbuild not found. Install with: pip3 install dmgbuild"
    exit 1
fi

rm -f "$DMG_FINAL"
hdiutil detach "/Volumes/Relay" 2>/dev/null || true

echo "Creating DMG..."
APP_PATH="$APP_PATH" "$DMGBUILD" \
    -s Resources/dmg-settings.py \
    "Relay" \
    "$DMG_FINAL"

echo "Created $DMG_FINAL"
