#!/usr/bin/env python3
"""Check relative links in Markdown files resolve to files on disk.

Scans every tracked ``*.md`` file under the repository root, extracts inline
links ``[text](target)`` and reference-style link definitions, ignores
absolute URLs, ``mailto:``, ``tel:``, and pure ``#anchor`` jumps, then resolves
the remaining targets relative to the file that contains them.

A target is reported broken when the path portion does not exist on disk.
Anchor fragments are checked only for links whose path resolves to a Markdown
file: the fragment must match a GitHub-style slug of a heading in that file.
"""

from __future__ import annotations

import re
import subprocess
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Inline links: [text](target "optional title") — target must not start with #
# or a URI scheme. Also match <target> autolinks of relative paths.
INLINE_RE = re.compile(r"!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+[\"'][^\")]*[\"'])?\s*\)")
# Reference definitions: [id]: target
REFDEF_RE = re.compile(r"^\s*\[[^\]]+\]:\s*<?([^\s>]+)>?", re.MULTILINE)
# HTML image tags with a relative src
IMG_RE = re.compile(r"<img[^>]+src=[\"']([^\"']+)[\"']")

SKIP_SCHEMES = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")

HEADING_RE = re.compile(r"^#{1,6}\s+(.*?)\s*#*\s*$", re.MULTILINE)


def slugify(text: str) -> str:
    """Approximate GitHub's heading-anchor slug."""
    text = re.sub(r"<[^>]+>", "", text)  # strip inline HTML
    text = re.sub(r"`([^`]*)`", r"\1", text)  # unwrap code spans
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)  # unwrap links
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = text.lower()
    text = re.sub(r"[^\w\s-]", "", text, flags=re.UNICODE)
    return text.strip().replace(" ", "-")


def anchors_of(md_path: Path) -> set[str]:
    try:
        text = md_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return set()
    slugs: set[str] = set()
    seen: dict[str, int] = {}
    for m in HEADING_RE.finditer(text):
        slug = slugify(m.group(1))
        n = seen.get(slug, 0)
        seen[slug] = n + 1
        slugs.add(slug if n == 0 else f"{slug}-{n}")
    return slugs


def strip_fenced_code(text: str) -> str:
    """Blank out fenced code blocks so code is not parsed as Markdown links."""
    return re.sub(
        r"^(```|~~~).*?^\1",
        lambda m: "\n" * m.group(0).count("\n"),
        text,
        flags=re.MULTILINE | re.DOTALL,
    )


def md_files() -> list[Path]:
    out = subprocess.run(
        ["git", "ls-files", "*.md"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return [ROOT / line for line in out.stdout.splitlines() if line.strip()]


def main() -> int:
    check_anchors = "--anchors" in sys.argv
    broken: list[tuple[Path, int, str, str]] = []
    anchor_cache: dict[Path, set[str]] = {}

    for md in md_files():
        text = md.read_text(encoding="utf-8", errors="replace")
        text = strip_fenced_code(text)
        targets: list[tuple[int, str]] = []
        for m in INLINE_RE.finditer(text):
            targets.append((text.count("\n", 0, m.start()) + 1, m.group(1)))
        for m in REFDEF_RE.finditer(text):
            targets.append((text.count("\n", 0, m.start()) + 1, m.group(1)))
        for m in IMG_RE.finditer(text):
            targets.append((text.count("\n", 0, m.start()) + 1, m.group(1)))

        for lineno, raw in targets:
            if not raw or raw.startswith("#") or SKIP_SCHEMES.match(raw):
                continue
            path_part, _, frag = raw.partition("#")
            path_part = path_part.replace("%20", " ")
            if not path_part:
                continue
            resolved = (md.parent / path_part).resolve()
            try:
                resolved.relative_to(ROOT)
            except ValueError:
                pass  # links outside the repo are still checked for existence
            if not resolved.exists():
                broken.append((md.relative_to(ROOT), lineno, raw, "missing file"))
            elif check_anchors and frag and resolved.suffix.lower() == ".md":
                if resolved not in anchor_cache:
                    anchor_cache[resolved] = anchors_of(resolved)
                slug = frag.lower().replace("%20", "-")
                if slug not in anchor_cache[resolved]:
                    broken.append(
                        (md.relative_to(ROOT), lineno, raw, "missing anchor")
                    )

    for rel, lineno, raw, why in broken:
        print(f"{rel}:{lineno}: [{why}] {raw}")
    print(f"\nTotal broken: {len(broken)}", file=sys.stderr)
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
