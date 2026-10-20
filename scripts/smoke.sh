#!/usr/bin/env bash
# Usage: smoke.sh <path to RumbleTube.app> <output dir>
# Boots an iPhone simulator, opens every screen via the -launchTab argument, saves a screenshot of each
# and exits non-zero if the app is not running after it should have settled (i.e. it crashed).
set -uo pipefail
APP="$1"; OUT="$2"; BUNDLE=com.hostus300.rumbletube
mkdir -p "$OUT"

TYPE=$(xcrun simctl list devicetypes | grep -oE 'com\.apple\.CoreSimulator\.SimDeviceType\.iPhone-[0-9]+-Pro\b' | sort -V | tail -1)
RUNTIME=$(xcrun simctl list runtimes | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+' | sort -V | tail -1)
echo "Device: $TYPE  Runtime: $RUNTIME"
DEV=$(xcrun simctl create smoke "$TYPE" "$RUNTIME")
xcrun simctl boot "$DEV"
xcrun simctl bootstatus "$DEV" -b >/dev/null
xcrun simctl ui "$DEV" appearance dark || true
xcrun simctl install "$DEV" "$APP"

failed=0
for screen in home shorts discover my-feed account search inbox settings; do
  xcrun simctl terminate "$DEV" "$BUNDLE" >/dev/null 2>&1 || true
  PID=$(xcrun simctl launch "$DEV" "$BUNDLE" -launchTab "$screen" -smokeTest YES 2>/dev/null | awk '{print $NF}')
  sleep 14
  xcrun simctl io "$DEV" screenshot "$OUT/$screen.png" >/dev/null 2>&1 || true
  if [ -n "$PID" ] && xcrun simctl spawn "$DEV" ps -p "$PID" >/dev/null 2>&1 || xcrun simctl spawn "$DEV" launchctl list | grep -q "$BUNDLE"; then
    echo "ok      $screen"
  else
    echo "CRASHED $screen (pid $PID)"; failed=1
    xcrun simctl spawn "$DEV" log show --last 40s --style compact \
      --predicate 'process == "RumbleTube" AND (messageType == error OR messageType == fault)' > "$OUT/$screen-log.txt" 2>/dev/null || true
  fi
done

# crash reports, if any (simulator crashes land in the host's DiagnosticReports)
find ~/Library/Logs/DiagnosticReports -iname '*RumbleTube*' -exec cp {} "$OUT/" \; 2>/dev/null || true
ls "$OUT"
xcrun simctl shutdown "$DEV" || true
exit $failed
