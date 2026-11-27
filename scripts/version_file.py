"""Read version.yaml: the release, its build number and its channel.

Run as a script, prints one field: `python3 scripts/version_file.py build_number`.
"""

import re
import sys
from pathlib import Path

CHANNELS = ("stable", "beta", "alpha")


def read(text):
    """{version, build_number, channel} from version.yaml text; a field that is
    missing or malformed is None. A channel declared more than once is None."""
    version = re.search(r"""^version:[ \t]*["']?([^"'#\s]+)""", text, re.M)
    build = re.search(r"^build_number:[ \t]*(\d+)", text, re.M)
    channels = list(re.finditer(
        r"^channel:[ \t]*(?P<quote>[\"']?)(?P<channel>stable|beta|alpha)(?P=quote)[ \t]*(?:#.*)?$",
        text, re.M,
    ))
    declarations = re.findall(r"^channel:", text, re.M)
    return {
        "version": version.group(1) if version else None,
        "build_number": int(build.group(1)) if build else None,
        "channel": channels[0].group("channel")
        if len(channels) == 1 and len(declarations) == 1 else None,
    }


def main(argv):
    if len(argv) not in (2, 3) or argv[1] not in ("version", "build_number", "channel"):
        print("usage: version_file.py version|build_number|channel [path]", file=sys.stderr)
        return 2
    path = Path(argv[2]) if len(argv) == 3 else Path("version.yaml")
    value = read(path.read_text())[argv[1]]
    if value is None:
        print(f"::error::{path} declares no valid {argv[1]}.", file=sys.stderr)
        return 1
    print(value)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
