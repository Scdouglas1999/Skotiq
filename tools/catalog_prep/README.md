# catalog_prep — deep-star tile builder

Builds the Skotiq planetarium **deep-star tier**: a downloadable
Tycho-2 / Gaia subset that extends the bundled HYG atlas (which floors out near
magnitude 11.5) down to ~mag 13. The app streams these tiles on demand via
`DeepStarCatalogManager`, culling to the view and only when zoomed in past the
deep-star FOV threshold.

`make_deep_star_tiles.py` converts a source CSV into the binary `.skdt` tile
format plus a `manifest.json`, which you host at a static URL. The app fetches
`<baseUrl>/manifest.json`, then each tile, verifying every tile's SHA-256
against the manifest.

## Honest data note

This repository and this script do **not** download any catalog data — the
public Tycho-2 / Gaia files are large and not bundled here, and they can't be
fetched from this build environment. You must obtain a source catalog yourself
and point `--input` at it. For tests and demos, `--synthetic` writes a tiny
deterministic tileset with no external dependency; that synthetic data is
**not real astrometry** and must never ship as the actual deep-star tier.

## Tile format (SKDT v1)

Little-endian; this layout is byte-identical to the Dart decoder in
`packages/skotiq_planetarium/lib/src/catalogs/deep_star_tile.dart`. If you
change one, change both.

```
magic 'SKDT' (4) | version u16 (=1) | raBand u8 | decBand u8
starCount u32 | reserved u32 (=0)
starCount * 12-byte records, sorted ascending by magnitude (brightest first):
    ra  u32  micro-hours    (ra_hours * 1e6)
    dec i32  micro-degrees  (dec_deg  * 1e6)
    mag i16  milli-mag      (mag * 1000)
    bv  i16  milli-mag      (bv  * 1000); 32767 = unknown
```

The sky is split into 24 RA bands (1 hour each) × 18 Dec bands (10° each),
matching the renderer's `CelestialSpatialIndex` cells so view culling agrees
with the tiling. One file per non-empty cell: `tile_rRR_dDD.skdt`.

## Usage

Synthetic test tileset (used by the unit tests; tiny, deterministic):

```bash
python3 make_deep_star_tiles.py --synthetic \
    --out ../../packages/skotiq_planetarium/test/fixtures/deep_star_tiles \
    --synthetic-per-tile 12
```

Real tiles from a CSV you supply (columns configurable):

```bash
python3 make_deep_star_tiles.py \
    --input tycho2_subset.csv \
    --ra-col RAdeg --dec-col DEdeg --mag-col VT --bv-col "B-V" --ra-degrees \
    --mag-floor 11.5 --mag-limit 13.0 \
    --name "Tycho-2 deep tier" \
    --source "Tycho-2 (Hog et al. 2000)" \
    --out ./skotiq_deep_stars
```

Then host it (any static file server works):

```bash
cd skotiq_deep_stars && python3 -m http.server 8765
```

and point the app's deep-star base URL at
`http://<host>:8765` (the default in `DeepStarCatalogManager` is a localhost
self-host). The app appends `/manifest.json` and `/tile_rRR_dDD.skdt`.

## Obtaining source catalogs

- **Tycho-2** (Høg et al. 2000) — ~2.5M stars to ~V 11.5; the brighter rows
  overlap HYG, so the `--mag-floor` filter keeps only the tier below it. Public
  via VizieR (catalog I/259).
- **Gaia DR3** — far deeper; you'll want to pre-filter to a magnitude band and
  decimate before tiling, or tiles get huge. Public via the Gaia archive /
  VizieR.

Map your file's columns with `--ra-col / --dec-col / --mag-col / --bv-col`, and
pass `--ra-degrees` if RA is in degrees rather than hours.
