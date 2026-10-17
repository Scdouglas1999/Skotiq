#!/usr/bin/env python3
"""Rename Nightshade to Skotiq across the repository.

The pass is mechanical and idempotent, so it can be run again on a branch that
kept moving after the first run (release/v7.1.0 had uncommitted work when the
rebrand started). Run it from the repository root:

    python3 tools/rebrand/rebrand.py          # rewrite contents, then move paths
    python3 tools/rebrand/rebrand.py --check  # list what still says the old name

Files named in legacy_allowlist.txt keep the old name on purpose (the data
migration has to know where the old install kept its data). Binary files are
never rewritten; their paths are still moved.
"""

import argparse
import os
import re
import subprocess
import sys

ROOT = os.getcwd()
HERE = os.path.dirname(os.path.abspath(__file__))
ALLOWLIST = os.path.join(HERE, "legacy_allowlist.txt")
SELF = os.path.relpath(os.path.abspath(__file__), ROOT)

# Skipped entirely: regenerated after the rebrand, or this tool itself.
SKIP_PREFIXES = ("graphify-out/", "tools/rebrand/")

# Platform identifiers first: these were placeholders (com.example.*) or
# inconsistent, so they get a real reverse-DNS id rather than a word swap.
EXACT = [
    ("com.example.nightshade_desktop", "com.skotiq.desktop"),
    ("com.example.nightshadeDesktop", "com.skotiq.desktop"),
    ("com.example.nightshade_mobile", "com.skotiq.mobile"),
    ("com.nightshade.nightshadeMobile", "com.skotiq.mobile"),
    ("com.nightshade.mobile", "com.skotiq.mobile"),
    ("com/example/nightshade_mobile", "com/skotiq/mobile"),
]

WORDS = [
    ("NIGHTSHADE", "SKOTIQ"),
    ("NightShade", "Skotiq"),
    ("nightShade", "skotiq"),
    ("Nightshade", "Skotiq"),
    ("nightshade", "skotiq"),
]

LEFTOVER = re.compile(r"night[\s_.-]?shade", re.IGNORECASE)


def tracked_files():
    out = subprocess.run(
        ["git", "ls-files", "-z"], capture_output=True, check=True
    ).stdout
    return [p for p in out.decode().split("\0") if p]


def allowlisted():
    if not os.path.exists(ALLOWLIST):
        return set()
    with open(ALLOWLIST, encoding="utf-8") as f:
        return {
            line.strip()
            for line in f
            if line.strip() and not line.lstrip().startswith("#")
        }


def skipped(path, allow):
    return path.startswith(SKIP_PREFIXES) or path in allow


def is_binary(data):
    return b"\0" in data[:8192]


def rewrite(text):
    for old, new in EXACT + WORDS:
        text = text.replace(old, new)
    return text


def rewrite_path(path):
    # Path components only take the identifier rewrite; the reverse-DNS
    # directory move for the Android sources is covered by EXACT.
    return rewrite(path)


def rewrite_contents(files, allow):
    changed = 0
    for path in files:
        if skipped(path, allow) or not os.path.isfile(path):
            continue
        with open(path, "rb") as f:
            data = f.read()
        if is_binary(data):
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            text = data.decode("latin-1")
            new = rewrite(text)
            if new != text:
                with open(path, "wb") as f:
                    f.write(new.encode("latin-1"))
                changed += 1
            continue
        new = rewrite(text)
        if new != text:
            with open(path, "wb") as f:
                f.write(new.encode("utf-8"))
            changed += 1
    return changed


def move_paths(files, allow):
    moves = []
    for path in files:
        if path.startswith(SKIP_PREFIXES) or path in allow:
            continue
        target = rewrite_path(path)
        if target != path:
            moves.append((path, target))
    for src, dst in moves:
        os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
        subprocess.run(["git", "mv", "-k", src, dst], check=True)
    # Remove directories the moves emptied.
    for src, _ in moves:
        d = os.path.dirname(src)
        while d and os.path.isdir(d) and not os.listdir(d):
            os.rmdir(d)
            d = os.path.dirname(d)
    return len(moves)


def check(files, allow):
    hits = 0
    for path in files:
        if path.startswith(SKIP_PREFIXES):
            continue
        if LEFTOVER.search(path) and path not in allow:
            print(f"path: {path}")
            hits += 1
        if path in allow or not os.path.isfile(path):
            continue
        with open(path, "rb") as f:
            data = f.read()
        if is_binary(data):
            continue
        for n, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
            if LEFTOVER.search(line):
                print(f"{path}:{n}: {line.strip()[:160]}")
                hits += 1
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    if not os.path.isdir(".git") and not os.path.isfile(".git"):
        sys.exit("run from the repository root")
    allow = allowlisted()
    files = tracked_files()
    if args.check:
        hits = check(files, allow)
        print(f"{hits} leftover mention(s)")
        sys.exit(1 if hits else 0)
    print(f"rewrote {rewrite_contents(files, allow)} file(s)")
    print(f"moved {move_paths(files, allow)} path(s)")


if __name__ == "__main__":
    main()
