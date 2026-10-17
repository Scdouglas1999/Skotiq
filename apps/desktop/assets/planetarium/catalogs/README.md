# Planetarium v2 catalog packs (desktop bundle)

Bundled catalog packs live under this directory and are declared in `apps/desktop/pubspec.yaml` so Flutter ships them inside the desktop app (`assets/planetarium/catalogs/...` at runtime).

| Pack | Directory | Contents |
|------|-----------|----------|
| **core** | `core/` | OpenNGC DSO mmap catalog (`dso-opengnc-v1.bin`) + `pack.json` |
| **stars-hyg** | `stars-hyg-v1/` | HYG HEALPix star tiles (`tiles/*.bin`) + `pack.json` |

Each pack directory includes a `pack.json` manifest (SHA-256 per file). After rebuilding payloads, regenerate manifests so digests match (see below).

## License and attribution

The two bundled catalog packs are transformed database extracts distributed
under the [Creative Commons Attribution-ShareAlike 4.0 International
license](https://creativecommons.org/licenses/by-sa/4.0/):

- **OpenNGC:** compiled by Mattia Verga and OpenNGC contributors. Source:
  <https://github.com/mattiaverga/OpenNGC>. The build filters and converts the
  source CSV into Skotiq's fixed-width `dso-opengnc-v1.bin` format.
- **HYG Database:** compiled by David Nash / Astronexus and contributors.
  Source: <https://codeberg.org/astronexus/hyg>. The build filters HYG v4.2 to
  magnitude 15 and partitions it into Skotiq's HEALPix tile format.

The resulting catalog pack data is licensed CC BY-SA 4.0. Skotiq's program
code remains governed by its own license; no additional restrictions are
asserted over the source datasets.

## Prerequisites (read-only sources, not committed)

| Tool | Source CSV | Setup |
|------|------------|--------|
| `build_opengnc` | `packages/skotiq_planetarium/assets/opengnc/NGC.csv` | [OpenNGC README](../../../../../packages/skotiq_planetarium/assets/opengnc/README.md) |
| `build_hyg_tiles` | `packages/skotiq_planetarium/assets/hyg/hyg_v42.csv` | [HYG README](../../../../../packages/skotiq_planetarium/assets/hyg/README.md) |

## Build steps (from repository root)

Run from `native/skotiq_native` (or pass an explicit repo root as the first CLI argument):

```bash
# Core pack — OpenNGC → dso-opengnc-v1.bin
cargo run -p skotiq_planetarium --bin build_opengnc

# Stars pack — HYG → HEALPix tiles (768 files, nside=8, mag ≤ 15)
cargo run -p skotiq_planetarium --bin build_hyg_tiles
```

**Outputs**

- `core/dso-opengnc-v1.bin` (13 306 DSO records at mag ≤ 20)
- `stars-hyg-v1/tiles/*.bin` (768 tiles, 119 432 stars)

Both tools self-check record/tile counts and exit non-zero on mismatch.

## `pack.json` manifests

Manifests list every payload path (POSIX `/` separators) with lowercase SHA-256 hex digests. Rust loads them via `load_and_verify_pack` (fail loud on missing files or hash mismatch).

Regenerate after rebuilding binaries (PowerShell example from repo root):

```powershell
function Get-Sha256Hex($path) { (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower() }
# core — single file
$coreDir = "apps/desktop/assets/planetarium/catalogs/core"
$files = @{}
Get-ChildItem $coreDir -File | Where-Object { $_.Name -ne 'pack.json' } | ForEach-Object { $files[$_.Name] = Get-Sha256Hex $_.FullName }
$obj = @{ id='core'; name='Core catalogs'; version='1'; depends_on=@(); files=$files }
[System.IO.File]::WriteAllText("$coreDir/pack.json", ($obj | ConvertTo-Json -Depth 5) + "`n")
# stars-hyg-v1 — one entry per tile
$hygDir = "apps/desktop/assets/planetarium/catalogs/stars-hyg-v1"
$files = [ordered]@{}
Get-ChildItem "$hygDir/tiles" -File | Sort-Object Name | ForEach-Object { $files["tiles/$($_.Name)"] = Get-Sha256Hex $_.FullName }
$obj = @{ id='stars-hyg-v1'; name='HYG stars (HEALPix nside=8)'; version='1'; depends_on=@(); files=$files }
[System.IO.File]::WriteAllText("$hygDir/pack.json", ($obj | ConvertTo-Json -Depth 5) + "`n")
```

Generated `.bin` payloads are gitignored; commit updated `pack.json` when hashes change.
