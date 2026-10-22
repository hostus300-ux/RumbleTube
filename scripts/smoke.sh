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
python3 -m pip install --quiet pillow >/dev/null 2>&1 || true
# Prints the share of the screen that is the launch-screen colour (#15191D): ~1.0 means the app never drew.
blank() { python3 - "$1" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB").resize((120, 260))
px = list(im.getdata())
print(round(sum(1 for p in px if abs(p[0]-21) < 6 and abs(p[1]-25) < 6 and abs(p[2]-29) < 6) / len(px), 2))
PY
}
reports() { find ~/Library/Logs/DiagnosticReports -iname '*RumbleTube*' 2>/dev/null | wc -l | tr -d ' '; }
# Warm-up: the very first launch after install is slow on the Intel simulator and often isn't on screen in time.
xcrun simctl launch "$DEV" "$BUNDLE" >/dev/null 2>&1; sleep 30
for screen in home shorts discover my-feed account search inbox settings; do
  xcrun simctl terminate "$DEV" "$BUNDLE" >/dev/null 2>&1 || true
  before=$(reports)
  xcrun simctl launch "$DEV" "$BUNDLE" -launchTab "$screen" -smokeTest YES >/dev/null 2>&1
  sleep 30   # the Intel simulator can take 15–25 s to show the first frame after a relaunch
  xcrun simctl io "$DEV" screenshot "$OUT/$screen.png" >/dev/null 2>&1 || true
  b=$(blank "$OUT/$screen.png" 2>/dev/null || echo 0)
  if python3 -c "import sys; sys.exit(0 if float('$b') > 0.9 else 1)"; then
    echo "STUCK?  $screen (screen still blank after 30 s) - sampling main thread"
    PID=$(pgrep -f 'RumbleTube.app/RumbleTube' | tail -1)
    [ -n "$PID" ] && sample "$PID" 3 -file "$OUT/$screen-sample.txt" >/dev/null 2>&1
    sleep 30
    xcrun simctl io "$DEV" screenshot "$OUT/$screen-60s.png" >/dev/null 2>&1 || true
    echo "        after 60 s blank=$(blank "$OUT/$screen-60s.png" 2>/dev/null)"
  fi
  # A crash always leaves a crash report; "not in launchctl" turned out to be unreliable.
  if [ "$(reports)" -gt "$before" ]; then
    echo "CRASHED $screen"; failed=1
    xcrun simctl spawn "$DEV" log show --last 40s --style compact \
      --predicate 'process == "RumbleTube" AND (messageType == error OR messageType == fault)' > "$OUT/$screen-log.txt" 2>/dev/null || true
  else
    echo "ok      $screen"
  fi
done

# crash reports, if any (simulator crashes land in the host's DiagnosticReports)
find ~/Library/Logs/DiagnosticReports -iname '*RumbleTube*' -exec cp {} "$OUT/" \; 2>/dev/null || true
ls "$OUT"
xcrun simctl shutdown "$DEV" || true
exit $failed
