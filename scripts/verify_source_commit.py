"""Check that every release archive was built from one commit.

Each Linux and Windows archive carries SOURCE-COMMIT.txt, written by the job
that built it. A release is built from the commit its tag names, so every
copy, and the loose SOURCE-COMMIT.txt beside the assets, must name that commit.
"""

import argparse
import sys
import tarfile
import zipfile
from pathlib import Path

NAME = "SOURCE-COMMIT.txt"


def archive_commits(path):
    if path.name.endswith(".zip"):
        with zipfile.ZipFile(path) as archive:
            return [archive.read(n).decode("ascii").strip()
                    for n in archive.namelist() if n.rsplit("/", 1)[-1] == NAME]
    with tarfile.open(path) as archive:
        return [archive.extractfile(m).read().decode("ascii").strip()
                for m in archive.getmembers() if m.isfile() and m.name.rsplit("/", 1)[-1] == NAME]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    problems = []
    loose = args.assets / NAME
    if not loose.is_file() or loose.read_text().strip() != args.commit:
        problems.append(f"{loose} does not name {args.commit}")
    archives = sorted(p for p in args.assets.iterdir()
                      if p.name.endswith((".zip", ".tar.gz")))
    if not archives:
        problems.append(f"no .zip or .tar.gz archive in {args.assets}")
    for path in archives:
        commits = archive_commits(path)
        if commits != [args.commit]:
            problems.append(f"{path.name} carries {commits or 'no ' + NAME}, not [{args.commit}]")
    for problem in problems:
        print(f"::error::{problem}", file=sys.stderr)
    if problems:
        return 1
    print(f"Every archive was built from {args.commit}: " + ", ".join(p.name for p in archives))
    return 0


if __name__ == "__main__":
    sys.exit(main())
