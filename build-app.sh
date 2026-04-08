#!/bin/bash
set -euo pipefail

# Parse flags
CONFIG="debug"
NOTARIZE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) CONFIG="release"; shift ;;
        --notarize) NOTARIZE=true; CONFIG="release"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

SIGNING_IDENTITY="Developer ID Application: LFSGD LTD (TKGBUP8TGN)"
NOTARIZE_PROFILE="relay-notarize"

# Version info
VERSION=$(cat VERSION)
BUILD_NUMBER=$(git rev-list --count HEAD)

echo "Building Relay v${VERSION} (build ${BUILD_NUMBER}) [${CONFIG}]..."
swift build -c "$CONFIG"

APP_DIR=".build/Relay.app/Contents"
mkdir -p "$APP_DIR/MacOS"
mkdir -p "$APP_DIR/Resources"

cp ".build/${CONFIG}/Relay" "$APP_DIR/MacOS/Relay"

# Copy asset bundle if it exists
if [ -d ".build/${CONFIG}/Relay_Relay.bundle" ]; then
    cp -R ".build/${CONFIG}/Relay_Relay.bundle" "$APP_DIR/Resources/"
fi

# Copy app icon
cp Relay/Resources/AppIcon.icns "$APP_DIR/Resources/AppIcon.icns"

# Embed Sparkle framework
SPARKLE_FRAMEWORK=$(find .build/artifacts -path "*/Sparkle.framework" -type d 2>/dev/null | head -1)
if [ -n "$SPARKLE_FRAMEWORK" ]; then
    mkdir -p "$APP_DIR/Frameworks"
    cp -R "$SPARKLE_FRAMEWORK" "$APP_DIR/Frameworks/"
    echo "Embedded Sparkle.framework"
fi

cat > "$APP_DIR/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.msllrs.relay</string>
	<key>CFBundleName</key>
	<string>Relay</string>
	<key>CFBundleExecutable</key>
	<string>Relay</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD_NUMBER}</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>Relay uses on-device speech recognition to transcribe voice notes. No audio data is sent to Apple.</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>Relay uses the microphone to record voice notes for transcription.</string>
	<key>SUFeedURL</key>
	<string>https://raw.githubusercontent.com/msllrs/relay/main/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>yjYIMOT7YoSbNQlT34KAgyBprxyi6rAN9k8k205798g=</string>
	<key>SUScheduledCheckInterval</key>
	<integer>86400</integer>
</dict>
</plist>
PLIST

# Sign with audio-input entitlement
cat > /tmp/relay-entitlements.plist << 'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.device.audio-input</key>
	<true/>
</dict>
</plist>
ENT

# Ensure @rpath resolves to the embedded Frameworks directory
install_name_tool -add_rpath @executable_path/../Frameworks "$APP_DIR/MacOS/Relay" 2>/dev/null || true

APP_BUNDLE=".build/Relay.app"

if $NOTARIZE; then
    echo "Signing with Developer ID..."

    # Sign Sparkle framework first (inside-out signing)
    if [ -d "$APP_DIR/Frameworks/Sparkle.framework" ]; then
        SPARKLE_DIR="$APP_DIR/Frameworks/Sparkle.framework/Versions/B"
        codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
            "$SPARKLE_DIR/XPCServices/Installer.xpc"
        codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
            "$SPARKLE_DIR/XPCServices/Downloader.xpc"
        codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
            "$SPARKLE_DIR/Autoupdate"
        codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
            "$SPARKLE_DIR/Updater.app"
        codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
            "$APP_DIR/Frameworks/Sparkle.framework"
        echo "Signed Sparkle.framework"
    fi

    # Sign the main binary with hardened runtime + timestamp (required for notarization)
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
        --entitlements /tmp/relay-entitlements.plist \
        "$APP_BUNDLE"

    echo "Verifying signature..."
    codesign --verify --deep --strict "$APP_BUNDLE"

    # Create ZIP for notarization
    NOTARIZE_ZIP=".build/Relay-notarize.zip"
    ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"

    echo "Submitting to Apple for notarization..."
    xcrun notarytool submit "$NOTARIZE_ZIP" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$APP_BUNDLE"

    echo "Verifying notarization..."
    spctl --assess --type execute --verbose "$APP_BUNDLE"

    rm "$NOTARIZE_ZIP"
    echo "Notarization complete!"

    # Create release artifacts
    RELEASE_ZIP=".build/Relay-v${VERSION}.zip"
    RELEASE_DMG=".build/Relay-v${VERSION}.dmg"
    ditto -c -k --keepParent "$APP_BUNDLE" "$RELEASE_ZIP"

    rm -f "$RELEASE_DMG"

    # Stage DMG contents: app + Applications alias with custom icon
    DMG_STAGING=".build/dmg-staging"
    rm -rf "$DMG_STAGING"
    mkdir -p "$DMG_STAGING"
    cp -R "$APP_BUNDLE" "$DMG_STAGING/"

    # Create Finder alias to /Applications and set custom folder icon
    osascript -e '
    tell application "Finder"
        set theAlias to make alias file to POSIX file "/Applications" at POSIX file "'"$(pwd)/$DMG_STAGING"'"
        set name of theAlias to "Applications"
    end tell'
    fileicon set "$DMG_STAGING/Applications" Resources/dmg-applications.png

    create-dmg \
        --volname "Relay" \
        --volicon "Relay/Resources/AppIcon.icns" \
        --background "Resources/dmg-bg@2x.png" \
        --window-pos 200 120 \
        --window-size 480 270 \
        --icon-size 80 \
        --icon "Relay.app" 140 110 \
        --hide-extension "Relay.app" \
        --icon "Applications" 340 110 \
        --no-internet-enable \
        "$RELEASE_DMG" "$DMG_STAGING"

    rm -rf "$DMG_STAGING"

    echo "Release artifacts:"
    echo "  $RELEASE_ZIP"
    echo "  $RELEASE_DMG"
else
    # Ad-hoc signing for local development
    codesign --force --sign - --entitlements /tmp/relay-entitlements.plist "$APP_DIR/MacOS/Relay"
fi

echo "Built $APP_BUNDLE (v${VERSION}, build ${BUILD_NUMBER}, ${CONFIG})"
echo "Run with: open $APP_BUNDLE"
