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

# Debug builds get a distinct bundle identity + name so macOS treats them as a
# separate app from the production install. This keeps their TCC grants (Screen
# Recording, Accessibility) isolated — without it, "Quit & Reopen" after changing
# a permission relaunches whichever copy owns com.msllrs.relay (often production),
# and the dev build never picks up the refreshed grant.
if [ "$CONFIG" = "debug" ]; then
    BUNDLE_ID="com.msllrs.relay.dev"
    DISPLAY_NAME="Relay Dev"
    # Separate scheme so dev-build testing can't hijack relay:// links aimed at
    # the production install (LaunchServices routes a scheme to one app only).
    URL_SCHEME="relay-dev"
    # Inverted-color icon so dev and production are distinguishable in the
    # Dock, app switcher, and permission lists.
    ICON_FILE="AppIcon-dev.icns"
    # Distinct bundle file name too — permission lists (TCC) display the file
    # name, not CFBundleDisplayName, so "Relay.app" twice is indistinguishable.
    APP_NAME="Relay Dev.app"
else
    BUNDLE_ID="com.msllrs.relay"
    DISPLAY_NAME="Relay"
    URL_SCHEME="relay"
    ICON_FILE="AppIcon.icns"
    APP_NAME="Relay.app"
fi

echo "Building Relay v${VERSION} (build ${BUILD_NUMBER}) [${CONFIG}] id=${BUNDLE_ID}..."
swift build -c "$CONFIG"

# Debug bundles used to be named Relay.app — remove strays so `open` and
# LaunchServices can't resolve to a stale copy.
if [ "$CONFIG" = "debug" ] && [ -d ".build/Relay.app" ]; then
    rm -rf ".build/Relay.app"
fi

# Assemble into a fresh bundle: cp -R into an existing one MERGES directories,
# so removed resources (old sounds, assets) would otherwise ship forever.
rm -rf ".build/${APP_NAME}"

APP_DIR=".build/${APP_NAME}/Contents"
mkdir -p "$APP_DIR/MacOS"
mkdir -p "$APP_DIR/Resources"

cp ".build/${CONFIG}/Relay" "$APP_DIR/MacOS/Relay"

# Copy asset bundle if it exists
if [ -d ".build/${CONFIG}/Relay_Relay.bundle" ]; then
    cp -R ".build/${CONFIG}/Relay_Relay.bundle" "$APP_DIR/Resources/"
fi

# Copy app icon
cp "Relay/Resources/${ICON_FILE}" "$APP_DIR/Resources/AppIcon.icns"

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
	<string>${BUNDLE_ID}</string>
	<key>CFBundleName</key>
	<string>${DISPLAY_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${DISPLAY_NAME}</string>
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
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>${BUNDLE_ID}</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>${URL_SCHEME}</string>
			</array>
		</dict>
	</array>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>Relay uses on-device speech recognition to transcribe voice notes. No audio data is sent to Apple.</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>Relay uses the microphone to record voice notes for transcription.</string>
	<key>NSScreenCaptureUsageDescription</key>
	<string>Relay captures a small region of your screen when you draw an annotation, to send visual context to Claude Code.</string>
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

APP_BUNDLE=".build/${APP_NAME}"

if $NOTARIZE; then
    echo "Signing with Developer ID..."

    # Strip extended attributes first (same as the dev branch) — leftover
    # resource forks make codesign fail with "detritus not allowed".
    xattr -cr "$APP_BUNDLE"

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
    # Ad-hoc signing for local development.
    # Strip extended attributes first — leftover resource forks/Finder xattrs make
    # codesign emit "resource fork ... not allowed" and produce an invalid signature
    # that gets SIGKILLed at launch.
    xattr -cr "$APP_BUNDLE"
    # Sign debug with Developer ID (not ad-hoc) so the build has a STABLE code
    # identity. TCC (Screen Recording, Accessibility) attaches grants to that
    # identity and persists them across rebuilds; ad-hoc signatures change every
    # build and never reliably land a row in the permission list. Falls back to
    # ad-hoc if the cert isn't in the keychain.
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGNING_IDENTITY"; then
        codesign --force --sign "$SIGNING_IDENTITY" \
            --entitlements /tmp/relay-entitlements.plist "$APP_DIR/MacOS/Relay"
    else
        echo "WARNING: Developer ID cert not found — falling back to ad-hoc (Screen Recording grant may not persist)"
        codesign --force --sign - --entitlements /tmp/relay-entitlements.plist "$APP_DIR/MacOS/Relay"
    fi
    codesign --verify --verbose=2 "$APP_DIR/MacOS/Relay" || echo "WARNING: signature verification failed"

    # Point LaunchServices at this dev build so "Quit & Reopen" (and `open`) use
    # it rather than a stale registration or the production copy.
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "$LSREGISTER" -f "$APP_BUNDLE" 2>/dev/null || true
fi

echo "Built $APP_BUNDLE (v${VERSION}, build ${BUILD_NUMBER}, ${CONFIG})"
echo "Run with: open \"$APP_BUNDLE\""
