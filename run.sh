#!/bin/bash
set -e

# Kill existing instance
pkill -f "Relay.app/Contents/MacOS/Relay" 2>/dev/null || true
sleep 0.5

# Build
swift build

# Copy into app bundle
cp .build/debug/Relay Relay.app/Contents/MacOS/Relay

# Launch
open Relay.app
echo "Relay launched. Look for the icon in your menu bar."
