# w2-abbrev — `ns`/`NS` abbreviation removal

Worktree: `skotiq-w2-abbrev`, branched at `b1105ed2e` (verified
`git rev-parse HEAD` = `b1105ed2eee08622582b90668af15540f9a5ec19`, branch
`rebrand/skotiq-w2-abbrev`, clean tree).

## Scope decision

The old product name's `ns`/`NS` abbreviation appears in five classes. Per the
brief, every trace the code can control goes to `sk`/`SK`; persisted
identifiers get a compat layer rather than being orphaned.

### Renamed outright (transient / not persisted)

- Fault-injection + test env vars: `NS_POA_*`, `NS_QHY_*`,
  `NS_TOUPTEK_*`, `NS_FLI_*`, `NS_MORAVIAN_*`, `NS_FUJIFILM_*`,
  `NS_OTA_IN_SHIM`, `NS_OTA_REPO`, `NS_AUDIT_{RUNTIME,DISPLAY,GEOMETRY}`,
  `NS_ANDROID_{APP_ID,AVD,RUNTIME}` → `SK_*`.
- Temp-dir/file prefixes `ns_*`, `ns-*`, `nst_*`, `nshub_*` in Dart `createTemp`
  and Rust `temp_dir`/test helpers → `sk_*`, `skt_*`, `skhub_*`.
- Import aliases `as ns_events`, `as ns` → `as sk_events`, `as sk`.
- In-flight temp suffixes: `.nshatmp` → `.skhatmp`,
  `.nsdelivery-part` → `.skdelivery-part`,
  `.nsdownload-part` → `.skdownload-part`, `nst.tmp.*` → `skt.tmp.*`,
  `<dl>.nsdt.part` follows the renamed `.skdt` below.
- Tool/scratch paths and names: `/tmp/ns-audit` → `/tmp/sk-audit`,
  `/tmp/ns-android` → `/tmp/sk-android`, `ns_test_api35` → `sk_test_api35`,
  `~/.cache/ns-soak` → `~/.cache/sk-soak`, `~/.cache/ns-ota` →
  `~/.cache/sk-ota`, `/tmp/nswf` → `/tmp/skwf`, test-only `ns.db` → `sk.db`,
  test-only `.nsm` sidecar name → `.skm`, `.nsq` comment shorthand → `.skeq`.
- `nshub-<hex>` generated hub secrets → `skhub-<hex>` (prefix is not parsed;
  existing stored secrets remain valid opaque strings).
- `ns:<session>:<index>` DepthLock frame ids → `sk:<session>:<index>`. The
  identity reader accepts `SK-SESID`/`SK-FIDX` and the pre-rename
  `NS-SESID`/`NS-FIDX` cards, and emits the `sk:` form for both so a
  mixed-era light pool still collapses to one identity.

### Renamed with read-compat (persisted; old artifacts keep working)

New writes use the `sk` names; readers accept both old and new.

- `.nsbackup` → `.skbackup` (restore/upload accepts `.skbackup`, `.nsbackup`,
  `.json`).
- `.nsbak` cloud-sync bundle suffix → `.skbak` (remote listing still matches
  `.nsbak` for already-pushed bundles).
- `.nsrecipe` → `.skrecipe`: export writes `<file>.skrecipe` with
  `kind: "skrecipe"`; the importer's picker accepts both extensions and the
  `kind` check accepts `"skrecipe"` and `"nsrecipe"`. Branch-name stripping
  removes either suffix.
- `.nsmaster` → `.skmaster` (name producer only; sidecars are always handed
  around by explicit path).
- `.nseq.json` → `.skeq.json` suggested names; pickers accept
  `['json', 'skeq', 'nseq']`.
- `.nsnippet.json` → `.sknippet.json` (`snippetFileExtension` constant;
  pickers accept both).
- `.nsplugin` → `.skplugin` (upload/install accepts either).
- `.nst` → `.skt` for atlas sidecars, swarm overlays and `delta_*.skt`
  federation payloads. Sidecar paths are constructed by convention
  (`<tileId>.skt`), so a lazy on-disk migration resolves `.skt` first and
  falls back to `.nst`; `store_tile`/`TileStore.save` delete the stale
  `.nst` twin after a successful `.skt` write; directory scans and the
  delta cleanup accept/reclaim both.
- `.nsdt` deep-star tiles → `.skdt` in `tileFileName` /
  `make_deep_star_tiles.py`; the `NSDT` binary magic is accepted alongside
  the new `SKDT` magic (installed/published tiles keep decoding).
