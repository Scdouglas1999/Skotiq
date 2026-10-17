# Bundled real-HiPS test fixtures (M31, DSS2 colour)

Committed, offline, deterministic real HiPS data for **one fixed sky field**, so
the framing GPU/HiPS tile-layer golden and render-verify tests composite genuine
DSS2-colour survey pixels with **no network access** and a **byte-stable**
result in CI.

This directory is **data only** — no code depends on it at runtime; it is loaded
exclusively by offline tests via [`fixture_field.dart`](fixture_field.dart).

## Field

| | |
|---|---|
| Object | **M31, the Andromeda Galaxy** |
| RA (ICRS/J2000) | `10.6847°` (`00h 42m 44s`) |
| Dec (ICRS/J2000) | `+41.2687°` (`+41° 16′ 07″`) |
| Plate scale used to pick tiles | `3.0° × 2.0°` FOV over a `900 × 600` px cutout |

M31 was chosen deliberately: it is a large, instantly-recognisable galaxy (so a
rendered golden is easy for a human to sanity-check), and at Norder 6 its visible
tile set — together with its whole Norder 5 / Norder 4 fallback chain — falls
entirely within HiPS directory bucket **`Dir0`** (`npix < 10000`). That keeps
every committed tile under the standard `Norder{k}/Dir0/` path this tree mirrors.

## Survey

| | |
|---|---|
| HiPS id | `CDS/P/DSS2/color` (DSS2 colour) |
| Base URL | <https://alasky.cds.unistra.fr/DSS/DSSColor> |
| Tile width | `512` px |
| Tile format | `jpeg` |
| Frame | `equatorial` |
| `hips_order` / `hips_order_min` | `9` / `0` |
| Allsky preview order | **`3`** (CDS publishes Allsky only at order 3; 0–2 are 404) |

This is the colour DSS2 HiPS the framing survey-image cutout path already uses,
so the streamed tiles agree in content with the existing single-cutout snapshot.

## Files

```
hips/
├── README.md                       ← this file (provenance + attribution)
├── dss2color_properties.txt        ← the survey's REAL properties document
├── Allsky.jpg                      ← REAL Norder3 whole-sky preview (1728×1856)
├── fixture_field.dart              ← canonical Dart descriptor tests import
├── Norder4/Dir0/Npix{163,166,169,172}.jpg          ← grandparent fallback (4 tiles)
├── Norder5/Dir0/Npix{653,654,655,664,666,
│                      676,677,678,679,688}.jpg      ← parent fallback (10 tiles)
└── Norder6/Dir0/
    ├── tiles_manifest.json          ← integrity index (sha256 + bytes) of ALL files
    └── Npix{2614…2754}.jpg          ← primary LOD, gap-free mosaic (28 tiles)
```

The committed tile set is the exact **level-of-detail fallback chain** the
loader (`HipsTileLoader`) streams:

* **Norder 6** — the *primary* sharp layer at the golden zoom (28 tiles, a
  complete seam-free mosaic of the field — every neighbour present so there are
  no black gaps to verify against);
* **Norder 5** — the *parent* fallback (`npix >> 2`), drawn under the primary
  while it streams in;
* **Norder 4** — the *grandparent* fallback;
* **Allsky (Norder 3)** — the coarsest whole-sky base layer, so the view is
  never blank.

### Why the npix lists are not arbitrary

The per-order npix values are the verbatim output of the production tile-selection
brain, `HipsTileSelection.computeVisibleTiles`
(`packages/skotiq_core/lib/src/services/hips/hips_tile_selection.dart`), run
against the field and plate scale above at the golden zoom for each order. They
are recorded identically in `fixture_field.dart` (`primaryNpix` / `parentNpix` /
`grandparentNpix`) and in `tiles_manifest.json`, so a test asks for *exactly* the
tiles that are on disk and the mosaic has no missing neighbours.

## Provenance — how these bytes were obtained (reproducible, not magic)

Every byte in this directory was fetched from the public CDS HiPS service by the
committed, auditable source-of-record script:

```
dart run tools/hips_fixtures/fetch_hips_fixtures.dart
```

That script is **not run in CI** and the tests do **not** depend on it. It exists
so a maintainer can re-derive byte-identical fixtures at any time and a reviewer
can see exactly which field, survey and tiles were committed and why. It fetches:

* `properties` → `dss2color_properties.txt`
* `Norder3/Allsky.jpg` → `Allsky.jpg`
* `Norder{4,5,6}/Dir0/Npix*.jpg` → the matching paths here,

validating each JPEG's SOI/EOI markers and each HTTP status before writing, so a
captive-portal error page or a truncated download can never land as a "tile".

`tiles_manifest.json` was generated from the downloaded bytes (the procedure is
encoded in the script's documentation); it records each file's `sha256` and byte
length so an offline test can assert the committed bytes are exactly the ones
`fixture_field.dart` promises.

### Re-fetching / refreshing

```bash
# Overwrite existing files with a fresh pull:
dart run tools/hips_fixtures/fetch_hips_fixtures.dart --force

# See what would be fetched without writing anything:
dart run tools/hips_fixtures/fetch_hips_fixtures.dart --dry-run
```

After a `--force` refresh, regenerate `tiles_manifest.json` (its sha256 values
will change only if CDS re-rendered the survey) — see the script header for the
manifest fields and the generator procedure.

## Attribution — Digitized Sky Survey (DSS2) / STScI

The imagery is the **Digitized Sky Survey**, redistributed by CDS as the
`CDS/P/DSS2/color` HiPS. Per the survey's own `properties` document
(`obs_copyright`, `obs_ack`) and the DSS copyright page
(<http://archive.stsci.edu/dss/copyright.html>):

> Digitized Sky Survey — STScI/NASA, Colored & Healpixed by CDS.

> The Digitized Sky Surveys were produced at the Space Telescope Science
> Institute under U.S. Government grant NAG W-2166. The images of these surveys
> are based on photographic data obtained using the Oschin Schmidt Telescope on
> Palomar Mountain and the UK Schmidt Telescope. … The National Geographic
> Society — Palomar Observatory Sky Atlas (POSS-I) was made by the California
> Institute of Technology with grants from the National Geographic Society. The
> Second Palomar Observatory Sky Survey (POSS-II) was made by the California
> Institute of Technology with funds from the National Science Foundation, the
> National Geographic Society, the Sloan Foundation, the Samuel Oschin
> Foundation, and the Eastman Kodak Corporation. …

* HiPS distribution: **CDS, Université de Strasbourg / CNRS** — colour composite
  and HEALPix tiling by A. Oberto & P. Fernique (CDS).
* HiPS DOI: `10.26093/cds/aladin/ht9n-7r`
* HiPS licence (as published): `ODbL-1.0`; `hips_copyright = CNRS/Unistra`.

The full, unaltered acknowledgement text is preserved verbatim in
`dss2color_properties.txt` (`obs_ack`). These fixtures are used solely for
automated regression testing of the framing renderer.
