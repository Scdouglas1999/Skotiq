#!/usr/bin/env bash
# Helper for driving the Skotiq Android app on emulator-5554.
export ANDROID_HOME=/home/scdouglas/Android/Sdk
export PATH=$ANDROID_HOME/platform-tools:$PATH
SHOTS=/home/scdouglas/Documents/Skotiq2/reports/mobile-agent-shots

shot() {  # shot <name>
  adb exec-out screencap -p > "$SHOTS/$1.png"
  echo "$SHOTS/$1.png"
}
tap()  { adb shell input tap "$1" "$2"; sleep "${3:-1.5}"; }
typ()  { adb shell input text "$1"; sleep 0.6; }
key()  { adb shell input keyevent "$1"; sleep "${2:-1.2}"; }
back() { adb shell input keyevent 4; sleep 1.2; }
swipe(){ adb shell input swipe "$1" "$2" "$3" "$4" "${5:-300}"; sleep 1.2; }
# back GESTURE (edge swipe), not the button
backgesture() { adb shell input swipe 0 1200 600 1200 200; sleep 1.4; }

"$@"
