#!/usr/bin/env python3
"""Read and tap an Android screen through uiautomator, for the Android rehearsal.

  adb_ui.py <serial> dump            texts and descriptions on screen, with bounds
  adb_ui.py <serial> tap <text>      tap the first node whose text or
                                     content-desc contains <text>
  adb_ui.py <serial> wait <text> [s] wait until <text> is on screen

Flutter exposes its semantics to uiautomator, so labels in the app show up
here as content-desc. Each tap is a stand-in for a human tap; the rehearsal
report lists which ones a real user makes.
"""

import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ADB = "/home/scdouglas/Android/Sdk/platform-tools/adb"


def nodes(serial):
    raw = subprocess.run([ADB, "-s", serial, "exec-out", "uiautomator", "dump",
                          "/dev/tty"], capture_output=True, text=True).stdout
    raw = raw[raw.find("<?xml"):raw.rfind(">") + 1]
    if not raw:
        return []
    out = []
    for n in ET.fromstring(raw).iter("node"):
        label = (n.get("text") or "") + " | " + (n.get("content-desc") or "")
        m = re.findall(r"\d+", n.get("bounds") or "")
        if label.strip(" |") and len(m) == 4:
            x1, y1, x2, y2 = map(int, m)
            out.append((label.strip(" |"), (x1 + x2) // 2, (y1 + y2) // 2))
    return out


def main():
    serial, cmd = sys.argv[1], sys.argv[2]
    if cmd == "dump":
        for label, x, y in nodes(serial):
            print(f"{x:5d},{y:5d}  {label[:160]!r}")
    elif cmd == "tap":
        want = sys.argv[3]
        for label, x, y in nodes(serial):
            if want in label:
                subprocess.run([ADB, "-s", serial, "shell", "input", "tap",
                                str(x), str(y)])
                print(f"tapped {label[:80]!r} at {x},{y}")
                return 0
        print(f"not on screen: {want!r}")
        return 1
    elif cmd == "wait":
        want = sys.argv[3]
        deadline = time.time() + float(sys.argv[4] if len(sys.argv) > 4 else 60)
        while time.time() < deadline:
            if any(want in label for label, _, _ in nodes(serial)):
                print(f"on screen: {want!r}")
                return 0
            time.sleep(2)
        print(f"timed out waiting for {want!r}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
