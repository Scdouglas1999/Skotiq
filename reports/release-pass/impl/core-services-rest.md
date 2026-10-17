# core-services-rest impl log

Baseline b07d91c9d. No predecessor changes found in scope (git status clean for my files).
graphify query attempted: graph.json absent (hook satisfied).

## Item 1 — DELETE dead legacy dark/flat branch (post_session_integration_service.dart)
- Re-proved: the only production construction site is `postSessionIntegrationServiceProvider`,
  which always passes `calibrationLibrary: ref.watch(calibrationLibraryServiceProvider)` (a
  non-nullable `Provider<CalibrationLibraryService>`). The `if (library != null)` fallthrough was
  reachable only from tests.
- Deleted the legacy `DarkLibraryService.findMatchingDark` / `FlatLibraryService.findBestMatch`
  branch; `calibrationLibrary` is now a required ctor arg and `darkLibrary`/`flatLibrary`/
  `darkTolerances` params + fields are gone (nothing else in the class used them).
- Retargeted every ctor site at the live path: 3 core tests + 2 skotiq_app tests (the app-test
  edits were forced by the required-arg change; they are mechanical arg swaps).
- New regression test: "an unmatched master surfaces the library matcher warning on the outcome
  (no unwarned calibration path exists)" — fails on baseline because the legacy branch built a
  `ResolvedCalibration` with an empty `warnings` list.
- Green: post_session_integration_service_test.dart 24/24; collaborative_mosaic_service_test +
  collaborative_mosaic_poller_test + mosaic_project_service_test 47/47;
  skotiq_app collab_mosaic_publish_refresh_test + mosaic_project_controller_test 25/25.

## Item 2 — BUG: ConstellationClient._download had an unbounded body read + left partial files
- Work-order line ref for the callers was wrong: `pullTile` uses `_send` (already bounded). The
  real `_download` callers are `pullPanelMaster` (:850) and `pullMosaicOutput` (:887); tests target
  those.
- Baseline behaviour proved by temporarily reverting the fix:
  - stall test: hung until the 15 s test timeout (`TimeoutException after 0:00:15`) and had
    already `emitted '/tmp/nst_stall*/community_7.fits'` — an unbounded hang.
  - truncated test: WORSE than reported — a mid-body `SocketException` did not throw at all
    (`Actual: <Instance of 'Future<String>'>`); `_download` returned the out path with a truncated
    file on disk, i.e. a silent success.
- Fix: idle-gap bound (`streamed.stream.timeout(_timeout)`, not a whole-transfer deadline, because
  these artifacts run to gigabytes) + `_closeQuietly`/`_deleteQuietly` on the failure path.
- Tests (new group `large-artifact downloads`): "a hub that sends headers then stalls mid-body
  times out instead of hanging forever, and leaves no partial artifact behind" and "a body that
  fails mid-stream deletes the truncated file". Both fail on baseline, pass on the fix.
- Green: constellation_client_test.dart 20/20.

## Item 3 — BUG: `match` skipped the `_enrich` pass `listMasters` performs
- Confirmed: `match` (:283) used the raw `_loadAll()` rows, so a master flat whose `filter` column
  is null but whose FITS header names it was listed correctly by the UI and invisible to the
  matcher, which then warned "No matching master flat for filter X" about the record on screen.
- Fix: extracted `_enrichAll` (the one answer to "what metadata does this master carry") and ran
  it in `match` before folding remote candidates; `listMasters` now calls the same helper.
- Test: "a flat whose filter lives only in its FITS header is matched, not reported missing while
  the library list shows it" (+ a `_FixedHeaderReader` fake). Reverting just the `_enrichAll` call
  in `match` makes it fail with `Expected: not null / Actual: <null>`.
- Green: calibration_library_service_test.dart + calibration_library_remote_authority_test.dart 18/18.

## Item 4 — BUG: two documented retention sweepers were never scheduled
- Confirmed unwired at baseline: `rg sweepCache` / `rg sweepSwarmBlobs` across packages+apps hit
  only the definitions and their own unit tests.
- Implemented the documented schedule on the schedule that already exists and that both entry
  points (`apps/desktop/lib/main.dart:281`, `main_headless.dart:340`) already await:
  `AutoSaveService` gains a `livingSkyRetentionSweep` hook next to the existing replay-debug
  prune — once via microtask on `start()`, then `Timer.periodic(1 day)`, cancelled in `stop()`,
  overlap-guarded, failures logged not fatal. `autoSaveServiceProvider` supplies the closure
  (`sweepCache()` then `sweepSwarmBlobs()`).
