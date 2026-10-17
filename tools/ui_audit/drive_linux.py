#!/usr/bin/env python3
"""Drive the Skotiq desktop app on Linux for audit sweeps.

WHY THIS EXISTS
---------------
Audits that read source find the bugs source review can find. The defects that
have actually cost this project a night's data -- a Pause button that does not
pause, a run that reports "completed" with zero frames, a status that contradicts
itself between two APIs -- only appear when the real binary is driven. This is
the harness that drives it: a scratch-profile app instance on a private X server,
with screenshots, a live accessibility tree, and keyboard/pointer input.

The accessibility tree is what makes a sweep checkable rather than impressionistic:
it reports every control's NAME, ROLE and STATE, so "is this switch on?" and "is
this button dead?" have answers that do not depend on squinting at a screenshot.
It does NOT report geometry -- this build's AT-SPI bridge times out on the
Component interface -- so clicking is `shot`, look, then `click-xy`. Use `click`
only to ask whether a named control is present and enabled.

ENVIRONMENT NOTES (each of these cost a debugging session to learn)
  * GALLIUM_DRIVER=softpipe, not llvmpipe. Under Mesa 26 llvmpipe crashes this
    app's shader setup on a virtual display; softpipe is slow but survives.
  * SKOTIQ_DATABASE_DIR points at a scratch dir so a sweep never mutates the
    developer's real observing data, and so each run starts from a known state.
  * The app takes a single-instance lock. A second launch exits silently and
    looks identical to a crash, so `start` refuses when one is already up.

USAGE
  drive_linux.py start [--display :77] [--profile NAME] [--fresh]
  drive_linux.py shot  out.png
  drive_linux.py tree  [--filter TEXT]
  drive_linux.py click "Settings"        # by accessible name
  drive_linux.py click-xy 400 300
  drive_linux.py key Escape
  drive_linux.py type "M31"
  drive_linux.py resize 420 900          # reflow to a phone-width viewport
  drive_linux.py resize --show           # report the current window geometry
  drive_linux.py log [--tail N]
  drive_linux.py stop

WHY `resize` EXISTS
-------------------
The window came up at a fixed 1600x900 and the harness could not change it, so
every responsive branch below the phone/tablet breakpoints -- the sequencer's
phone builder, the guiding screen's mobile tabs, the fullscreen image viewer
that is gated on `Responsive.isPhone` -- was unreachable and the coverage
ledger recorded them all as "needs an emulator". Most of them do not: they are
window-width branches on the very same desktop binary. `resize` drives
`xdotool windowsize`, which works without a window manager because Flutter's
GTK window accepts the configure directly.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BUNDLE = REPO / "apps/desktop/build/linux/x64/release/bundle/skotiq"
DEBUG_BUNDLE = REPO / "apps/desktop/build/linux/x64/debug/bundle/skotiq"
RUNTIME = Path(os.environ.get("SK_AUDIT_RUNTIME", "/tmp/sk-audit"))
DISPLAY = os.environ.get("SK_AUDIT_DISPLAY", ":77")
GEOMETRY = os.environ.get("SK_AUDIT_GEOMETRY", "1920x1200x24")


def _paths(profile: str) -> dict[str, Path]:
    base = RUNTIME / profile
    return {
        "base": base,
        "data": base / "data",
        "log": base / "app.log",
        "xvfb_pid": base / "xvfb.pid",
        "app_pid": base / "app.pid",
    }


def _env(profile: str) -> dict[str, str]:
    p = _paths(profile)
    env = dict(os.environ)
    env.update(
        {
            "DISPLAY": DISPLAY,
            "GDK_BACKEND": "x11",
            "LIBGL_ALWAYS_SOFTWARE": "1",
            "GALLIUM_DRIVER": "softpipe",
            "SKOTIQ_DATABASE_DIR": str(p["data"]),
            "SKOTIQ_DATA_DIR": str(p["data"]),
            # Flutter's Linux embedder only builds an accessibility tree when a
            # client asks for one; without this the tree is empty and every
            # click has to fall back to pixel coordinates.
            "GTK_MODULES": "gail:atk-bridge",
            "NO_AT_BRIDGE": "0",
        }
    )
    return env


def _running(pidfile: Path) -> int | None:
    if not pidfile.exists():
        return None
    try:
        pid = int(pidfile.read_text().strip())
        os.kill(pid, 0)
        return pid
    except (ValueError, ProcessLookupError, PermissionError):
        return None


def cmd_start(args: argparse.Namespace) -> int:
    p = _paths(args.profile)
    if _running(p["app_pid"]):
        print(f"error: app already running for profile {args.profile}; "
              f"stop it first (drive_linux.py stop --profile {args.profile})",
              file=sys.stderr)
        return 1

    binary = BUNDLE if BUNDLE.exists() else DEBUG_BUNDLE
    if not binary.exists():
        print(f"error: no app bundle at {BUNDLE} or {DEBUG_BUNDLE}; "
              "build with: cd apps/desktop && flutter build linux --release",
              file=sys.stderr)
        return 2

    if args.fresh and p["base"].exists():
        shutil.rmtree(p["base"])
    p["data"].mkdir(parents=True, exist_ok=True)

    if not _running(p["xvfb_pid"]):
        # -noreset keeps the display alive between app restarts, so a sweep can
        # relaunch the app without every window manager assumption resetting.
        xvfb = subprocess.Popen(
            ["Xvfb", DISPLAY, "-screen", "0", GEOMETRY, "-noreset"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        p["xvfb_pid"].write_text(str(xvfb.pid))
        time.sleep(1.5)

    # Xvfb exits immediately if the display is already active, and this script
    # would then silently attach to whoever owns it. That has happened: a leftover
    # instance from an earlier session still held :91, so screenshots captured a
    # DIFFERENT app's window -- with plausible-looking observing data in it. A
    # sweep cannot tell that apart from its own app, so it must be refused here.
    squatters = _existing_windows(args.profile)
    if squatters and not args.allow_shared_display:
        print(
            f"error: {DISPLAY} already has {len(squatters)} window(s) before we "
            f"launched anything, so screenshots would capture another process's "
            f"app. Pick a free SK_AUDIT_DISPLAY, or pass --allow-shared-display "
            f"if you know the display is yours.",
            file=sys.stderr,
        )
        return 5

    log = open(p["log"], "ab")
    app = subprocess.Popen(
        [str(binary)],
        env=_env(args.profile),
        cwd=str(binary.parent),
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    p["app_pid"].write_text(str(app.pid))

    deadline = time.time() + args.timeout
    while time.time() < deadline:
        time.sleep(1.0)
        if app.poll() is not None:
            print(f"error: app exited with code {app.returncode}; "
                  f"see {p['log']}", file=sys.stderr)
            return 3
        if _window_id(args.profile):
            print(f"app up: pid={app.pid} display={DISPLAY} log={p['log']}")
            return 0
    print(f"error: no window appeared within {args.timeout}s; see {p['log']}",
          file=sys.stderr)
    return 4


def _existing_windows(profile: str) -> list[str]:
    r = subprocess.run(
        ["xdotool", "search", "--onlyvisible", "--name", "."],
        env=_env(profile), capture_output=True, text=True,
    )
    return [i for i in r.stdout.split() if i]


def _window_id(profile: str) -> str | None:
    ids = _existing_windows(profile)
    return ids[-1] if ids else None


def cmd_shot(args: argparse.Namespace) -> int:
    """Capture the app, cropped to the window and downscaled by default.

    Screenshot size is the single biggest consumer of an audit agent's context.
    A raw 1920x1200 root capture costs on the order of 2000 tokens once encoded,
    and agents in the first sweep read 116-140 of them each -- roughly a quarter
    of a million tokens in images alone, before any tool output. The three
    largest transcripts are exactly the three agents that died mid-run.

    Two thirds of that was avoidable waste:
      * the app window is 1600x900 inside a 1920x1200 root, so a root capture is
        ~40% black margin;
      * the remaining pixels are far more resolution than reading UI text needs.

    So `shot` now crops to the app window and downscales to `--width` (1280 by
    default, enough to read every label in this UI). Use `--region` for a single
    panel, and `--raw` when pixel-exact full-resolution evidence is the point.
    """
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    origin = (0, 0)
    target = "root"
    if not args.raw and not args.region:
        win = _app_window(args.profile)
        if win:
            target, origin = win

    cmd = ["import", "-window", target]
    if args.region:
        cmd += ["-crop", args.region]
        m = re.match(r"\d+x\d+\+(\d+)\+(\d+)$", args.region)
        if m:
            origin = (int(m.group(1)), int(m.group(2)))
    cmd += [str(out)]
    r = subprocess.run(cmd, env=_env(args.profile), capture_output=True,
                       text=True)
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
        return r.returncode

    before = _dimensions(out)
    if not args.raw:
        subprocess.run(
            ["convert", str(out), "-resize", f"{args.width}x>", str(out)],
            env=_env(args.profile), capture_output=True, text=True,
        )
    after = _dimensions(out)

    # Cropping and downscaling move the image out of the root coordinate frame
    # that `click-xy` speaks, so a caller measuring a control in this PNG would
    # click somewhere else entirely -- the exact "silently clicks the wrong
    # control" failure this harness exists to avoid. Record the mapping next to
    # the image and provide `click-img` so nobody has to do the arithmetic.
    scale = (before[0] / after[0]) if after[0] else 1.0
    _mapping_path(out).write_text(
        json.dumps({"origin_x": origin[0], "origin_y": origin[1],
                    "scale": scale})
    )

    kb = out.stat().st_size / 1024
    print(f"{out} ({kb:.0f} KB, {after[0]}x{after[1]})")
    if origin != (0, 0) or scale != 1.0:
        print(f"  image coords -> use: click-img X Y   "
              f"(offset +{origin[0]}+{origin[1]}, scale {scale:.3f})")
    return 0


def _dimensions(path: Path) -> tuple[int, int]:
    r = subprocess.run(["identify", "-format", "%w %h", str(path)],
                       capture_output=True, text=True)
    try:
        w, h = r.stdout.split()[:2]
        return int(w), int(h)
    except (ValueError, IndexError):
        return (0, 0)


def _mapping_path(shot: Path) -> Path:
    return shot.with_suffix(shot.suffix + ".coords.json")


def _app_window(profile: str) -> tuple[str, tuple[int, int]] | None:
    """The app's main window id and its root offset.

    Picks the LARGEST window rather than the most recent: a tooltip or a
    secondary surface would otherwise win and the capture would be cropped to
    it, which looks like the app rendering almost nothing.
    """
    best = None
    for wid in _existing_windows(profile):
        r = subprocess.run(["xdotool", "getwindowgeometry", "--shell", wid],
                           env=_env(profile), capture_output=True, text=True)
        geom = dict(
            line.split("=", 1) for line in r.stdout.strip().splitlines()
            if "=" in line
        )
        try:
            w, h = int(geom["WIDTH"]), int(geom["HEIGHT"])
            x, y = int(geom["X"]), int(geom["Y"])
        except (KeyError, ValueError):
            continue
        if best is None or w * h > best[1]:
            best = (wid, w * h, (x, y))
    return (best[0], best[2]) if best else None


def cmd_click_img(args: argparse.Namespace) -> int:
    """Click a point measured in a screenshot, in that screenshot's own frame."""
    mapping = _mapping_path(Path(args.shot))
    if not mapping.exists():
        print(f"error: no coordinate mapping beside {args.shot}; it was not "
              f"produced by `shot` (or predates the mapping). Use click-xy with "
              f"root coordinates.", file=sys.stderr)
        return 1
    m = json.loads(mapping.read_text())
    x = int(args.x * m["scale"] + m["origin_x"])
    y = int(args.y * m["scale"] + m["origin_y"])
    return _click_xy(args.profile, x, y)


