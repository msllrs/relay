#!/bin/bash
set -euo pipefail

VERSION=$(cat VERSION)
BUILD_NUMBER=$(git rev-list --count HEAD)
ARCHIVE_NAME="Relay-v${VERSION}.zip"

echo "=== Building Relay v${VERSION} (release) ==="
./build-app.sh --release

echo "=== Creating archive ==="
cd .build
ditto -c -k --keepParent Relay.app "$ARCHIVE_NAME"
cd ..

echo "=== Signing archive with Sparkle ==="
SIGN_UPDATE=$(find .build/artifacts -name "sign_update" -type f 2>/dev/null | head -1)
if [ -z "$SIGN_UPDATE" ]; then
    echo "Error: sign_update not found in .build/artifacts."
    echo "Run 'swift package resolve' first."
    exit 1
fi

SIGNATURE=$("$SIGN_UPDATE" ".build/$ARCHIVE_NAME" 2>&1)
echo "$SIGNATURE"

echo "=== Generating appcast ==="
GENERATE_APPCAST=$(find .build/artifacts -name "generate_appcast" -type f 2>/dev/null | head -1)
if [ -z "$GENERATE_APPCAST" ]; then
    echo "Warning: generate_appcast not found. Skipping appcast generation."
else
    "$GENERATE_APPCAST" .build/
    if [ -f .build/appcast.xml ]; then
        cp .build/appcast.xml appcast.xml
        echo "Updated appcast.xml"
    fi
fi

echo ""
echo "=== Release checklist ==="
echo "1. Archive: .build/$ARCHIVE_NAME"
echo "2. Upload the archive to GitHub Releases as v${VERSION}"
echo "3. Commit and push the updated appcast.xml"
echo "4. Verify the appcast URL resolves:"
echo "   https://raw.githubusercontent.com/msllrs/relay/main/appcast.xml"
