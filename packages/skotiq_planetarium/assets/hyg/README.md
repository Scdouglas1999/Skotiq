# HYG star catalog (read-only source)

Place **`hyg_v42.csv`** here for the planetarium v2 tile converter (`build_hyg_tiles`).

Download (gzipped) from Codeberg:

https://codeberg.org/astronexus/hyg/media/branch/main/data/hyg/CURRENT/hyg_v42.csv.gz

Decompress to `hyg_v42.csv`. The file is not committed to git (~34 MB).

Build tiles from the repository root:

```bash
cargo run -p skotiq_planetarium --bin build_hyg_tiles
```

Output: `apps/desktop/assets/planetarium/catalogs/stars-hyg-v1/tiles/`.
