#!/usr/bin/env python3
"""Drive the Skotiq mobile app on an Android emulator for audit sweeps.

WHY THIS EXISTS
---------------
The desktop sweep reached 384 of 400 coverage units; the 14 that stayed
untouched were the mobile app, recorded as "needs an Android emulator". The SDK,
the emulator and an `sk_test_api35` AVD were all already on this machine — what
was missing was a harness. This is it.

It is the Android counterpart of `drive_linux.py`, with one real advantage:
`uiautomator dump` returns the view hierarchy WITH BOUNDS. On the desktop the
AT-SPI bridge answers names and states but times out on geometry, so clicking
means screenshot-look-click-xy. Here you can tap a control BY NAME and the
harness resolves the coordinates itself, which does not go stale when a layout
shifts.

USAGE
  drive_android.py boot [--avd sk_test_api35]
  drive_android.py install [--apk path]     # builds a debug APK if none given
  drive_android.py start
  drive_android.py tree [--filter TEXT]     # names, classes, bounds, enabled/checked
  drive_android.py tap "Connect"            # by visible text or content-desc
  drive_android.py tap-xy 540 1200
  drive_android.py back / home
  drive_android.py type "M31"
  drive_android.py shot out.png             # downscaled by default; see --width
  drive_android.py log [--tail N]           # app logcat only
  drive_android.py stop
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SDK = Path(os.environ.get("ANDROID_HOME", str(Path.home() / "Android/Sdk")))
EMULATOR = SDK / "emulator/emulator"
APP_ID = os.environ.get("SK_ANDROID_APP_ID", "com.skotiq.mobile")
AVD = os.environ.get("SK_ANDROID_AVD", "sk_test_api35")
OUT = Path(os.environ.get("SK_ANDROID_RUNTIME", "/tmp/sk-android"))


def _adb(*args: str, timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["adb", *args], capture_output=True, text=True, timeout=timeout
    )


def _booted() -> bool:
    r = _adb("shell", "getprop", "sys.boot_completed", timeout=15)
    return r.stdout.strip() == "1"


def cmd_boot(args: argparse.Namespace) -> int:
    if _booted():
        print("emulator already booted")
        return 0
    if not EMULATOR.exists():
        print(f"error: no emulator at {EMULATOR}; set ANDROID_HOME", file=sys.stderr)
        return 2

    OUT.mkdir(parents=True, exist_ok=True)
    log = open(OUT / "emulator.log", "ab")
    # -no-snapshot-load so a sweep starts from the AVD's clean state rather than
    # whatever a previous run left behind; a stale snapshot is the mobile
    # equivalent of the desktop harness's dirty scratch profile.
    subprocess.Popen(
        [str(EMULATOR), "-avd", args.avd, "-no-window", "-no-audio",
         "-no-snapshot-load", "-gpu", "swiftshader_indirect"],
        stdout=log, stderr=subprocess.STDOUT,
    )
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        time.sleep(5)
        if _booted():
            _adb("shell", "settings", "put", "global", "window_animation_scale", "0")
            _adb("shell", "settings", "put", "global", "transition_animation_scale", "0")
            _adb("shell", "settings", "put", "global", "animator_duration_scale", "0")
            print(f"emulator booted ({args.avd}); animations disabled")
            return 0
    print(f"error: emulator did not boot within {args.timeout}s; "
          f"see {OUT / 'emulator.log'}", file=sys.stderr)
    return 3


def cmd_install(args: argparse.Namespace) -> int:
    apk = Path(args.apk) if args.apk else None
    if apk is None:
        built = REPO / "apps/mobile/build/app/outputs/flutter-apk/app-debug.apk"
        if not built.exists():
            print("building debug APK (this takes a few minutes)...")
            r = subprocess.run(
                ["flutter", "build", "apk", "--debug"],
                cwd=str(REPO / "apps/mobile"), capture_output=True, text=True,
                timeout=args.timeout,
            )
            if r.returncode != 0:
                print(r.stdout[-3000:], file=sys.stderr)
                return r.returncode
        apk = built
    if not apk.exists():
        print(f"error: no APK at {apk}", file=sys.stderr)
        return 2
    r = _adb("install", "-r", "-g", str(apk), timeout=600)
    print(r.stdout.strip() or r.stderr.strip())
    return 0 if "Success" in r.stdout else 1


def cmd_start(args: argparse.Namespace) -> int:
    _adb("shell", "am", "force-stop", APP_ID)
    r = _adb("shell", "monkey", "-p", APP_ID, "-c",
             "android.intent.category.LAUNCHER", "1")
    time.sleep(6)
    print(r.stdout.strip().splitlines()[-1] if r.stdout.strip() else "launched")
    return 0


def _dump_tree() -> ET.Element | None:
    """The view hierarchy, with bounds. Retried: uiautomator loses the race with
    an in-progress frame and returns 'could not get idle state' rather than
    failing, which reads exactly like an empty screen."""
    for _ in range(4):
        r = _adb("shell", "uiautomator", "dump", "/sdcard/ui.xml", timeout=60)
        if "dumped to" in (r.stdout + r.stderr):
            x = _adb("shell", "cat", "/sdcard/ui.xml", timeout=60)
            try:
                return ET.fromstring(x.stdout)
            except ET.ParseError:
                pass
        time.sleep(1.5)
    return None


def _nodes(root: ET.Element):
    for n in root.iter("node"):
        text = (n.get("text") or "").strip()
        desc = (n.get("content-desc") or "").strip()
        label = text or desc
        yield n, label


def cmd_tree(args: argparse.Namespace) -> int:
    root = _dump_tree()
    if root is None:
        print("error: uiautomator returned no hierarchy", file=sys.stderr)
        return 1
    for n, label in _nodes(root):
        if not label:
            continue
        if args.filter and args.filter.lower() not in label.lower():
            continue
        flags = []
        if n.get("checkable") == "true":
            flags.append("ON" if n.get("checked") == "true" else "off")
        if n.get("enabled") == "false":
            flags.append("DISABLED")
        cls = (n.get("class") or "").rsplit(".", 1)[-1]
        print(f"{cls}: {label}{' [' + ','.join(flags) + ']' if flags else ''} "
              f"{n.get('bounds')}")
    return 0


def _centre(bounds: str) -> tuple[int, int] | None:
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds or "")
    if not m:
        return None
    x1, y1, x2, y2 = (int(g) for g in m.groups())
    if x2 <= x1 or y2 <= y1:
        return None
    return (x1 + x2) // 2, (y1 + y2) // 2


def cmd_tap(args: argparse.Namespace) -> int:
    root = _dump_tree()
    if root is None:
        print("error: no hierarchy to resolve against", file=sys.stderr)
        return 1
    want = args.name.strip().lower()
    exact, partial = [], []
    for n, label in _nodes(root):
        if not label:
            continue
        low = label.lower()
        (exact if low == want else partial if want in low else []).append((n, label))
    for n, label in exact + partial:
        pt = _centre(n.get("bounds"))
        if pt is None:
            continue
        if n.get("enabled") == "false":
            print(f"error: {label!r} is DISABLED — not tapping", file=sys.stderr)
            return 3
        _adb("shell", "input", "tap", str(pt[0]), str(pt[1]))
        time.sleep(args.settle)
        print(f"tapped {label!r} at {pt[0]},{pt[1]}")
        return 0
    print(f"error: nothing matching {args.name!r} on screen", file=sys.stderr)
    return 2


def cmd_tap_xy(args: argparse.Namespace) -> int:
    _adb("shell", "input", "tap", str(args.x), str(args.y))
    time.sleep(args.settle)
    print(f"tapped {args.x},{args.y}")
    return 0


def cmd_key(args: argparse.Namespace) -> int:
    _adb("shell", "input", "keyevent", args.keycode)
    time.sleep(0.5)
    return 0


def cmd_type(args: argparse.Namespace) -> int:
    _adb("shell", "input", "text", args.text.replace(" ", "%s"))
    time.sleep(0.4)
    return 0


def cmd_shot(args: argparse.Namespace) -> int:
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    raw = subprocess.run(["adb", "exec-out", "screencap", "-p"],
                         capture_output=True, timeout=120)
    out.write_bytes(raw.stdout)
    # Same reasoning as the desktop harness: screenshots are what exhaust a
    # sweep agent's context, and a phone screenshot is tall and mostly chrome.
    if not args.raw:
        subprocess.run(["convert", str(out), "-resize", f"{args.width}x>",
                        str(out)], capture_output=True)
    print(f"{out} ({out.stat().st_size / 1024:.0f} KB)")
    return 0


def cmd_log(args: argparse.Namespace) -> int:
    r = _adb("logcat", "-d", "-v", "brief", timeout=120)
    lines = [l for l in r.stdout.splitlines()
             if "skotiq" in l.lower() or "flutter" in l.lower()]
    for line in lines[-args.tail:]:
        print(line)
    return 0


def cmd_stop(args: argparse.Namespace) -> int:
    _adb("shell", "am", "force-stop", APP_ID)
    if args.kill_emulator:
        _adb("emu", "kill")
        print("emulator killed")
    else:
        print("app stopped (emulator left running)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("boot"); s.add_argument("--avd", default=AVD)
    s.add_argument("--timeout", type=int, default=300); s.set_defaults(fn=cmd_boot)
    s = sub.add_parser("install"); s.add_argument("--apk", default="")
    s.add_argument("--timeout", type=int, default=1800); s.set_defaults(fn=cmd_install)
    s = sub.add_parser("start"); s.set_defaults(fn=cmd_start)
    s = sub.add_parser("tree"); s.add_argument("--filter", default="")
    s.set_defaults(fn=cmd_tree)
    s = sub.add_parser("tap"); s.add_argument("name")
    s.add_argument("--settle", type=float, default=1.2); s.set_defaults(fn=cmd_tap)
    s = sub.add_parser("tap-xy"); s.add_argument("x", type=int); s.add_argument("y", type=int)
    s.add_argument("--settle", type=float, default=1.2); s.set_defaults(fn=cmd_tap_xy)
    s = sub.add_parser("back"); s.set_defaults(fn=cmd_key, keycode="KEYCODE_BACK")
    s = sub.add_parser("home"); s.set_defaults(fn=cmd_key, keycode="KEYCODE_HOME")
    s = sub.add_parser("type"); s.add_argument("text"); s.set_defaults(fn=cmd_type)
    s = sub.add_parser("shot"); s.add_argument("out")
    s.add_argument("--width", type=int, default=720); s.add_argument("--raw", action="store_true")
    s.set_defaults(fn=cmd_shot)
    s = sub.add_parser("log"); s.add_argument("--tail", type=int, default=80)
    s.set_defaults(fn=cmd_log)
    s = sub.add_parser("stop"); s.add_argument("--kill-emulator", action="store_true")
    s.set_defaults(fn=cmd_stop)

    args = ap.parse_args()
    if not hasattr(args, "keycode"):
        args.keycode = ""
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
