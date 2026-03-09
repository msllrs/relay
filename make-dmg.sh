#!/bin/bash
set -euo pipefail

VERSION=$(cat VERSION)
DMG_NAME="Relay-${VERSION}.dmg"
STAGING_DIR=".build/dmg-staging"

echo "Building release..."
./build-app.sh --release

echo "Creating DMG..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

cp -R .build/Relay.app "$STAGING_DIR/Relay.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f ".build/${DMG_NAME}"
hdiutil create \
    -volname "Relay" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    ".build/${DMG_NAME}"

rm -rf "$STAGING_DIR"

echo "Created .build/${DMG_NAME}"
