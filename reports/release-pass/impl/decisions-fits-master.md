# Batch fits-master — owner decision 8: the stacked master saves as FITS

Branch worktree: `.claude/worktrees/wf_9953116a-7f8-6` (rebased onto the campaign
head `b7e8f77f5`; the worktree was created off `main` at `59dec49c7` — see
"Wave hazards" below). Nothing committed.

## The decision

> **Stacked master**: EXTEND the FITS writer (EXPTIME/DATE-OBS optional or
> synthesized from stack metadata); the master saves as FITS.

Origin: Wave D `SCI-28` residual / `ND-6` — Stop → "Save master" → typing
`stack_master.fits` wrote `stack_master.png` (later: refused outright), because
the live stacker has no per-frame header to build a FITS header from.

## What the writer actually demanded

`write_fits` never demanded `EXPTIME` / `DATE-OBS` — `validate_fits_header` only
requires `SIMPLE/BITPIX/NAXIS*`. The demand lived one layer up: every FITS save
path took a *per-frame* header struct (`FitsWriteHeader.exposure_time`,
`.capture_timestamp` — both non-optional), and the live stacker has neither: an
in-memory frame is a raw `u16` buffer with no keywords at all. So the fix is a
stack-shaped header, not a relaxed writer.

## Implementation

**`imaging/src/stack_master.rs` (new)** — the master's provenance and writer.

* `FrameProvenance { exposure_secs: Option<f64>, date_obs: Option<String> }` —
  what a frame's own header said, `None` meaning *unknown*, never zero.
  `from_header_map` reads the two keywords out of the flattened header
  `read_image` already returns.
* `StackProvenance` — folded across the frames the stacker *accepted*: frame
  count, Σ integration, count of frames that reported an exposure, earliest
  parseable `DATE-OBS` (compared in UTC, so an offset stamp sorts correctly),
  first unparseable stamp, and the stack's start instant.
* `to_fits_header()` synthesizes:
  * `EXPTIME` = Σ of the exposures the stacked frames reported, with the card
    comment disclosing the basis — `total integration of N stacked frames` /
    `integration of K of N stacked frames` / `no stacked frame reported
    EXPTIME`. An unknown exposure contributes **nothing** (the convention
    `master_accumulation::MasterMetadata` already uses), so a headerless stack
    reads `EXPTIME = 0.0` *with a comment saying the integration is unknown*
    rather than a fabricated number.
  * `DATE-OBS` = earliest stacked frame's stamp; failing that the raw stamp a
    frame reported in an unrecognised form; failing that the moment the stack
    started, each with its own disclosing comment.
  * plus `NFRAMES`, and the `IMAGETYP/FRAMETYP/CALSTAT` identification the
    post-session masters use (`api/post_session/masters.rs`).
* `write_stack_master(path, image, provenance)` — creates the parent dir and
  writes through `write_fits`.

**`imaging/src/stacking.rs`** — `LiveStacker` carries a `StackProvenance`.
`new_with_provenance` / `add_frame_with_provenance` take the frame's header;
the existing `new` / `add_frame` delegate with `FrameProvenance::unknown()`, so
no caller changed behaviour. Only frames that are actually stacked fold in — a
frame rejected for alignment contributes no pixels, so it contributes no
integration. `reset()` starts a fresh provenance because it drops every
accumulated pixel.

**`bridge/src/stacking_api.rs`** — `stacking_start` / `stacking_add_frame` (the
file-path ingest, which is what the sequencer auto-feed uses) harvest
`EXPTIME`/`DATE-OBS` from each frame's header, so the realistic path reports a
*real* total integration. New `stacking_save_master_fits(file_path)` writes the
accumulated master and returns path / frames / integration / `DATE-OBS`.

**`bridge/src/api/imaging.rs`** — `api_stacking_save_master_fits` (async, write
on `spawn_blocking` like the other FITS writers) + `ApiLiveStackingMaster`.
FRB regenerated with the pinned 2.11.1 codegen (`CC=clang CPATH=…`, per
`scripts/dev.sh`); the generated diff is purely additive.

**Dart (`live_stacking_service.dart`, `stacking_panel.dart`)** — `saveMaster`
routes by extension: `.fits/.fit/.fts` (and *no* extension) → the native FITS
master; `.png` → the existing render (the UI preview export, kept); anything
else → `LiveStackingMasterFormatUnsupported`, which now carries a `reason` so
the dialog can say *why*. The suggested destination is now
`live_stack_…_Nframes.fits`, the Stop prompt names the FITS master, and the
confirmation states the integration the header carries.

Remote clients: the stack accumulates on the imaging host and only its pixels
come over the wire, so a client asking for FITS is refused with that reason
(PNG still works remotely, unchanged). A host-side `/api/stacking/save-master`
route does not exist — noted as owed, not silently faked.

## Tests (failing first, then green)

| Suite | Verdict |
| --- | --- |
| `cargo test -p skotiq_imaging` (incl. new `tests/stack_master_fits.rs`) | 538 + 12 + 4 + 6 + 1 doc passed, 0 failed |
| `cargo test -p skotiq_bridge --lib stacking_api` | 16 passed (2 new) |
| `flutter test test/services/live_stacking_master_format_test.dart` etc. (skotiq_core) | 40 passed |
| `flutter test test/screens/imaging/` (skotiq_app) | 243 passed |
| `cargo fmt --all` | clean |
| `cargo clippy -p skotiq_imaging / -p skotiq_bridge --all-targets` | no new warnings (the 3 doc-overindent + 3 bridge lints are pre-existing, in `platesolve.rs` / `plate_solve.rs` / `weather.rs` / `sim_capture.rs`) |
| `flutter analyze` (core, app, bridge) | no errors |

The first Rust test written was `headerless_stack_still_writes_exptime_and_date_obs`
(failed to compile — no `stack_master` module); the first Dart one was
`a .fits destination is written as FITS, not rewritten to PNG` (failed: no
`saveFitsMaster` seam, no `fitsMaster` format).

## Wave hazards found while doing this (NOT fixed here)

1. **`.gitignore:276 profiles/` swallows source directories.**
   `packages/skotiq_core/lib/src/providers/profiles/{equipment_profile_model,
   equipment_profiles_notifier,profile_derived_providers}.dart` are **untracked**
   — they exist only in the main checkout. Every fresh worktree (and every fresh
   clone) fails to compile `skotiq_core`. I copied them in locally to run the
   Dart tests; they are still ignored, so they are not in my diff. The rule needs
   narrowing (or a `!` negation for `lib/**/profiles/`) and the three files need
   committing by whoever owns that split.
2. **Worktrees created off `main`.** This worktree (and `-3`, `-4`, `-5` by
   `git worktree list`) started at `59dec49c7` = `main`, not the campaign head
   `b7e8f77f5`. I reset mine before touching anything; the sibling batches should
   check theirs or their diffs will be against the wrong base.

## Owed / not verified here

* On-rig: save a real live stack as FITS and open the master in ASTAP/PixInsight.
* OSC (3-channel) masters go through `write_fits` with `NAXIS3=3` and the
  codebase's interleaved `ImageData` layout — the same path the post-session
  masters already use. Whether a third-party reader interprets that as planar is
  a **pre-existing** question for the shared writer, not something this batch
  introduced; worth a one-file check on the rig.
* A host-side save-master route for remote clients (`/api/stacking/save-master`).