def _atspi_root(profile: str):
    """The accessibility root of OUR app instance, matched by process id.

    Matching on the application NAME is not good enough and is actively
    dangerous: the AT-SPI registry is per login session, not per X display, so a
    developer's own Skotiq running on their real desktop shows up in the same
    desktop enumeration as the sandboxed instance. Selecting by name picked up
    the developer's app -- meaning the tree being audited was the wrong process's
    tree, and a `click` would have driven their live session. Matching the pid we
    launched makes that mistake impossible.
    """
    p = _paths(profile)
    want = _running(p["app_pid"])
    if want is None:
        return None

    os.environ["DISPLAY"] = DISPLAY
    import gi

    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi

    Atspi.init()
    # The registry re-registers applications as they settle, and an enumeration
    # that lands mid-churn comes back without ours -- which reads exactly like
    # "the app has no accessibility tree" and sends a sweep down the pixel-guess
    # fallback for no reason. Retry before believing it.
    for attempt in range(5):
        desktop = Atspi.get_desktop(0)
        for i in range(desktop.get_child_count()):
            try:
                app = desktop.get_child_at_index(i)
                if app is not None and Atspi.Accessible.get_process_id(app) == want:
                    return app
            except Exception:
                continue
        time.sleep(0.6 * (attempt + 1))
    return None


