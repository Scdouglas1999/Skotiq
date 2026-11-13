//! Post-session (offline / batch) image-processing pipeline.
//!
//! The batch-integration pipeline over `skotiq_imaging::{registration,
//! frame_weighting, normalization, integration, master_accumulation,
//! calibration_masters}`.
//!
//! Each entry point takes and returns JSON, so a setting added later (a new
//! rejection algorithm, resampler or drizzle parameter) rides inside the
//! payload and needs no binding regeneration (that needs LLVM + MSVC + WinKit,
//! see `docs/FRB_TROUBLESHOOTING.md`). The entry points are six
//! `String -> Result<String, String>` functions:
//!
//! * [`integrate_session`] — one-shot batch integration → linear FITS master.
//! * [`master_accumulate`] — multi-night accumulating master (create / add /
//!   finalize / info / build / deliver).
//! * [`build_master_flat`] — build a unit-mean master flat from raw flats.
//! * [`save_fits_master`] — re-export an in-memory buffer as a FITS master.
//! * [`build_calibration_master`] — build a dark or bias master from raw frames.
//! * [`post_session_cancel`] — set / read / clear a run's cancellation flag.
//!
//! The pipeline is **stateless per call** (no process-wide singleton): the
//! post-session engine can run in a Dart isolate without clobbering a live
//! stacking session (which *is* a singleton). The one exception is the
//! cancellation registry in [`cancel`], which holds a polled flag per run id and
//! no pipeline state — a synchronous FFI descent has no other way to be stopped.
//! The calls are CPU-bound and synchronous; the Dart side runs them off the UI
//! isolate.

use crate::post_session::report::{report, PassReport};

pub use helpers::{calibrate_with_flat_state, load_optional_flat, FlatMaster};

mod args;
mod calibration_master;
mod calibration_report;
pub(crate) mod cancel;
#[cfg(test)]
mod darkroom_regression_tests;
pub(crate) mod delivery;
pub mod entrypoints;
pub(crate) mod helpers;
mod integrate;
mod master_cards;
pub(crate) mod masters;
mod multi_night;
#[cfg(test)]
mod multi_night_tests;
#[cfg(test)]
mod pass_view_capture_tests;
#[cfg(test)]
mod real_frame_harness_tests;
#[cfg(test)]
mod reference_choice_tests;
mod registration_preview;
pub mod report;
mod spool;
mod telemetry;
#[cfg(test)]
mod tests;
mod uniform_delivery;

// Integration progress events

/// Overall fraction at the *start* of each integration phase. The fraction
/// reported during a phase interpolates from its own entry up to the next
/// phase's entry, so the bar advances smoothly across the whole run.
const FRACTION_CALIBRATE: f32 = 0.0;
const FRACTION_REGISTER: f32 = 0.20;
const FRACTION_WEIGHT: f32 = 0.60;
const FRACTION_NORMALIZE: f32 = 0.62;
const FRACTION_INTEGRATE: f32 = 0.80;
const FRACTION_INTEGRATE_DONE: f32 = 0.92;
const FRACTION_WRITE: f32 = 0.95;
const FRACTION_DONE: f32 = 1.0;

/// Reports the integration's progress, for a progress bar.
///
/// Callers report per phase boundary, and per frame inside the per-frame
/// loops, never per pixel.
fn emit_integration_progress(
    phase: &str,
    fraction: f32,
    frames_done: Option<u32>,
    frames_total: Option<u32>,
) {
    report(PassReport::Progress {
        phase: phase.to_string(),
        fraction: fraction.clamp(0.0, 1.0),
        frames_done,
        frames_total,
    });
}
