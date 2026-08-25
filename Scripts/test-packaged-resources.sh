#!/bin/bash
# Regression test for GitHub issue #3: Relay crashed instantly on user machines
# because SwiftPM's generated Bundle.module accessor only checks
# <app root>/Relay_Relay.bundle (wrong: build-app.sh packages it in
# Contents/Resources) and the absolute .build path of the machine that
# compiled it (absent on user machines) — then fatalErrors.
#
# Simulates a user machine by hiding the local .build resource bundle, then
# launches the packaged binary and asserts it survives startup.
#
# Usage: Scripts/test-packaged-resources.sh [--skip-build]
set -uo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" != "--skip-build" ]]; then
    ./build-app.sh || { echo "FAIL: build-app.sh failed"; exit 1; }
fi

APP=".build/Relay Dev.app"
[ -d "$APP" ] || { echo "FAIL: $APP not found"; exit 1; }

# Copy the app out of the repo, like a user install.
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"

# Hide every dev-machine fallback copy of the bundle (debug AND release — the
# accessor bakes in whichever configuration built the binary) so Bundle.module
# can only succeed via the packaged app itself.
HIDDEN=()
while IFS= read -r dev_bundle; do
    mv "$dev_bundle" "${dev_bundle}.hidden-for-test"
    HIDDEN+=("$dev_bundle")
done < <(find .build -maxdepth 3 -name "Relay_Relay.bundle" -not -path "*.app*")

restore() {
    # ${arr[@]+...} guard: macOS bash 3.2 treats an empty array as unset under -u
    for b in ${HIDDEN[@]+"${HIDDEN[@]}"}; do
        [ -d "${b}.hidden-for-test" ] && mv "${b}.hidden-for-test" "$b"
    done
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
    rm -rf "$STAGE"
}
trap restore EXIT

LOG="$STAGE/launch.log"
"$STAGE/Relay Dev.app/Contents/MacOS/Relay" > "$LOG" 2>&1 &
PID=$!

sleep 3

if kill -0 "$PID" 2>/dev/null; then
    # Surviving isn't enough — a wrong-but-existing bundle would leave sounds
    # silently missing (SoundFeedback logs and returns nil).
    if grep -q "SoundFeedback: missing" "$LOG"; then
        echo "FAIL: app survived but sounds failed to load from the packaged bundle"
        grep "SoundFeedback: missing" "$LOG"
        exit 1
    fi
    echo "PASS: app survived startup with only packaged resources"
    exit 0
else
    wait "$PID"
    STATUS=$?
    echo "FAIL: app died during startup (exit $STATUS)"
    echo "--- launch log ---"
    cat "$LOG"
    exit 1
fi