def _walk(node, depth=0, out=None, limit=4000):
    if out is None:
        out = []
    if len(out) >= limit:
        return out
    try:
        name = node.get_name() or ""
        role = node.get_role_name() or ""
    except Exception:
        return out
    out.append((depth, role, name, node))
    for i in range(node.get_child_count()):
        try:
            child = node.get_child_at_index(i)
        except Exception:
            continue
        if child is not None:
            _walk(child, depth + 1, out, limit)
    return out


def _states(node) -> str:
    """The interaction states an audit actually needs to see.

    A sweep of "every switch" is worthless without the switch's value, and a
    control that renders but is disabled is a different finding from one that is
    missing. Reported inline so a tree dump is self-sufficient evidence.
    """
    try:
        raw = {s.value_nick for s in node.get_state_set().get_states()}
    except Exception:
        return ""
    flags = []
    if "checked" in raw:
        flags.append("ON")
    elif "checkable" in raw:
        flags.append("off")
    # Interactivity is decided by ROLE, not by `focusable`: Flutter drops
    # `focusable` from a disabled button entirely, so a focusable-based test
    # can never print DISABLED on the one node class an audit most needs it
    # for. Static roles (label, panel, image) never carry enabled/sensitive
    # and stay exempt so the dump is not flooded with false alarms.
    try:
        role = node.get_role_name()
    except Exception:
        role = ""
    interactive = bool(raw & {"focusable", "selectable", "checkable"}) or role in {
        "push button", "button", "toggle button", "check box", "radio button",
        "combo box", "menu item", "check menu item", "radio menu item",
        "slider", "spin button", "entry", "text", "link", "page tab",
        "list item",
    }
    # Flutter's Linux AT-SPI bridge keeps `sensitive` on a disabled button
    # while dropping `enabled`/`focusable`, so requiring both absent meant no
    # disabled button ever printed [DISABLED]. `enabled` alone is the truth.
    if interactive and "enabled" not in raw:
        flags.append("DISABLED")
    if "showing" not in raw:
        flags.append("offscreen")
    return f" [{','.join(flags)}]" if flags else ""


