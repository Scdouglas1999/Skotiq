# D-fix batch: native-fixes

Three Wave D REFUTATIONS. Each was reproduced with a failing test at HEAD that
encodes the refuter's exact counter-input, then fixed.

## 1. REFUTED C1 — frame verdicts reach the counters but not the integration total

Refuter evidence (waveD-result.json, refuted[0]): 3x300 s frames, frame 1
accepted, frames 2-3 rejected -> `captured=3 rejected=2 integration=900.0`.
The Session Report printed "2 of 3 rejected" beside "900 s integrated" on a
night with 300 s of usable data.

Root cause: `SequenceRunStats.recordFrame`
(packages/skotiq_core/lib/src/providers/sequence_stats_provider.dart:140)
credited `integrationSecs` and `FilterStats.integrationSecs` unconditionally
while the counters honoured the verdict. Native has always excluded rejected
exposure time from the integration budget (the `FrameRejected` contract in
native/skotiq_native/sequencer/src/node/progress.rs).

Fix: integration (aggregate and per-filter) is credited only when
`accepted`. Rejected exposure time now falls into `overheadSecs`, which is
what it is.

Tests (adopted from the refuter's counter-input, in the batch's own harness
packages/skotiq_core/test/providers/sequence/sequence_run_frame_verdict_test.dart):
- `rejected exposure time is not credited as integration` — 1 accepted +
  2 rejected 300 s subs; asserts 300.0 aggregate AND 300.0 in the per-filter
  breakdown, with captured=3/rejected=2 unchanged. FAILED at HEAD (900.0).
- `an all-rejected node integrates nothing` — FAILED at HEAD (300.0).
- `the persisted run record carries the accepted-only total` — round-trips
  through `toJson`/`ParsedRunStats.fromJson` and pins
  `overheadSecs == wallClockSecs - 300.0`. FAILED at HEAD (600.0).

Verify: `flutter test test/providers/sequence/` in packages/skotiq_core —
564 passed.

## 2. REFUTED phd2AutoSelectStar — the refusal was RELOCATED into the _phd2 path

Refuter evidence (refuted[1]): the inverted `_nativeBridgeRequired` guard was
removed, but `phd2Connect`'s native branch nulls `_phd2Client` and returns
before line 125, the only assignment; `phd2Disconnect` nulls it again. So on
every build where the native library loads — the shipped desktop/headless
configuration — `phd2AutoSelectStar` threw `Exception('PHD2 not connected')`
on a rig whose PHD2 WAS connected through the Rust client.

Fix: made the call real rather than removing it. Auto-select IS `find_star`:
the Dart client's `autoSelectStar()` sends the `find_star` RPC and discards the
reply; `api_phd2_find_star` (already in the generated API — no FRB regeneration
needed) sends the same RPC and returns the coordinates. The native branch now
calls `gen_api.apiPhd2FindStar()`.

Test: the refuter's proof is a source-path argument (the branch cannot be
driven under `flutter test`, where `_nativeAvailable` is false — which is why
the batch's behavioural test passed on baseline AND fix). So the pin is a
source contract in packages/skotiq_bridge/test/native_guard_contract_test.dart,
in the same style as the existing guard-polarity test:
`every _phd2Client user has a native branch` scans guiding_operations.dart
method by method and fails any method that dereferences `_phd2Client` without
an `if (_nativeAvailable)` branch. At HEAD it reported exactly one offender:

    lib/src/bridge_stub/guiding_operations.dart:523: Future<void> phd2AutoSelectStar() async {

and nothing else — every other PHD2 method already had its native branch.
Green after the fix. The stale claim in the old test's comment ("no
apiPhd2AutoSelectStar ... sole implementation in either mode") was corrected.

Verify: `flutter test` in packages/skotiq_bridge — 124 passed.

## 3. REFUTED SCI-48 — the sparing rule was a string prefix, not a base name

Refuter evidence (refuted[4]): `platesolve.rs:689`
`if !name.to_string_lossy().starts_with(stem) { continue; }` — no separator or
extension boundary. Compiled verbatim into a standalone binary, solving
`M31.fits` deleted `M31_L_0008.fits` (a light the capture pipeline wrote during
the solve) and `M31_session.log`. Reachable on exFAT/FAT32 capture drives and
SMB shares, where `fs::hard_link` fails so the in-place fallback runs while the
camera keeps writing into the swept folder.

Fix: new `is_solve_artifact(name, stem)` requires BOTH an exact base-name match
(`file_stem == stem`) AND an extension in `SOLVER_ARTIFACT_EXTENSIONS`
(axy, corr, ini, match, new, rdls, solved, wcs, xyls — the set ASTAP and
solve-field actually emit). `<stem>-indx.xyls`, the one suffixed form
solve-field produces, is admitted explicitly rather than by loosening the
base-name test.

Tests (native/skotiq_native/imaging/src/platesolve.rs):
- `reclaim_spares_files_that_merely_share_the_stem_as_a_prefix` — the refuter's
  fixture verbatim (M31.fits + M31.ini/.wcs debris + M31_L_0008.fits +
  M31_session.log + M31_dark.ini). FAILED at HEAD on the new light.
- `reclaim_only_touches_known_solver_extensions` — exact base name, unknown
  extension (.txt, .xisf) survives; the full solve-field product set is still
  reclaimed. FAILED at HEAD on the operator note.
The two pre-existing tests the refuter showed were blind (their "another
frame" fixture M42_L_0001.ini shares no prefix) still pass unchanged.

Verify: `cargo test -p skotiq_imaging --lib` — 524 passed, 0 failed.
`cargo fmt --check` and `cargo clippy --all-targets` clean.

## Notes
- No FRB regeneration; no generated files touched; no git writes.
- One full-suite run of skotiq_core showed 8 test FILES failing at
  "loading" — a `flutter pub get` race from concurrent agents, not a
  regression: each passes in isolation and `test/backend/` re-ran 269/269
  green immediately after.
