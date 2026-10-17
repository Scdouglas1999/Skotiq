"""Capture a Windows app window by process name (for UI audit)."""
from __future__ import annotations

import sys
from pathlib import Path

import ctypes
from ctypes import wintypes

import win32con
import win32gui
from PIL import ImageGrab


def find_window(title_substring: str, process_name: str | None = None) -> int:
    matches: list[tuple[int, str]] = []

    def enum_handler(hwnd, _):
        if not win32gui.IsWindowVisible(hwnd):
            return
        title = win32gui.GetWindowText(hwnd)
        if not title or title_substring.lower() not in title.lower():
            return
        if process_name:
            import win32process

            _, pid = win32process.GetWindowThreadProcessId(hwnd)
            try:
                handle = win32process.OpenProcess(
                    win32con.PROCESS_QUERY_LIMITED_INFORMATION, False, pid
                )
                try:
                    import win32api

                    exe = win32api.GetModuleFileNameEx(handle, 0)
                finally:
                    win32process.CloseHandle(handle)
            except Exception:
                return
            if process_name.lower() not in exe.lower():
                return
        matches.append((hwnd, title))

    win32gui.EnumWindows(enum_handler, None)
    if not matches:
        raise RuntimeError(
            f"No window matching title {title_substring!r}"
            + (f" and process {process_name!r}" if process_name else "")
        )
    # Prefer largest area (main window over tool windows).
    best = max(
        matches,
        key=lambda item: _window_area(item[0]),
    )
    return best[0]


def _window_area(hwnd: int) -> int:
    left, top, right, bottom = win32gui.GetWindowRect(hwnd)
    return max(0, right - left) * max(0, bottom - top)


def capture(hwnd: int, path: Path) -> None:
    win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)
    win32gui.SetForegroundWindow(hwnd)
    import time

    time.sleep(0.6)
    left, top, right, bottom = win32gui.GetWindowRect(hwnd)
    if right <= left or bottom <= top:
        raise RuntimeError("Invalid window dimensions")
    image = ImageGrab.grab(bbox=(left, top, right, bottom), all_screens=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)


def main() -> int:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".ui-audit-screenshots/capture.png")
    hwnd = find_window("Skotiq")
    capture(hwnd, out)
    print(f"saved {out} ({out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
