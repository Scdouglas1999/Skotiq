# rust-imaging — implementation log

Batch `rust-imaging`. Baseline commit `b07d91c9d`. Scope
`native/skotiq_native/imaging/**`.

## Resume state (start of this session)

A previous attempt left partial work on the tree. `git diff b07d91c9d --
native/skotiq_native/imaging/` showed items 1, 2, 3, 5 and 7 already
applied and items 4 and 6 untouched. This session verified every applied item
against the baseline code (including proving each BUG test fails pre-fix) and
then implemented 4 and 6.

Baseline before any of my edits: `cargo test -p skotiq_imaging` →
**503 + 12 + 6 + 1 pass, 0 fail**.

## Item 1 — DELETE the `#[cfg(test)]`-only internal plate solver

Predecessor's work, re-proved this session.

`platesolve.rs` 3386 → 2488 lines. Re-proved zero callers myself across
`native/ packages/ apps/ tools/` (all extensions, not just `.rs`):

```
grep -rn "FORCE_CPU|GPU_ATTEMPT_TIMEOUT|GPU_PLATE_SOLVE_UNRESPONSIVE|
          solve_internal|extract_plate_stars|gpu_downsample|wgpu|pollster"
```

→ the only surviving hits are three lines in `bridge/src/lib.rs:318-324`, a
`tracing` filter string (`"…,wgpu_core=warn,wgpu_hal=warn,…"`). That is a log
filter, not a caller, and it is outside my scope, so it stays.

`wgpu` and `pollster` are out of `imaging/Cargo.toml` **and** out of
`native/skotiq_native/Cargo.lock` (`grep '^name = "wgpu' Cargo.lock` →
empty). `bytemuck` correctly stays — `lib.rs:568/595/670/696` use it.

The three G20 guards the deleted module existed for
(`SKOTIQ_PLATESOLVE_FORCE_CPU`, `GPU_ATTEMPT_TIMEOUT`,
`GPU_PLATE_SOLVE_UNRESPONSIVE`) are gone with it, and no doc, script or Dart
file mentions them.

## Item 2 — BUG: Debug-stringified FITS header (`lib.rs:842`/`:857`)

**Proved against pre-fix code.** I reverted the two mapping lines to
`format!("{:?}", v)` and ran the two tests:

```
test tests::calibrated_frame_header_carries_numeric_exptime_and_gain ... FAILED
   NAXIS flattened to Rust variant syntax: Integer(2)
test tests::flattened_header_survives_a_plain_set_string_carry_over ... FAILED
   left: Some("String(\"Ha\")")  right: Some("Ha")
```

Both pass with the fix restored. The fix is `FitsValue::to_header_string()`
(+ `XisfProperty::to_header_string`) and `FitsHeader::set_value_token`, which
reads the flattened form back into typed cards.

**Honest limit, and a handoff.** The item asked that EXPTIME/GAIN come out as
*numeric* cards. Inside this scope that is now possible — `set_value_token`
does it, and the test proves the round trip — but the production carry-over at
`bridge/src/api/imaging.rs:4811` still calls `header.set_string(key, value)`,
so a calibrated frame today ships `EXPTIME = '120.0'` (a quoted string) rather
than `EXPTIME = 120.0`. That is a strict improvement over `'Float(120.0)'` and
`get_string` reads it, but `get_float` still does not. The remaining one-line
change (`set_string` → `set_value_token`) is in `bridge/`, outside my scope —
recorded under `blocked` for the rust-bridge batch.

## Item 3 — PERF: `write_fits` block writes

Predecessor's work, reviewed and kept. `write_be_samples::<_, N>` converts in
64 KiB blocks; both 2880-byte padding loops became a single sliced
`write_all`.

Parity is pinned by `tests/write_fits_block_parity.rs` (6 tests), which builds
the expected data section with an *independent* per-sample big-endian
reference and asserts byte equality, plus the header/data padding bytes:

```
u16_data_matches_per_sample_reference           ok
u32_data_matches_per_sample_reference           ok
f32_data_matches_per_sample_reference           ok
f64_data_matches_per_sample_reference           ok
multi_block_image_has_no_seam_at_the_block_boundary ok
trailing_partial_sample_is_dropped              ok
```

## Item 4 — MERGE `combine_master_frames` onto `integrate_frames`

Implemented this session.

**Golden parity test written first**, in a new
`stacking::master_parity_tests` module. `reference_combine` is the deleted
implementation transcribed verbatim (`combine_pixel` / `median_in_place` /
`sigma_clip_in_place`, the per-pixel `Vec<f64>` gather, the flat
normalisation, the U16/F32 finalisation). `every_method_and_kind_matches_the_pre_merge_combiner`
asserts **byte-equal** `image.data` plus bit-equal `input_mean` /
`output_mean` over the full cross product:

