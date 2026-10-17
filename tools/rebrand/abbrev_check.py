#!/usr/bin/env python3
"""Guard against the old product abbreviation ``ns``/``NS`` creeping back.

Scans every tracked text file for the abbreviation families the rebrand
renamed to ``sk``/``SK`` and fails on any hit outside the allowlist. Run from
the repo root:

    python3 tools/rebrand/abbrev_check.py

Exit 0 = clean; exit 1 = at least one unallowed hit (each printed).

The allowlist exists for two kinds of survivors:

* non-product ``ns`` meanings — nanoseconds, XML namespaces, mDNS ``nsd``
  package, DNS/netns, Apple ``NS`` APIs, vendor constants (``LIBRAW_*``,
  ``ENABLE_NS_ASSERTIONS``, ``APNS*``), HEALPix ``nside`` — and
* deliberate backwards-compatibility code — the pre-rename identifiers kept
  so old user data still opens (secure-storage keys in the install migration,
  legacy file extensions/magics with dual-read fallbacks).

Reports/ and historical release notes are verbatim records and are exempt
(``reports/``, ``docs/CHANGELOG.md`` is not — the extension names it carries
were updated when the formats were renamed).
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

# Abbreviation families the rebrand owned. Each pattern is deliberately loose
# (substring-level) so nothing slips through on a technicality; the allowlist
# carves back the legitimate survivors.
PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("NS_* environment/identifier", re.compile(r"\bNS_[A-Z][A-Z0-9_]*")),
    ("ns-prefixed import alias", re.compile(r"\bas ns[_a-z0-9]*\b")),
    ("ns temp prefix", re.compile(r"[\"']ns[_-]")),
    ("ns file extension", re.compile(r"\.ns[a-z]+")),
    ("ns frame-id prefix", re.compile(r"[\"']ns:")),
    ("nshub- secret prefix", re.compile(r"nshub-")),
    ("Ns-prefixed identifier", re.compile(r"\bNs[A-Z][a-zA-Z0-9]*")),
    ("ns-prefixed identifier", re.compile(r"\bns[A-Z][a-zA-Z0-9]*")),
    ("ns- css/log tag", re.compile(r"\[NS\]|\"ns-[a-z]|'ns-[a-z]")),
    ("ns dotted key", re.compile(r"\bns\.[a-z]")),
]

# Whole-subtree exemptions: vendored code, platform runners (Apple's NS-prefixed
# APIs), generated/binary artifacts, and verbatim historical records.
EXEMPT_DIRS = (
    "native/skotiq_native/imaging/vendor/",
    "native/skotiq_native/test-fixtures/",
    "third_party/",
    "graphify-out/",
    "reports/",
    "tools/rebrand/",
    "apps/desktop/macos/",
    "apps/desktop/ios/",
    "apps/desktop/windows/",
    "apps/mobile/ios/",
    "apps/mobile/macos/",
    "apps/mobile/android/",
)
EXEMPT_FILES = {
    "packages/skotiq_core/test/fixtures/skotiq-v4.3.0-profile.db",
}
BINARY_EXTS = {
    ".fits", ".fit", ".db", ".dll", ".so", ".dylib", ".png", ".jpg",
    ".jpeg", ".ico", ".icns", ".woff", ".woff2", ".ttf", ".otf", ".zip",
    ".gz", ".nst",
}

# Per-file allowlist for legitimate survivors. Any line containing one of the
# file's substrings is excused — keep these tight so drift is visible.
ALLOWLIST: dict[str, list[str]] = {
    # ---- Backwards-compatibility (dual-read) sites ----
    "native/skotiq_native/imaging/src/sky_atlas.rs": [
        "LEGACY_TILE_MAGIC", "NST1", ".nst", "legacy_tile_path",
    ],
    "native/skotiq_native/imaging/src/depthlock/input.rs": [
        "NS-SESID", "NS-FIDX",
    ],
    "native/skotiq_native/imaging/tests/depthlock_input.rs": [
        "NS-SESID", "NS-FIDX",
    ],
    "native/skotiq_native/imaging/tests/rig_frame_shape.rs": ["ns-rig-data"],
    "native/skotiq_native/bridge/src/unified_device_ops/rig_grading_tests.rs": [
        "ns-rig-data",
    ],
    "native/skotiq_native/bridge/src/api/darkroom/export.rs": [
        "NSRECIPE-B64",
    ],
    "packages/skotiq_planetarium/lib/src/catalogs/deep_star_tile.dart": [
        "NSDT",
    ],
    "packages/skotiq_planetarium/test/deep_star_tile_test.dart": ["NSDT"],
    "packages/skotiq_core/lib/src/services/backup_service.dart": [".nsbackup"],
    "packages/skotiq_core/lib/src/services/sync/sync_service.dart": [".nsbak"],
    "packages/skotiq_core/lib/src/services/sky_atlas/sky_atlas_service.dart": [
        ".nst",
    ],
    "packages/skotiq_core/lib/src/services/constellation/constellation_service.dart": [
        ".nst",
    ],
    "packages/skotiq_core/lib/src/services/snippet_file_service.dart": [
        "nsnippet",
    ],
    "packages/skotiq_core/lib/src/services/sequence_file_service.dart": [
        "'nseq'",
    ],
    "packages/skotiq_core/lib/src/utils/legacy_install_migration.dart": [
        "ns.notif",
    ],
    "packages/skotiq_core/test/utils/legacy_install_migration_test.dart": [
        "ns.notif",
    ],
    "packages/skotiq_app/lib/screens/darkroom/darkroom_controller.dart": [
        ".nsrecipe",
    ],
    "packages/skotiq_app/lib/screens/darkroom/darkroom_controller_parts/_helpers.dart": [
        "nsrecipe",
    ],
    "packages/skotiq_app/lib/screens/settings/backup_screen.dart": [
        "nsbackup",
    ],
    "apps/desktop/lib/headless_api/handlers/backup_handlers.dart": [
        "nsbackup",
    ],
    "server/skotiq_hub/lib/src/tiles/tile_codec.dart": ["NST1"],
    "server/skotiq_hub/lib/src/tiles/tile_store.dart": [".nst"],
    "server/skotiq_hub/test/tile_codec_test.dart": [".nst", "NST1"],
    "server/skotiq_hub/test/auth_test.dart": ["nshub-", "skhub-"],
    # ---- Non-product ns meanings ----
    # mDNS discovery package (`package:nsd`) — vendor name, not the product.
    "packages/skotiq_core/lib/src/services/mdns/mdns_discovery.dart": [
        "nsd",
    ],
    "packages/skotiq_core/lib/src/services/mdns/mdns_advertiser.dart": [
        "nsd",
    ],
    # network-namespace tooling
    "tools/network/netns_setup.sh": ["netns"],
    # HEALPix nside/npix — the sky-tessellation field names, not the product.
    "packages/skotiq_core/lib/src/services/hips/healpix_nested.dart": [
        "nside", "npix",
    ],
    "packages/skotiq_core/test/services/hips/healpix_nested_test.dart": [
        "nside", "npix",
    ],
    "packages/skotiq_core/test/services/hips/hips_healpix_test.dart": [
        "nside", "npix",
    ],
}


def _exempt(path: str) -> bool:
    if path in EXEMPT_FILES:
        return True
    if any(path.startswith(d) for d in EXEMPT_DIRS):
        return True
    return Path(path).suffix.lower() in BINARY_EXTS


def _allowed(path: str, line: str) -> bool:
    return any(tok in line for tok in ALLOWLIST.get(path, ()))


def main() -> int:
    files = subprocess.run(
        ["git", "ls-files"], cwd=REPO, capture_output=True, text=True, check=True
    ).stdout.splitlines()
    hits: list[str] = []
    for rel in files:
        if _exempt(rel):
            continue
        full = REPO / rel
        try:
            text = full.read_text(encoding="utf-8", errors="strict")
        except (OSError, UnicodeDecodeError):
            continue  # binary or unreadable — not a text surface
        for lineno, line in enumerate(text.splitlines(), 1):
            if _allowed(rel, line):
                continue
            for family, pat in PATTERNS:
                m = pat.search(line)
                if m:
                    hits.append(f"{rel}:{lineno}: [{family}] {line.strip()}")
                    break
    if hits:
        print(f"{len(hits)} leftover product-abbreviation hit(s):")
        for h in hits:
            print(" ", h)
        return 1
    print("0 leftover product-abbreviation hit(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
