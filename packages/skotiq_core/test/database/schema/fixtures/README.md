# Schema fixtures

Both files were written by the code at commit `c04d55c8d`, the last one that
created tables with raw DDL in migrations and services. They pin what that
code put on disk, so `one_schema_source_test.dart` can show the drift
definitions describe the same database.

- `base_c04d55c8d_populated.db.gz` is a schema v64 database with at least one
  row in every table, gzipped. The tables that only existed once their
  service had run are in it, written by those services; every other table has
  one row filled by column type. It holds no user data.
- `base_c04d55c8d_fresh_schema.json` is the structural dump (`schema_dump.dart`)
  of a database that commit created from nothing.

To regenerate, check out `c04d55c8d`, copy `../schema_dump.dart` and
`generate_base_fixtures.dart.txt` (as `gen_base_fixture_test.dart`) into
`packages/skotiq_core/test/`, and run:

```bash
cd packages/skotiq_core
NS_FIXTURE_OUT=/tmp/fixtures flutter test test/gen_base_fixture_test.dart
gzip -9 -n /tmp/fixtures/base_populated.db
```

The generator is kept as `.txt` because it only compiles against that commit.