- 5 methods (Mean, Median, SigmaClip k=3/i=5, k=1.5/**i=1**, k=2/i=20)
- 3 kinds (Bias, Dark, Flat) × 2 output types (U16, F32)
- 5 frame counts (1, 2, 3, 8, 11) × 2 geometries (7×5 mono, 4×3 RGB)
- both input pixel types (U16 and F32), with injected cosmic-ray spikes

= 1200 combinations, all bit-identical.

Structural changes:

- `integration.rs`: `integrate_frames` now wraps a new `pub(crate)
  integrate_columns`, which returns the raw `f64` master instead of a
  quantised `ImageData`. The master flat must normalise by its own mean
  *before* rounding, so it needs the `f64`.
- `integrate_columns` takes an `iteration_limit`. `integrate_frames` passes
  `Reject::MAX_ITERATIONS` (unchanged behaviour); `combine_master_frames`
  passes the caller's `iterations`, which is part of its public contract. The
  `i=1` case in the parity test is what pins this.
- `combine_column` gained a total-rejection fallback. A threshold tighter than
  1σ can reject an entire column; `integration` used to answer 0.0 (a black
  pixel in the master), `combine_master_frames` answered the median of the
  untouched column. The merged code restores the column and takes the median,
  which is parity for the master path and a defect fix for the integration
  path. `total_rejection_falls_back_to_the_median` covers it (and asserts the
  *reference* also answers 5000.0, so it is parity, not a new invention).
  Total rejection is unreachable for `kappa ≥ 1`: if every sample were more
  than 1σ from the mean then `Σd² > nσ² = n·Σd²/(n−1)`, i.e. `1 > n/(n−1)`.
- The `frames.len() × pixels × 8` `f64` residency is gone: frames are decoded
  a **row band** at a time under a 32 MiB budget (`BAND_BUDGET_BYTES`), so 30
  darks off a 24 MP sensor cost ~32 MB of decoded working set instead of
  5.8 GB. `band_height_does_not_change_the_result` runs every band height from
  1 to 9 rows over a 6×8×3 stack and asserts all match the golden.
- Deleted `combine_pixel`, `median_in_place`, `sigma_clip_in_place` (the
  per-output-pixel heap allocation went with them). No test referenced them.

**One intentional divergence**, documented and tested: a non-finite sample is
now dropped rather than propagated (`integrate_columns` filters non-finite).
A single NaN in one flat used to poison that pixel of the master for every
light it divided. `a_nan_in_one_frame_no_longer_poisons_the_master_pixel`
pins the new answer *and* asserts the reference implementation returns NaN, so
the change is on the record rather than silent.

Also added: an explicit length check per frame. The old code panicked
(`s[i]` out of bounds) on a buffer shorter than its declared geometry; it now
returns a diagnostic `Err`. Buffers *longer* than the geometry are still
accepted and truncated, exactly as before.

Callers left untouched: `calibration_masters.rs:188` and
`bridge/src/api/post_session.rs:1438`.

## Item 5 — PERF: cache solver discovery

Predecessor's work, re-checked this session (their own note was wrong about
it being unfinished). `DISCOVERED_SOLVERS` memoises the ASTAP /
astrometry.net probe; `PlateSolverConfig::default()`, `is_solver_available()`
and `get_solver_path()` all read it; `set_solver_preference` and
`invalidate_solver_availability_cache` drop it; `blind_solve` / `solve_near`
build one config instead of two.

`solver_discovery_is_cached_until_invalidated` proves the cache observably:
it plants a fake solver, resolves it, **deletes the file**, and asserts the
next resolve still answers the same path — then that explicit invalidation
re-probes and stops answering it. A poisoned lock is recovered with
`into_inner()` rather than panicking (the guarded region only clones
`PathBuf`s), so a panic elsewhere cannot end plate solving for the process.

Fixed one stale doc reference the deletion left behind: `platesolve.rs:190`
pointed at `SOLVER_AVAILABLE_CACHE`, which no longer exists.

## Item 6 — DEDUP: one `robust_stats` module

New `src/robust_stats.rs` (`pub(crate)`, 209 lines, registered as a private
`mod` in `lib.rs` so nothing leaks into the barrel).

Exports: `MAD_TO_SIGMA`, `median_sorted`, `median_in_place`,
`median_in_place_par`, `nearest_rank_index`, `percentile_nearest_rank`,
`percentile_floor`, `percentile_interpolated`.

**The three percentile conventions were the point**, and each call site was
mapped to the one it already used:

| Was | Convention | Now |
|---|---|---|
| `sky_atlas.rs:1488` | `round((n−1)·q)` | `percentile_nearest_rank` |
| `difference_image.rs:626` | identical | `percentile_nearest_rank` |
| `background_extraction.rs:1117` | identical, sorts first | sort + `percentile_nearest_rank` |
| `frame_weighting.rs:271` (`u16`) | identical rank | `nearest_rank_index` (stays `u16`, no `f64` widening) |
| `stretch.rs:367` | `(n·q)` truncated — **a different answer** | `percentile_floor` |
| `master_accumulation.rs:864` | linear interpolation | `percentile_interpolated` |

`the_three_percentile_conventions_agree_only_at_the_median` pins the
divergence: over 10 samples at `q = 0.9` they answer 8.0 / 9.0 / 8.1.

Eight medians retired: `stacking.rs` (deleted by item 4),
`calibration_masters.rs:515`, `color_calibration.rs:442`,
`difference_image.rs:849`, `mosaic_stitch.rs:694`,
`background_extraction.rs:1102`, `frame_weighting.rs:257` (→ the parallel
variant), `integration.rs:777`, and `defect_map.rs`'s `sample_median_sorted`.
`defect_map.rs`'s three *`u16`* inline medians are deliberately left: they do
integer arithmetic in the `u16` domain (`(a as u32 + b as u32) / 2`, which
truncates), which is not the `f64` helper's answer.

Ordering is now `total_cmp` everywhere. `mosaic_stitch` and the old
`stacking` median used `partial_cmp`, which reports `Equal` for NaN and is
therefore not a total order — a NaN could leave the slice unsorted and the
"median" arbitrary. For NaN-free input the two agree exactly, so this is
behaviour-preserving on real data and a fix on degenerate data;
`a_nan_sample_sinks_to_the_end_instead_of_corrupting_the_order` pins it.

Five module-local `const MAD_TO_SIGMA: f64 = 1.4826;` (plus `stretch`'s
`MAD_SIGMA_SCALE` and three bare literals) collapsed onto the one constant.

**Not adopted:** the work order's `mad_sigma(sorted, median)`. The six MAD
sites disagree on the median *inside* the MAD — `sky_atlas::estimate_frame_norm`
and `difference_image::residual_background` take it by nearest rank (the upper
centre for an even count), the rest take the mean of the two centres. One
shared helper would have to pick, and picking would move the noise floor of
whichever sites it did not match. That reasoning is recorded as a comment in
`robust_stats.rs` rather than left implicit.

Parity evidence for the dedup: all 8 `robust_stats` unit tests plus the
**506 pre-existing crate tests passing unchanged** — including
`stretch`'s STF tests, `sky_atlas`'s normalisation tests,
`frame_weighting`'s `percentile_u16` / `median_f64` assertions, and
`master_accumulation`'s normalisation tests, i.e. one test per migrated
convention.

## Item 7 — BUG: unify the two FITS geometry parsers

Predecessor's work. **Proved against pre-fix code**: I restored `reader.rs`'s
inline geometry block and ran the new tests:

```
test reader::tests::mapped_reader_rejects_a_4d_cube_like_read_fits_does ... FAILED
   expected Unsupported4DCube, got Ok("Ok")
test reader::tests::mapped_reader_requires_naxis3_for_3d_images ... FAILED
```

Both pass with `geometry_from_header` restored. `read_fits_from_reader` keeps
its documented header-only (`NAXIS = 0`) early return before consulting the
shared function, so that path is unchanged.

## Verification

| Command | Result |
|---|---|
| `cargo test -p skotiq_imaging` | **514 + 12 + 6 + 1 pass, 0 fail** (baseline was 503 + 12 + 6 + 1) |
| `cargo clippy -p skotiq_imaging --all-targets` | clean, 0 warnings |
| `cargo build --workspace` | clean — `bridge` and `sequencer` still compile against the changed crate |
| `rustfmt` | run on every file touched (no repo-wide formatting) |

One flake seen and chased down: `platesolve::tests::explicit_astrometry_choice_does_not_run_available_astap`
failed once during a run that overlapped a compile, then passed 4/4 on
re-runs (including 3 consecutive full-suite runs). It is a wall-clock test —
it sleeps 1.5 s and asserts a killed `sleep 2` child never wrote its marker —
and it exercises no code in this batch.

## Not done / handoff

- `bridge/src/api/imaging.rs:4811` should call `FitsHeader::set_value_token`
  instead of `set_string` so calibrated frames carry genuinely numeric
  EXPTIME/GAIN cards. Outside this batch's scope.
- No file splits were performed (`fits.rs`, `platesolve.rs`, `stacking.rs`
  stay single files) — explicitly excluded by the work order for this wave.
