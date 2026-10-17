"""Click side-nav items and capture Skotiq screens (UI audit)."""
from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

import pyautogui
import win32con
import win32gui

# Import sibling capture helper
sys.path.insert(0, str(Path(__file__).resolve().parent))
from capture_window import capture, find_window  # noqa: E402

# Collapsed sidebar: icon column center ~36px from window left.
# First nav item ~90px from top; ~52px vertical stride (approximate).
NAV_Y_START = 92
NAV_Y_STEP = 52
NAV_X = 36

SCREENS = [
    (0, "dashboard"),
    (1, "equipment"),
    (2, "imaging"),
    (3, "guiding"),
    (4, "sequencer"),
    (5, "planetarium"),
    (7, "analytics"),
]


def main() -> int:
    out_dir = Path(__file__).resolve().parents[2] / ".ui-audit-screenshots"
    out_dir.mkdir(parents=True, exist_ok=True)
    hwnd = find_window("Skotiq")
    left, top, _, _ = win32gui.GetWindowRect(hwnd)
    win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)
    win32gui.SetForegroundWindow(hwnd)
    time.sleep(0.8)

    pyautogui.FAILSAFE = False
    for index, name in SCREENS:
        x = left + NAV_X
        y = top + NAV_Y_START + index * NAV_Y_STEP
        pyautogui.click(x, y)
        time.sleep(1.2)
        capture(hwnd, out_dir / f"nav-{index:02d}-{name}.png")
        print(f"captured {name}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
