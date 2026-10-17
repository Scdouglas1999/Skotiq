#!/usr/bin/env python3
"""Gate a wave branch: count forbidden UI literals in the ADDED lines of a diff.

    python3 docs/design/overhaul/tools/diff_audit.py <base-sha> [<head>] [--repo PATH]

Prints, per forbidden pattern, the number of added lines that match and the first few
file:line locations. Exit 1 if any pattern matches in files under packages/skotiq_ui/lib or
packages/skotiq_app/lib (tests, tools and docs are reported but do not fail).

Patterns are the "No new raw literals" rule from 07-implementation-waves.md rule 4, plus the
deprecated names each wave must not introduce.
"""
from __future__ import annotations

import re
import subprocess
import sys

PATTERNS = {
    "BorderRadius.circular(<number>)": re.compile(r"BorderRadius\.circular\(\s*\d"),
    "Radius.circular(<number>)": re.compile(r"(?<!Border)Radius\.circular\(\s*\d"),
    "TextStyle(fontSize: <number>)": re.compile(r"TextStyle\([^)]*fontSize:\s*\d"),
    ".copyWith(fontSize: <number>)": re.compile(r"copyWith\([^)]*fontSize:\s*\d"),
    "Color(0x...)": re.compile(r"\bColor\(0x[0-9A-Fa-f]{8}\)"),
    "Icons.* (Material)": re.compile(r"\bIcons\.[a-zA-Z_]+"),
    "EdgeInsets.all(odd)": re.compile(r"EdgeInsets\.all\(\s*(1|3|5|7|9|11|13|15|17|19|21|23)(\.0)?\s*\)"),
    "Duration(milliseconds: <n>) inline": re.compile(r"Duration\(milliseconds:\s*\d"),
    "deprecated: SkotiqTypography.h1..h6": re.compile(r"SkotiqTypography\.h[1-6]\b"),
    "deprecated: surfaceAlt": re.compile(r"\.surfaceAlt\b"),
    "deprecated: SubTabButton": re.compile(r"\bSubTabButton\("),
    "deprecated: ScreenHeader": re.compile(r"\bScreenHeader\("),
    "deprecated: ContextualTourPrompt": re.compile(r"ContextualTourPrompt"),
    "raw IconButton(": re.compile(r"(?<![A-Za-z])IconButton\("),
    "placeholder ---": re.compile(r"['\"]---['\"]|--:--"),
    "Co-Authored-By trailer": re.compile(r"Co-Authored-By"),
}
FAIL_PREFIXES = ("packages/skotiq_ui/lib/", "packages/skotiq_app/lib/")
# The theme directory DEFINES the literals everyone else must reference; report, never fail.
EXEMPT_PREFIXES = ("packages/skotiq_ui/lib/src/theme/", "packages/skotiq_ui/lib/src/tokens/")


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    repo = "."
    if "--repo" in sys.argv:
        repo = sys.argv[sys.argv.index("--repo") + 1]
    if not args:
        print(__doc__)
        return 2
    base = args[0]
    head = args[1] if len(args) > 1 else "HEAD"
    diff = subprocess.run(
        ["git", "-C", repo, "diff", "--unified=0", f"{base}...{head}", "--", "*.dart"],
        capture_output=True, text=True, check=True,
    ).stdout
    current = None
    line_no = 0
    hits: dict[str, list[str]] = {k: [] for k in PATTERNS}
    fail = False
    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            current = raw[6:] if raw.startswith("+++ b/") else raw[4:]
            continue
        if raw.startswith("@@"):
            m = re.search(r"\+(\d+)", raw)
            line_no = int(m.group(1)) - 1 if m else 0
            continue
        if raw.startswith("+") and not raw.startswith("+++"):
            line_no += 1
            text = raw[1:]
            if text.lstrip().startswith("//"):
                continue
            for name, rx in PATTERNS.items():
                if rx.search(text):
                    loc = f"{current}:{line_no}"
                    hits[name].append(loc)
                    if current and current.startswith(FAIL_PREFIXES) and not current.startswith(EXEMPT_PREFIXES) and "/test/" not in current:
                        fail = True
    total = 0
    for name, locs in hits.items():
        if not locs:
            continue
        total += len(locs)
        print(f"{len(locs):4d}  {name}")
        for loc in locs[:6]:
            print(f"        {loc}")
        if len(locs) > 6:
            print(f"        … {len(locs) - 6} more")
    if total == 0:
        print("no forbidden literals in added lines")
    print("RESULT:", "FAIL (hits under lib/)" if fail else "PASS")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