- Doc comments in both sweepers now name their scheduler instead of asserting an unowned one.
- Also took the §4.5 fix that the work order tied to this wiring: `entity.statSync()` inside
  `await for` became `await entity.stat()` in both sweepers.
- Tests: new test/services/living_sky_retention_schedule_test.dart — sweep runs once on start; a
  failing sweep is not fatal; stop cancels the timer; and "the production wiring supplies the
  sweep" reads the real `autoSaveServiceProvider` and asserts the hook is non-null (this one is
  the regression guard — on baseline the field does not exist and the file will not compile).
- Green: living_sky_retention_schedule_test + auto_save_service_replay_retention_test +
  auto_save_status_hydration_test + sky_atlas_service_test + constellation_swarm_scale_test 38/38.

## Item 5 — PERF: whole-DB indented JSON built on the calling isolate
- `createBackup` gained `humanReadable` (default true); `autoSaveBackup()` passes false, so the
  unattended timer-driven archive drops the indentation that roughly doubles both bytes written
  and encode cost.
- The single `JsonEncoder.withIndent(...).convert(backup)` String + `writeAsString` became
  `_writeJsonArchive`: `JsonUtf8Encoder(indent, null, 64 KiB).startChunkedConversion` writing
  64 KiB blocks straight into the temp file's `IOSink` (via a small `_IOSinkBytes` adapter),
  flushed before close. The atomic temp-file-then-rename behaviour is untouched.
- `_dumpTable` now reads in 2000-row pages `ORDER BY rowid` instead of one unpaged `SELECT *`,
  inside the same transaction the caller already opened, so the driver result set stays bounded
  on the per-frame science tables.
- Parity tests (new test/services/backup_service_archive_stream_test.dart):
  "the compact auto-save archive carries exactly the human-readable content" (decoded archives
  equal after normalising the two wall-clock stamps, compact strictly smaller, pretty still
  indented) and "a table larger than one dump page round-trips row-for-row, in order"
  (2500 guide_rms_history rows: exact values, exact order, then a restore into a fresh DB with
  matching count + order).
- Green: all 5 pre-existing backup suites + the new one 34/34; apps/desktop
  headless_api/backup_handlers_test 7/7.

## Item 6 — DEDUP: three copies of the hub join key
- Replaced `ConstellationService._hubKey`, `CoImagingSessionService._hubKey` and
  `SharedCalibrationLibrary.hubKey` (byte-identical, each commented "keep in sync with the other
  two") with one `constellationHubKey(Uri)` in a new leaf library
  lib/src/services/constellation/constellation_hub_key.dart. No file was split; the two private
  copies had no external callers and `SharedCalibrationLibrary.hubKey`'s only caller was inside
  its own class.
- Parity test: test/services/constellation_hub_key_test.dart keeps a verbatim copy of the body it
  replaced and asserts equality across 9 URL shapes (trailing slash, path prefix, explicit and
  default ports, userinfo, query, IPv6), plus "one hub yields one key however its URL was written"
  and "scheme and explicit port stay part of the identity".
- Green: constellation_hub_key_test + coimaging_session_service_test +
  shared_calibration_library_test + the 6 constellation service suites 83/83.

## Item 7 — DELETE: MosaicService.checkVisibilityConstraints / calculateAltitude
- Re-proved fresh across packages/ apps/ native/ tools/ server/ docs/ (excluding graphify-out and
  build): `checkVisibilityConstraints` matched exactly one line — its own definition. No headless
  route, no FRB export, no registry, no string lookup, no test.
- `MosaicService.calculateAltitude` was called only from `checkVisibilityConstraints` (:699). The
  `calculateAltitude` hits in scheduler_service_test.dart are `SchedulerService.calculateAltitude`,
  a different class, and `_calculateAltitudeDegrees` in targets_dao.dart is unrelated.
- Deleted both (~85 lines) and dropped the now-unused `AstronomyCalculations` show-clause from the
  planetarium import (`mosaicPanelCenters` is still used). No test existed for either member, so
  none was deleted.
- Green: mosaic_service_test.dart 45/45; `rg checkVisibilityConstraints` now returns nothing.

## Verification summary
- packages/skotiq_core: `dart analyze lib` clean; `flutter test test/services` 2749 passed
  (4 skipped). `test/providers test/database` 1682 passed with one load flake in
  test/providers/sequence/rules/adaptive_exposure_rules_test.dart (a file outside my scope being
  edited concurrently); it passes 13/13 when run on its own.
- apps/desktop: test/headless_api/backup_handlers_test.dart 7/7 (the `createBackup` signature
  change is source-compatible).
- packages/skotiq_app: the two mosaic/collab test files I had to retarget 25/25.
- `dart format` clean on every file touched. No stray *.tmp.* files in scope.
