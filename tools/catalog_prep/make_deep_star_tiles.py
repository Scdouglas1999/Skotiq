#!/usr/bin/env python3
"""Convert a public deep-star source catalog into Skotiq SKDT tiles.

The planetarium's *deep-star tier* extends the bundled HYG atlas (~mag 11.5
floor) downward to a Tycho-2 / Gaia subset, served as small per-region binary
tiles the app streams on demand. This script converts a source catalog (CSV of
RA/Dec/magnitude rows) into that tile format plus a ``manifest.json`` you host
at a static URL; the app's ``DeepStarCatalogManager`` downloads and SHA-256
verifies the tiles into its data dir.

It does NOT download anything — point ``--input`` at a catalog you already have
(see README.md for honest notes on obtaining Tycho-2 / Gaia and the column
mapping). For tests / demos, ``--synthetic`` writes a tiny deterministic
tileset with no external data.

SKDT binary layout (little-endian) — MUST stay byte-identical to the Dart
decoder in ``deep_star_tile.dart``::

    magic 'SKDT' (4) | version u16 (=1) | raBand u8 | decBand u8
    starCount u32 | reserved u32 (=0)
    then starCount * 12-byte records, sorted ascending by magnitude:
        ra  u32  micro-hours   (ra_hours * 1e6)
        dec i32  micro-degrees (dec_deg  * 1e6)
        mag i16  milli-mag     (mag * 1000)
        bv  i16  milli-mag     (bv  * 1000); 32767 = unknown

Tiling: 24 RA bands (1h) x 18 Dec bands (10 deg), matching the renderer's
``CelestialSpatialIndex`` cells so app-side culling agrees with the tiling.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import struct
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

MAGIC = b"SKDT"
FORMAT_VERSION = 1
HEADER_BYTES = 16
RECORD_BYTES = 12
BV_UNKNOWN = 0x7FFF

RA_BANDS = 24
DEC_BANDS = 18

# Stars at/above this magnitude come from the bundled HYG catalog; excluding
# them keeps the two tiers from double-drawing. Keep in sync with
# kHygFaintFloorMag in deep_star_providers.dart.
DEFAULT_MAG_FLOOR = 11.5
DEFAULT_MAG_LIMIT = 13.0


@dataclass
class Star:
    ra_hours: float
    dec_deg: float
    mag: float
    bv: float | None


def ra_band_of(ra_hours: float) -> int:
    r = ra_hours % 24.0
    if r < 0:
        r += 24.0
    return min(RA_BANDS - 1, max(0, int(r / 24.0 * RA_BANDS)))


def dec_band_of(dec_deg: float) -> int:
    return min(DEC_BANDS - 1, max(0, int((dec_deg + 90.0) / 180.0 * DEC_BANDS)))


def tile_file_name(ra_band: int, dec_band: int) -> str:
    return f"tile_r{ra_band:02d}_d{dec_band:02d}.skdt"


def encode_tile(ra_band: int, dec_band: int, stars: list[Star]) -> bytes:
    # Sort brightest-first so the app's k-way merge can stop early.
    stars = sorted(stars, key=lambda s: s.mag)
    buf = bytearray()
    buf += MAGIC
    buf += struct.pack("<H", FORMAT_VERSION)
    buf += struct.pack("<B", ra_band)
    buf += struct.pack("<B", dec_band)
    buf += struct.pack("<I", len(stars))
    buf += struct.pack("<I", 0)  # reserved/flags
    for s in stars:
        ra_micro = max(0, min(24_000_000, round(s.ra_hours * 1e6)))
        dec_micro = max(-90_000_000, min(90_000_000, round(s.dec_deg * 1e6)))
        milli_mag = max(-32768, min(32766, round(s.mag * 1000)))
        if s.bv is None:
            milli_bv = BV_UNKNOWN
        else:
            milli_bv = max(-32768, min(32766, round(s.bv * 1000)))
        buf += struct.pack("<Iihh", ra_micro, dec_micro, milli_mag, milli_bv)
    return bytes(buf)


def read_source_csv(
    path: Path,
    ra_col: str,
    dec_col: str,
    mag_col: str,
    bv_col: str | None,
    ra_in_degrees: bool,
    mag_floor: float,
    mag_limit: float,
) -> list[Star]:
    stars: list[Star] = []
    with path.open(newline="") as fh:
        reader = csv.DictReader(fh)
        missing = {ra_col, dec_col, mag_col} - set(reader.fieldnames or [])
        if missing:
            sys.exit(f"input is missing required column(s): {sorted(missing)}")
        for row in reader:
            try:
                ra = float(row[ra_col])
                dec = float(row[dec_col])
                mag = float(row[mag_col])
            except (TypeError, ValueError):
                continue
            if ra_in_degrees:
                ra = ra / 15.0
            ra = ra % 24.0
            if not (-90.0 <= dec <= 90.0):
                continue
            # Keep only the deep tier: fainter than the HYG floor, down to limit.
            if mag <= mag_floor or mag > mag_limit:
                continue
            bv: float | None = None
            if bv_col and row.get(bv_col):
                try:
                    bv = float(row[bv_col])
                except ValueError:
                    bv = None
            stars.append(Star(ra, dec, mag, bv))
    return stars


def make_synthetic(
    mag_floor: float, mag_limit: float, per_tile: int
) -> list[Star]:
    """Deterministic pseudo-random tileset — no external data.

    Honesty: this is NOT real astrometry. It exists so the app's tile
    download/decode/cull path and the unit tests have a self-contained fixture;
    real deep-star tiles must be built from Tycho-2 / Gaia (see README.md).
    """
    stars: list[Star] = []
    # Simple LCG for reproducibility without numpy.
    seed = 0x5EED5301
    def rnd() -> float:
        nonlocal seed
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        return seed / 0x7FFFFFFF

    for rb in range(RA_BANDS):
        for db in range(DEC_BANDS):
            for _ in range(per_tile):
                ra = (rb + rnd()) / RA_BANDS * 24.0
                dec = (db + rnd()) / DEC_BANDS * 180.0 - 90.0
                # Steep faint-end power law (more faint than bright).
                mag = mag_floor + (mag_limit - mag_floor) * (rnd() ** 0.5)
                bv = rnd() * 1.8 - 0.2
                stars.append(Star(ra, dec, mag, bv))
    return stars


def build_tileset(
    stars: list[Star],
    out_dir: Path,
    name: str,
    source: str,
    mag_floor: float,
    mag_limit: float,
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    # Bin into tiles.
    bins: dict[tuple[int, int], list[Star]] = {}
    for s in stars:
        key = (ra_band_of(s.ra_hours), dec_band_of(s.dec_deg))
        bins.setdefault(key, []).append(s)

    tiles_meta = []
    for (rb, db), tile_stars in sorted(bins.items()):
        if not tile_stars:
            continue
        data = encode_tile(rb, db, tile_stars)
        fname = tile_file_name(rb, db)
        (out_dir / fname).write_bytes(data)
        tiles_meta.append(
            {
                "ra": rb,
                "dec": db,
                "file": fname,
                "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "stars": len(tile_stars),
            }
        )

    manifest = {
        "format": "skotiq-deep-star-tiles",
        "formatVersion": FORMAT_VERSION,
        "name": name,
        "source": source,
        "magnitudeFloor": mag_floor,
        "magnitudeLimit": mag_limit,
        "generated": datetime.now(timezone.utc).isoformat(),
        "tileCount": len(tiles_meta),
        "totalStars": sum(t["stars"] for t in tiles_meta),
        "totalBytes": sum(t["bytes"] for t in tiles_meta),
        "tiles": tiles_meta,
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))

    print(
        f"wrote {len(tiles_meta)} tiles, "
        f"{manifest['totalStars']} stars, "
        f"{manifest['totalBytes'] / 1024:.1f} KiB to {out_dir}"
    )


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", type=Path, help="source CSV catalog")
    ap.add_argument("--out", type=Path, required=True, help="output directory")
    ap.add_argument("--name", default="Deep-star tier")
    ap.add_argument("--source", default="unknown")
    ap.add_argument("--ra-col", default="ra")
    ap.add_argument("--dec-col", default="dec")
    ap.add_argument("--mag-col", default="mag")
    ap.add_argument("--bv-col", default=None)
    ap.add_argument("--ra-degrees", action="store_true",
                    help="treat RA column as degrees, not hours")
    ap.add_argument("--mag-floor", type=float, default=DEFAULT_MAG_FLOOR)
    ap.add_argument("--mag-limit", type=float, default=DEFAULT_MAG_LIMIT)
    ap.add_argument("--synthetic", action="store_true",
                    help="generate a tiny deterministic test tileset (no input)")
    ap.add_argument("--synthetic-per-tile", type=int, default=40)
    args = ap.parse_args()

    if args.synthetic:
        stars = make_synthetic(args.mag_floor, args.mag_limit,
                               args.synthetic_per_tile)
        source = args.source if args.source != "unknown" else "synthetic"
        build_tileset(stars, args.out, args.name, source,
                      args.mag_floor, args.mag_limit)
        return

    if not args.input:
        ap.error("--input is required unless --synthetic is given")
    stars = read_source_csv(
        args.input, args.ra_col, args.dec_col, args.mag_col, args.bv_col,
        args.ra_degrees, args.mag_floor, args.mag_limit,
    )
    if not stars:
        sys.exit("no stars passed the magnitude filter — check columns/units")
    build_tileset(stars, args.out, args.name, args.source,
                  args.mag_floor, args.mag_limit)


if __name__ == "__main__":
    main()
