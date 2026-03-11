#!/bin/bash
set -euo pipefail

# Parse flags
CONFIG="debug"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) CONFIG="release"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

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

codesign --force --sign - --entitlements /tmp/relay-entitlements.plist "$APP_DIR/MacOS/Relay"

echo "Built .build/Relay.app (v${VERSION}, build ${BUILD_NUMBER}, ${CONFIG})"
echo "Run with: open .build/Relay.app"