def _norm(s: str) -> str:
    """Collapse a semantics label to something a caller can actually type.

    Flutter emits a button's label and its child Text as one accessible name
    separated by a newline ("Back\\nBack"), so an exact-match lookup on the
    visible word fails on almost every button in the app.
    """
    return " ".join(dict.fromkeys(s.split())).strip().lower()


def cmd_tree(args: argparse.Namespace) -> int:
    app = _atspi_root(args.profile)
    if app is None:
        print("error: no Skotiq accessibility root found for our pid. The "
              "app exposes a tree only when semantics are enabled; fall back to "
              "click-xy.", file=sys.stderr)
        return 1
    for depth, role, name, node in _walk(app):
        if args.filter and args.filter.lower() not in name.lower():
            continue
        if not name and not args.all:
            continue
        print(f"{'  ' * depth}{role}: {name}{_states(node)}")
    return 0


def cmd_click(args: argparse.Namespace) -> int:
    app = _atspi_root(args.profile)
    if app is None:
        print("error: accessibility tree unavailable; use click-xy",
              file=sys.stderr)
        return 1
    want = _norm(args.name)
    exact, partial = [], []
    for _, role, name, node in _walk(app):
        n = _norm(name)
        if not n:
            continue
        if n == want:
            exact.append((role, name, node))
        elif want in n:
            partial.append((role, name, node))

    for role, name, node in exact + partial:
        try:
            ext = node.get_component_iface().get_extents(Atspi_COORD_SCREEN)
        except Exception:
            continue
        # A zero-area or offscreen node is a semantics ghost, not the control the
        # caller means; clicking its centre would land on whatever is underneath.
        if ext.width <= 0 or ext.height <= 0:
            continue
        x, y = ext.x + ext.width // 2, ext.y + ext.height // 2
        print(f"-> {role}: {name.splitlines()[0]}")
        return _click_xy(args.profile, x, y)

    if exact or partial:
        # The control is on screen; this build's AT-SPI bridge answers name/role/
        # state queries but times out on the Component interface, so there is no
        # geometry to click. Say so precisely -- "not found" would send the
        # caller hunting for a control that is right there.
        found = (exact + partial)[0]
        print(
            f"error: found {found[0]}: {found[1].splitlines()[0]!r} but this "
            f"build exposes no AT-SPI geometry. Take a shot and use click-xy.",
            file=sys.stderr,
        )
        return 3
    print(f"error: no control matching {args.name!r} in the live tree",
          file=sys.stderr)
    return 2


