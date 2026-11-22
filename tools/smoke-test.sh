#!/usr/bin/env bash
# Installs each debug APK on the emulator, walks through its main screens, saves screenshots,
# and fails the job if any app crashes or stops running. Debug builds show Google TEST ads.
# Each app is started with launch(), which waits for the process, retries once with a warning
# and prints what the system logged if the app did not come up; each app is stopped once checked.
set -u
DIST=${1:-dist}
OUT=${2:-shots}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
FAIL=0

adb shell svc power stayon true
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
adb logcat -b all -c

shot() {
  sleep "${2:-3}"
  adb exec-out screencap -p > "$OUT/$1.png"
  echo "  screenshot: $1"
}

SIZE=$(adb shell wm size | grep -oE '[0-9]+x[0-9]+' | tail -1)
W=${SIZE%x*}
H=${SIZE#*x}

tap() { # tap the first element whose text contains $1, scrolling down to find it if needed
  local point=""
  for attempt in 1 2 3 4 5 6 7; do
    adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
    point=$(adb shell cat /sdcard/ui.xml | python3 "$HERE/tap_point.py" "$1") && break
    point=""
    if [ "$attempt" -ge 2 ]; then
      adb shell input swipe $((W / 2)) $((H * 7 / 10)) $((W / 2)) $((H * 3 / 10)) 300
    fi
    sleep 1
  done
  if [ -z "$point" ]; then
    echo "::warning::Couldn't find \"$1\" on screen"
    return 1
  fi
  adb shell input tap $point
  sleep 1.5
}

why_gone() { # $1 package: print what the system logged about the process ending
  adb logcat -d -b events 2>/dev/null | grep -E "am_(kill|proc_died|anr|crash|low_memory)" | grep -F "$1" | tail -10
  adb logcat -d -b main,system 2>/dev/null \
    | grep -E "ANR in|FATAL EXCEPTION|lowmemorykiller|Killing [0-9]+:|has died|Force stopping|Error: |Exception" \
    | grep -v -F "uiautomator" | tail -40
}

running() { [ -n "$(adb shell pidof "$1" | tr -d '\r')" ]; }

launch() { # $1 package, $2 activity, $3 app name, rest: extra "am start" arguments
  local pkg=$1 act=$2 name=$3 out try i
  shift 3
  for try in 1 2; do
    out=$(adb shell am start -W -n "$pkg/$act" "$@" 2>&1 | tr -d '\r')
    for i in 1 2 3 4 5 6 7 8 9 10; do
      running "$pkg" && break
      sleep 1
    done
    if running "$pkg" && ! printf '%s' "$out" | grep -q -E "^Error|Exception"; then
      [ "$try" -eq 1 ] || echo "::warning::$name only started on the second attempt"
      return 0
    fi
    echo "::warning::$name did not start (attempt $try). \"am start\" said:"
    printf '%s\n' "$out"
    why_gone "$pkg"
    sleep 5
  done
  return 1
}

check() { # $1 package, $2 app name
  if adb logcat -d -b crash 2>/dev/null | grep -q "Process: $1"; then
    echo "::error::$2 crashed"
    adb logcat -d -b crash | grep -A 40 "Process: $1" | head -70
    FAIL=1
  elif ! running "$1"; then
    echo "::error::$2 is not running"
    why_gone "$1"
    FAIL=1
  else
    echo "  OK: $2 is running with no crash"
  fi
}

install() {
  echo "== $2"
  if ! adb install -r -g "$DIST/$1"; then
    echo "::error::Could not install $1"
    FAIL=1
    return 1
  fi
}

# ---- Seeti --------------------------------------------------------------------------------
P=io.github.sachin102492.seeti.debug
A=io.github.sachin102492.seeti.MainActivity
if install seeti-debug.apk Seeti; then
  launch "$P" "$A" Seeti
  shot seeti-1-setup 6
  tap "Start counting" && tap "Continue"
  shot seeti-2-listening 4
  check "$P" Seeti
  # Three manual "+1" taps reach the default target of 3 and must ring the alarm.
  tap "+1 missed one"; tap "+1 missed one"; tap "+1 missed one"
  shot seeti-3-alarm 3
  tap "Stop alarm"
  shot seeti-4-after-stop 3
  check "$P" Seeti
  adb shell am force-stop "$P"
fi

# ---- Bijli Guard --------------------------------------------------------------------------
P=io.github.sachin102492.bijli.debug
A=io.github.sachin102492.bijli.MainActivity
if install bijli-debug.apk "Bijli Guard"; then
  launch "$P" "$A" "Bijli Guard" --ez seed_demo true
  shot bijli-1-this-month 6
  tap "Readings" && shot bijli-2-readings 2
  tap "Tenants" && shot bijli-3-tenants 2
  tap "Rates" && shot bijli-4-rates 2
  tap "Month" && tap "Add today's meter reading" && shot bijli-5-add-reading 2
  adb shell input keyevent KEYCODE_BACK
  check "$P" "Bijli Guard"
  adb shell am force-stop "$P"
fi

# ---- SafeShare ID -------------------------------------------------------------------------
P=io.github.sachin102492.safeshare.debug
A=io.github.sachin102492.safeshare.MainActivity
if install safeshare-debug.apk "SafeShare ID"; then
  launch "$P" "$A" "SafeShare ID"
  shot safeshare-1-home 6
  # Opens the bundled, clearly fake sample card (debug builds only).
  adb shell am start -n "$P/$A" --ez demo_sample true >/dev/null
  shot safeshare-2-detecting 4
  # The first run asks Google Play services for the on-device reader; wait for the result.
  for _ in $(seq 1 40); do
    adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
    if adb shell cat /sdcard/ui.xml | grep -q -E 'Hidden:|Nothing found|reader isn.t ready'; then break; fi
    sleep 3
  done
  if adb shell cat /sdcard/ui.xml | grep -q 'Hidden:'; then
    echo "  OK: SafeShare hid parts of the sample card automatically"
  else
    echo "::warning::SafeShare did not hide anything automatically on the emulator"
  fi
  shot safeshare-3-masked 1
  if tap "Only for"; then
    adb shell input text "Hotel%sRaj%scheck-in"
    adb shell input keyevent KEYCODE_BACK
    shot safeshare-4-purpose 2
  fi
  check "$P" "SafeShare ID"
  adb shell am force-stop "$P"
fi

# ---- Ghar Clock ---------------------------------------------------------------------------
P=io.github.sachin102492.gharclock.debug
A=io.github.sachin102492.gharclock.MainActivity
if install gharclock-debug.apk "Ghar Clock"; then
  launch "$P" "$A" "Ghar Clock"
  shot gharclock-1-welcome 6
  tap "Add 6 items" && shot gharclock-2-list 3
  check "$P" "Ghar Clock"
  adb shell am force-stop "$P"
  launch "$P" "$A" "Ghar Clock" --ez seed_demo true
  shot gharclock-3-with-history 6
  tap "Refilled today" && shot gharclock-4-after-refill 2
  check "$P" "Ghar Clock"
fi

echo
ls -la "$OUT"
if [ "$FAIL" -ne 0 ]; then
  echo "::error::At least one app crashed or failed to start. See the logs above."
  exit 1
fi
echo "All four apps opened and ran without crashing."
