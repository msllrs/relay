#!/bin/bash
# Regression check: the binary's LC_BUILD_VERSION "sdk" must match the SDK it
# was compiled against. SwiftPM's Swift Build backend (Xcode 27) stamps the
# deployment target (15.0) there instead, and AppKit then applies its
# linked-on-or-before compatibility behaviors — on macOS 27 that left the
# settings popover stuck at the main page's height. Release builds made with
# Xcode 26 were stamped correctly, so the bug only showed in local builds.
#
# Usage: Scripts/check-sdk-stamp.sh <binary>...
set -euo pipefail

expected=$(xcrun --sdk macosx --show-sdk-version)
status=0
for binary in "$@"; do
    stamped=$(otool -l "$binary" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "sdk" { print $2; exit }')
    if [ "$stamped" = "$expected" ]; then
        echo "SDK stamp OK: $binary ($stamped)"
    else
        echo "ERROR: $binary is stamped SDK ${stamped:-none}, but was built against SDK $expected" >&2
        status=1
    fi
done
exit $status