Atspi_COORD_SCREEN = 0


def _click_xy(profile: str, x: int, y: int) -> int:
    subprocess.run(["xdotool", "mousemove", str(x), str(y), "click", "1"],
                   env=_env(profile), check=True)
    time.sleep(0.4)
    print(f"clicked {x},{y}")
    return 0


def cmd_click_xy(args: argparse.Namespace) -> int:
    return _click_xy(args.profile, args.x, args.y)


def cmd_wheel(args: argparse.Namespace) -> int:
    # Flutter scrolls only the scrollable under the pointer, so the move and
    # the wheel clicks must be one xdotool invocation.
    if args.notches == 0:
        print("scrolled nothing (0 notches)")
        return 0
    button = "4" if args.notches > 0 else "5"
    subprocess.run(["xdotool", "mousemove", str(args.x), str(args.y),
                    "click", "--repeat", str(abs(args.notches)),
                    "--delay", "60", button],
                   env=_env(args.profile), check=True)
    time.sleep(0.5)
    print(f"scrolled {'up' if args.notches > 0 else 'down'} "
          f"{abs(args.notches)} at {args.x},{args.y}")
    return 0


def _geometry(profile: str, wid: str) -> dict[str, int]:
    r = subprocess.run(["xdotool", "getwindowgeometry", "--shell", wid],
                       env=_env(profile), capture_output=True, text=True)
    return {
        k: int(v) for k, v in
        (line.split("=", 1) for line in r.stdout.strip().splitlines()
         if "=" in line)
        if v.lstrip("-").isdigit()
    }


def cmd_resize(args: argparse.Namespace) -> int:
    """Resize the app window so responsive breakpoints actually flip.

    Reports the size the window ACTUALLY took, not the size that was asked
    for. Those differ in two ways that would otherwise be invisible: the X
    server clamps to the Xvfb screen (1920x1200 by default), and GTK enforces
    the widget tree's own minimum. A sweep that assumed its request was
    honoured would record "the phone layout did not appear at 420px" when the
    window never actually got to 420px.
    """
    win = _app_window(args.profile)
    if win is None:
        print("error: no app window; is the app running?", file=sys.stderr)
        return 1
    wid = win[0]

    if args.show or args.width is None:
        g = _geometry(args.profile, wid)
        print(f"{g.get('WIDTH')}x{g.get('HEIGHT')}+{g.get('X')}+{g.get('Y')}")
        return 0

    height = args.height if args.height is not None else \
        _geometry(args.profile, wid).get("HEIGHT", 900)
    subprocess.run(["xdotool", "windowsize", "--sync", wid,
                    str(args.width), str(height)],
                   env=_env(args.profile), check=True)
    # Without a window manager nothing repositions the window, so a shrink
    # leaves it wherever it was and a grow can push it off the screen edge --
    # where `import -window` captures a truncated image. Pin it to the origin.
    subprocess.run(["xdotool", "windowmove", "--sync", wid, "0", "0"],
                   env=_env(args.profile), check=True)
    # Flutter relayouts on the next frame; softpipe needs a beat to paint it.
    time.sleep(args.settle)

    g = _geometry(args.profile, wid)
    got_w, got_h = g.get("WIDTH"), g.get("HEIGHT")
    print(f"window is now {got_w}x{got_h}")
    if got_w != args.width or got_h != height:
        print(f"  note: requested {args.width}x{height}; the server or GTK "
              f"clamped it. Breakpoint decisions must use the actual size.")
    return 0


def cmd_key(args: argparse.Namespace) -> int:
    subprocess.run(["xdotool", "key", "--clearmodifiers", args.keys],
                   env=_env(args.profile), check=True)
    time.sleep(0.3)
    return 0