- FITS keywords: `NS-SESID` → `SK-SESID`, `NS-FIDX` → `SK-FIDX`,
  `NS-NPLN` → `SK-NPLN`, `NS-MOSNM` → `SK-MOSNM`, `NS-PIDX` → `SK-PIDX`,
  `NS-PROW` → `SK-PROW`, `NS-PCOL` → `SK-PCOL`, `NS-NPAN` → `SK-NPAN`,
  `NSSTAGE` → `SKSTAGE`, `NSRECIPE` → `SKRECIPE`, `NSRECVER` → `SKRECVER`,
  `NSRECSTP` → `SKRECSTP`, `NSRECIPE-B64` → `SKRECIPE-B64` (HISTORY marker,
  replay accepts both), `NSHA_VER` → `SKHA_VER` (provenance stamp),
  `NS-RIG` → `SK-RIG`.
  DepthLock reads `SK-SESID`/`SK-FIDX` first and falls back to the `NS-*`
  cards so frames captured before the rename keep their identities.
- `.nst` blob magic `NST1` → `SKT1`: `deserialize` accepts `NST1` and `SKT1`;
  `serialize` writes `SKT1`. Applies on both sides of the hub/client codec
  (Rust `sky_atlas.rs` and `server/skotiq_hub` `tile_codec.dart`). The two
  committed Rust-parity fixtures keep their `NST1` bytes as
  `tile_legacy_*.nst` decode fixtures; byte-identical `SKT1` copies were
  regenerated as `tile_a.skt`/`tile_b.skt`.
- `.nsdt` deep-star tile magic `NSDT` → `SKDT` likewise: the decoder accepts
  both, the encoder/generator emit `SKDT`, and the 432 committed synthetic
  fixtures were regenerated deterministically (records verified identical,
  only the magic differs).

### Left unchanged (documented for the reviewer)

- `ns.notif.v1.` secure-storage prefix — the first-launch migration in
  `legacy_install_migration.dart` still reads it; renaming would orphan the
  data it exists to rescue. (Already covered by
  `tools/rebrand/legacy_allowlist.txt`.)
- `~/.cache/ns-rig-data/` — the physical rig-frame cache path on dev
  machines. The test helpers now look under `~/.cache/sk-rig-data` first and
  fall back to `ns-rig-data`, so a fresh checkout uses the new name and an
  existing corpus keeps working. The env override is `SKOTIQ_RIG_DATA`.
- Non-product `ns`: nanoseconds (`as_nanos`, `_ns` durations), XML namespaces
  (`xmlns`, `sabredav.org/ns`), the `nsd` mDNS plugin package, `nside`/
  `nside_for` HEALPix parameters, `NSEW` (INDI directional movement), `APNS`,
  `netns` (Linux network namespaces in `netns_shim.sh`),
  `ENABLE_NS_ASSERTIONS` (Xcode NSAssert setting), `STAR_POSITIONS_PX`,
  `LIBRAW_*` enum members (`LENS_NOT_SET` etc. contain `NS_` substrings),
  `sans-serif`, `design_tokens`, `consequence`, etc.
- Committed binary artifacts whose bytes carry the old vocabulary
  (`.fits` test fixtures with `NS-*` headers, `.db` profile fixtures,
  historical report PNGs/JSONs). The JSON finding dumps under
  `reports/coverage/**` are verbatim evidence of past runs and keep their
  original strings; living docs (tool READMEs, workflow notes, `docs/**`)
  are updated instead.

## Commands run (unpiped)

