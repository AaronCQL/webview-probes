#!/bin/bash
# usage: run-ios.sh <log> <timeout-secs> [app args...]
# Boots an iPhone simulator (once), installs build/ios/Probe.app, launches it with
# --console-pty and waits for the app to exit (or the timeout).
set -uo pipefail
cd "$(dirname "$0")/.."
LOG=$1; TO=$2; shift 2
UDID_FILE=build/ios/udid
if [ ! -f "$UDID_FILE" ]; then
  xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
rts=sorted([k for k in d if "iOS-18" in k], reverse=True) or sorted([k for k in d if "iOS" in k], reverse=True)
for rt in rts:
    for dev in d[rt]:
        if dev["name"].startswith("iPhone 16") and dev["name"]=="iPhone 16":
            print(dev["udid"], rt); sys.exit(0)
for rt in rts:
    for dev in d[rt]:
        if dev["name"].startswith("iPhone"):
            print(dev["udid"], rt); sys.exit(0)
' > build/ios/device.txt
  cat build/ios/device.txt
  cut -d' ' -f1 build/ios/device.txt > "$UDID_FILE"
  UDID=$(cat "$UDID_FILE")
  xcrun simctl boot "$UDID" || true
  xcrun simctl bootstatus "$UDID" -b
  xcrun simctl install "$UDID" build/ios/Probe.app
fi
UDID=$(cat "$UDID_FILE")
perl -e 'alarm shift; exec @ARGV' "$TO" \
  xcrun simctl launch --console-pty --terminate-running-process "$UDID" com.example.probe "$@" 2>&1 | tee "$LOG"
echo "exit: ${PIPESTATUS[0]}"
