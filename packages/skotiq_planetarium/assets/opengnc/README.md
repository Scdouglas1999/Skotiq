# OpenNGC DSO catalog (read-only source)

Place **`NGC.csv`** here for the planetarium v2 DSO catalog builder (`build_opengnc`).

Download from OpenNGC:

https://raw.githubusercontent.com/mattiaverga/OpenNGC/master/database_files/NGC.csv

The file is not committed to git (~5 MB).

Build the mmap catalog from the repository root:

```bash
cargo run -p skotiq_planetarium --bin build_opengnc
```

Output: `apps/desktop/assets/planetarium/catalogs/core/dso-opengnc-v1.bin`.
