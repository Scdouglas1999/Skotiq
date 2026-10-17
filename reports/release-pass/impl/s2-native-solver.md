# Stage-2 batch: native-solver (IMG-14 solver-hints half, SCI-48)

Scope: `native/skotiq_native/bridge/src/**` (solver call paths),
`native/skotiq_native/imaging/src/platesolve.rs` (+ tests).

## IMG-14 — solver-hints half (FIXED)

**Root cause at HEAD.** Two solve paths existed in the bridge and only one of
them told the solver anything. `unified_device_ops::plate_solve` gathered the
optics (profile focal length + camera pixel pitch + binning) and stamped them
into the temp FITS it wrote. `api/polar_alignment.rs::write_temp_fits_for_solve`
built a bare `FitsHeader::new()` — no `FOCALLEN`, no `XPIXSZ` — and then called
`api_plate_solve_blind`. ASTAP reads the field scale out of the FITS header, so
every TPPA frame (3 measurement frames + one per iteration of the adjustment
loop, which runs for as long as the operator is turning bolts) was solved with
the solver sweeping for the field of view.

**Failing test first.** `polar_solve_frame_carries_the_field_scale_hints`
(bridge, `api::polar_alignment::polar_run_control_tests`) writes a solve frame
and reads the FITS back. Against HEAD's two-argument signature it failed with
`FOCALLEN: left: None, right: Some(416.0)`.

**Fix.**
- New shared helper in `api/plate_solve.rs`: `SolveHints`
  (`focal_length_mm`, `pixel_size_um`, `binning`) plus
  `gather_solve_hints()` / `gather_solve_hints_for_camera(Option<&str>)`,
  `SolveHints::apply_to_fits_header`, `SolveHints::log_scale`. The gathering
  and the log line moved out of `unified_device_ops::plate_solve` verbatim;
  that path now calls the helper, so there is one implementation.
- `write_temp_fits_for_solve(image, path, &SolveHints)` stamps
  `FOCALLEN`, `PIXSIZE1/2`, `XPIXSZ`/`YPIXSZ` (the binned pitch, same
  convention as `api::imaging` uses for a saved light) and `XBINNING/YBINNING`,
  plus `EXPTIME`. Both polar call sites pass hints gathered once per run.
- Two hazards the naive extraction would have introduced, both closed:
  - the profile's imaging camera is not necessarily the camera polar alignment
    is running through, so polar asks for hints **by its own camera id**
    (`gather_solve_hints_for_camera`). A pitch from the wrong sensor is a
    confidently wrong scale, which is worse than none.
  - the camera has not been switched to the run's binning when the hints are
    read, so polar overrides `binning` with the binning the run was asked for.
    `SolveHints` also implements `Default` by hand — a derived one would give
    binning `(0, 0)` and multiply every pitch to `0.0 um`.

**Deliberately NOT done: a position hint for the polar frames.** Polar
alignment runs before the mount's pointing can be trusted (it is often started
from a park position on a mount that has never been synced). Stamping `RA`/`DEC`
would make ASTAP search around that position instead of blind, and a mount that
is wrong by more than the search radius would turn solves that succeed today
into failures — five of them ends the alignment run. The scale hint has no such
failure mode. `unified_device_ops` continues to pass the caller's `hint_ra` /
`hint_dec` when the caller has them.

**Cross-scope leftover (not mine, Dart):** `PlateSolveService._solveWithAstap`
(`packages/skotiq_core/lib/src/services/plate_solve_service.dart:398`) is a
*second* solver implementation that shells out to `astap` from Dart with
`workingDirectory: File(imagePath).parent.path`. It passes no scale hint and it
writes `.wcs` next to the operator's capture — the Dart twin of both items in
this batch. It is the local fallback used when the backend solve is
unavailable. Out of this batch's scope; worth its own item.

## SCI-48 — ASTAP/solve-field debris beside the user's FITS (FIXED)

**Root cause at HEAD.** External solvers name their output after the file they
are handed and write it into that file's folder. ASTAP writes `<image>.ini` and
`<image>.wcs`; astrometry.net writes `.axy`, `.corr`, `.rdls`, `.solved`,
`.new` and `.wcs` into `--dir`, which was set to `image_path.parent()`. The
ASTAP path removed the two artifacts on three of its return paths but not on
the timeout or non-zero-exit paths; the astrometry path never removed anything,
including on success.

**Failing tests first** (both `imaging`, `platesolve::tests`, unix):
- `astap_leaves_no_debris_in_the_capture_folder` — a fake ASTAP writes its
  `.ini`/`.wcs` and then hangs so the runner kills it. HEAD left
  `["M31_L_0007.ini", "M31_L_0007.wcs"]` in the capture folder.
- `astrometry_leaves_no_debris_in_the_capture_folder` — a fake `solve-field`
  writes its product set and exits 0. HEAD left
  `[".axy", ".corr", ".new", ".rdls", ".solved", ".wcs"]` there, on a
  **successful** solve.

**Fix.** `SolveScratch` in `platesolve.rs`: for each invocation, create a
private directory and **hard link** the frame into it, then hand the solver the
link (ASTAP `-f`, solve-field's input + `--dir`). All artifacts land in the
scratch directory and the whole directory is removed when the solve returns —
success, failure, timeout, or early return. A hard link never copies the frame,
so this costs nothing per solve. Candidate directories in order: the system
temp dir, then a dot-prefixed directory in the image's own folder (guaranteed
same filesystem, so the link cannot fail for `EXDEV`). If neither can be
staged, the solve runs in place as before and the guard reclaims only the files
that (a) appeared during this solve, (b) share the frame's base name and (c)
are files — pinned by `in_place_fallback_reclaims_only_this_solve_s_artifacts`
and `cleanup_keeps_files_that_were_there_before_the_solve`, which prove an
operator's own sidecar and another frame's files survive.

No new solver flags were introduced (an `-o` output-base flag would have risked
a hard failure on an ASTAP build that does not accept it), and the in-solve
`fs::remove_file` calls were removed so cleanup has exactly one owner.

**Test-harness note.** Five tests in this module write an executable fixture
then exec it. Under the parallel test runner a `fork` on another test's thread
inherits the still-open write descriptor and the exec fails with ETXTBSY; the
astrometry test hit it once. They now share `lock_script_fixtures()`.

## Verification

- `cargo test -p skotiq_imaging --lib` — 522 passed, 0 failed.
- `cargo test -p skotiq_bridge --lib` — 550 passed, 0 failed, 4 ignored
  (pre-existing ignores).
- The two new imaging debris tests were run 3x in a row after the fix (stable).
- `cargo check --workspace --all-targets` — clean.
- `cargo clippy -p skotiq_imaging -p skotiq_bridge --lib --all-targets`
  — no warning in any file this batch touched (the two warnings reported are in
  `device_manager/ops/weather.rs` and `sim_capture.rs`, untouched here).
- `rustfmt --check` clean on the four files touched; no repo-wide format run.
- No FRB regeneration: every new item is `pub(crate)`, and the only signature
  change is on a `pub(crate)` function.

Live confirmation on a real solver (ASTAP present, real frames) belongs to
Wave D — no GUI harness or bundle rebuild was run here.

## Files touched

- `native/skotiq_native/imaging/src/platesolve.rs`
- `native/skotiq_native/bridge/src/api/plate_solve.rs`
- `native/skotiq_native/bridge/src/api/polar_alignment.rs`
- `native/skotiq_native/bridge/src/unified_device_ops.rs`
