#!/bin/bash
set -euo pipefail

echo "Building Relay..."
swift build

APP_DIR=".build/Relay.app/Contents"
mkdir -p "$APP_DIR/MacOS"
mkdir -p "$APP_DIR/Resources"

cp .build/debug/Relay "$APP_DIR/MacOS/Relay"

# Copy asset bundle if it exists
if [ -d ".build/debug/Relay_Relay.bundle" ]; then
    cp -R ".build/debug/Relay_Relay.bundle" "$APP_DIR/Resources/"
fi

cat > "$APP_DIR/Info.plist" << 'PLIST'
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
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>Relay uses speech recognition to transcribe voice notes that are added to your prompt context.</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>Relay uses the microphone to record voice notes for transcription.</string>
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

codesign --force --sign - --entitlements /tmp/relay-entitlements.plist "$APP_DIR/MacOS/Relay"

echo "Built .build/Relay.app"
echo "Run with: open .build/Relay.app"