| Command | Exit |
|---|---|
| `git rev-parse HEAD` | 0 (`b1105ed2eee…`) |
| `python3 tools/rebrand/rebrand.py --check` | 0 (0 leftover) |
| `melos bootstrap > bootstrap.log 2>&1` | 0 |
| `python3 tools/rebrand/abbrev_check.py` | 0 (0 hits) |
| `dart format --output=none --set-exit-if-changed <touched files>` | 0 |
| `cargo fmt --check` (native/skotiq_native) | 0 |
| `dart analyze packages/skotiq_core packages/skotiq_planetarium server/skotiq_hub` | 3 — 0 errors in skotiq_*; hub failed only on missing `pub get` |
| `dart pub get` (server/skotiq_hub) then `dart analyze server/skotiq_hub` | 0 — No issues found |
| `dart analyze server/skotiq_hub packages/skotiq_app packages/skotiq_bridge` | 0 errors (873 pre-existing infos) |
| `flutter test --concurrency=4 test/deep_star_tile_test.dart test/deep_star_store_test.dart test/deep_star_catalog_test.dart test/catalog_partial_sweep_test.dart` (skotiq_planetarium) | 0 (24/24) |
| `flutter test --concurrency=4 test/services/{sequence_file_service,snippet_file_service,sky_atlas_service,constellation_pull_blend,cloud_sync_service,s3_sync_target,webdav_sync_target}_test.dart` (skotiq_core) | 0 (92/92) |
| `flutter test --concurrency=4 test/screens/darkroom/darkroom_editor_wiring_test.dart test/screens/darkroom/darkroom_branch_and_export_test.dart test/screens/settings/backup_import_authority_test.dart test/screens/settings/backup_restore_notice_test.dart test/screens/settings/backup_list_entry_test.dart` (skotiq_app) | 0 (94/94) |
| `CARGO_TARGET_DIR=$HOME/.cache/ns-tmp/w2-abbrev/target cargo test -j 8 --workspace --no-fail-fast` (native/skotiq_native) | 101 — 2 failures total: `fold_then_coverage_then_finalize` (real regression, fixed in `b8f57b033`: `list_tiles_on_disk` still filtered on the old extension — now scans both) and `test_zwo_camera_discovery_no_crash` (known flaky hardware test the brief permits). All other binaries green. |
| `CARGO_TARGET_DIR=… cargo test -p skotiq_bridge api::sky_atlas` (re-run after fix) | 0 (10/10) |
| `melos run analyze` | 0 |
| `melos exec --concurrency=1 --flutter -- flutter test --exclude-tags golden --concurrency=4` | (running — see work log) |
| `dart test test/tile_codec_test.dart` (server/skotiq_hub) | 65 — `dart test` fails to compile its bundled `analyzer-13.3.0` against this Dart SDK (`RecordTypeAnnotation` exhaustiveness). Pre-existing toolchain drift in the hub's dev-dependency closure, unrelated to the rename; the tile codec itself analyzes clean and its Rust twin's tests cover the same codec. |

## Deviations from the brief

- **FITS keywords renamed with dual-read rather than left as established
  formats.** r1's report had deferred the `NS-*`/`ns:` vocabulary as a
  "coordinated cross-area change"; this wave is that coordination point, so
  the write side moved to `SK-*` and every reader accepts the `NS-*` cards
  too. No user file becomes unreadable, and new files carry the new names.
- **`nshub-` generated secrets now read `skhub-`.** The prefix is cosmetic
  (the strength policy never parses it), so existing stored secrets stay
  valid.
- **`~/.cache/ns-rig-data` keeps its name as a fallback.** The helpers look
  under `sk-rig-data` first so fresh checkouts use the new name; an existing
  corpus still resolves.
- **Hub `dart test` not runnable in this environment** (see command table);
  flagged rather than silently skipped.

## Golden tests expected to fail

None — this wave renames identifiers and file-format vocabulary, not pixels.

## Work log

1. Inventoried every `ns`/`NS` family; classified product-vs-non-product
   (nanoseconds, `xmlns`, `nsd`, `netns`, `APNS`, `LIBRAW_*`,
   `ENABLE_NS_ASSERTIONS`, `nside`, `NSEW` left alone).
2. Renamed env vars, temp prefixes, import aliases, hub secret prefix,
   scratch paths (`ns.db`, `/tmp/nswf`, `~/.cache/ns-*`, AVD names) outright.
3. Renamed the persisted/file-format vocabulary with read-compat:
   `.nsdt`/`NSDT`, `.nst`/`NST1`, `.nsrecipe`+`kind`, `.nsmaster`,
   `.nsplugin`, `.nseq.json`, `.nsnippet.json`, `.nsbackup`, `.nsbak`,
   `NS*` FITS keywords, `ns:` frame ids, `NSRECIPE-B64`.
4. Regenerated the deterministic deep-star fixtures (records verified
   identical; only magic differs) and the hub parity tiles (kept the `NST1`
   pair as `tile_legacy_*.nst` decode fixtures).
5. Added legacy-decode coverage: NSDT-magic tile, NST1 fixtures, `NS-SESID`
   identity, `NSRECIPE-B64` HISTORY replay, dual-extension pickers/scans.
6. Wrote `tools/rebrand/abbrev_check.py` (greps the renamed families,
   allowlists the compat code + non-product `ns` meanings); currently clean.
7. Ran the verification ladder above; targeted suites green.
8. The full Rust workspace run surfaced one real regression:
   `list_tiles_on_disk` filtered `path.extension() == "nst"`, so coverage
   never saw the renamed sidecars and `fold_then_coverage_then_finalize`
   failed. Fixed to scan both extensions (`b8f57b033`); the whole
   `api::sky_atlas` module is green on re-run. The only other Rust failure
   was the permitted flaky `test_zwo_camera_discovery_no_crash`.