def cmd_type(args: argparse.Namespace) -> int:
    # `--` terminates xdotool's own option parsing. Without it, typing a value
    # that starts with a dash ("-74.0" into a Longitude field) is swallowed as
    # a flag: xdotool errors, nothing is typed, and the sweep records an empty
    # field as an app defect.
    subprocess.run(["xdotool", "type", "--clearmodifiers", "--delay", "30",
                    "--", args.text],
                   env=_env(args.profile), check=True)
    time.sleep(0.3)
    return 0


def cmd_log(args: argparse.Namespace) -> int:
    p = _paths(args.profile)
    if not p["log"].exists():
        print("no log yet", file=sys.stderr)
        return 1
    lines = p["log"].read_text(errors="replace").splitlines()
    for line in lines[-args.tail:]:
        print(line)
    return 0


def cmd_stop(args: argparse.Namespace) -> int:
    p = _paths(args.profile)
    for key in ("app_pid", "xvfb_pid"):
        pid = _running(p[key])
        if pid:
            os.kill(pid, signal.SIGTERM)
            print(f"stopped {key} {pid}")
        p[key].unlink(missing_ok=True)
    return 0


def main() -> int:
    # --profile is accepted on both sides of the subcommand. argparse would
    # otherwise reject `start --profile x`, which is the order everyone types.
    # SUPPRESS is load-bearing: with a real default here, the subparser (which
    # shares this parent) re-applies "main" over a value the top-level parser
    # already stored, silently discarding a leading `--profile x`.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--profile", default=argparse.SUPPRESS)

    ap = argparse.ArgumentParser(description=__doc__, parents=[common])
    sub = ap.add_subparsers(dest="cmd", required=True)

    def add(name: str):
        return sub.add_parser(name, parents=[common])

    s = add("start")
    s.add_argument("--fresh", action="store_true")
    s.add_argument("--timeout", type=int, default=90)
    s.add_argument("--allow-shared-display", action="store_true")
    s.set_defaults(fn=cmd_start)

    s = add("shot")
    s.add_argument("out")
    s.add_argument("--width", type=int, default=1280,
                   help="downscale to this width (default 1280)")
    s.add_argument("--region", default="",
                   help="WxH+X+Y to capture one panel instead of the window")
    s.add_argument("--raw", action="store_true",
                   help="full-resolution root capture, no crop or downscale")
    s.set_defaults(fn=cmd_shot)

    s = add("tree")
    s.add_argument("--filter", default="")
    s.add_argument("--all", action="store_true")
    s.set_defaults(fn=cmd_tree)

    s = add("click")
    s.add_argument("name")
    s.set_defaults(fn=cmd_click)

    s = add("click-xy")
    s.add_argument("x", type=int)
    s.add_argument("y", type=int)
    s.set_defaults(fn=cmd_click_xy)

    s = add("wheel")
    s.add_argument("x", type=int)
    s.add_argument("y", type=int)
    s.add_argument("notches", type=int,
                   help="positive scrolls up, negative scrolls down")
    s.set_defaults(fn=cmd_wheel)

    s = add("click-img")
    s.add_argument("shot", help="the screenshot the coordinates were read from")
    s.add_argument("x", type=int)
    s.add_argument("y", type=int)
    s.set_defaults(fn=cmd_click_img)

    s = add("resize")
    s.add_argument("width", type=int, nargs="?",
                   help="target window width in pixels (omit to just report)")
    s.add_argument("height", type=int, nargs="?",
                   help="target window height (default: keep the current one)")
    s.add_argument("--show", action="store_true",
                   help="print the current geometry and change nothing")
    s.add_argument("--settle", type=float, default=1.5,
                   help="seconds to wait for the relayout to paint")
    s.set_defaults(fn=cmd_resize)

    s = add("key")
    s.add_argument("keys")
    s.set_defaults(fn=cmd_key)

    s = add("type")
    s.add_argument("text")
    s.set_defaults(fn=cmd_type)

    s = add("log")
    s.add_argument("--tail", type=int, default=80)
    s.set_defaults(fn=cmd_log)

    s = add("stop")
    s.set_defaults(fn=cmd_stop)

    args = ap.parse_args()
    if not hasattr(args, "profile"):
        args.profile = "main"
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
