//! Post-session (offline / batch) image-processing FFI surface.
//!
//! This module exposes the committed native batch-integration pipeline
//! (`skotiq_imaging::{registration, frame_weighting, normalization,
//! integration, master_accumulation, calibration_masters}`) to Dart through a
//! **minimal, JSON-in / JSON-out** boundary.
//!
//! Why JSON and not typed FFI structs: regenerating `flutter_rust_bridge`
//! bindings is heavyweight (needs LLVM + MSVC + WinKit, see
//! `docs/FRB_TROUBLESHOOTING.md`). Every knob added later — new rejection
//! algorithm, new resampler, drizzle params — then rides inside the JSON payload
//! and never triggers another regen. This is the same trick the live stacker
//! uses for node config (per project memory). The boundary is exactly six
//! `String -> Result<String, String>` functions:
//!
//! * [`api_integrate_session`] — one-shot batch integration → linear FITS master.
//! * [`api_master_accumulate`] — multi-night accumulating master (create / add /
//!   finalize / info / build / deliver).
//! * [`api_build_master_flat`] — build a unit-mean master flat from raw flats.
//! * [`api_save_fits_master`] — re-export an in-memory buffer as a FITS master.
//! * [`api_build_calibration_master`] — build a dark or bias master from raw frames.
//! * [`api_post_session_cancel`] — set / read / clear a run's cancellation flag.
//!
//! The pipeline is **stateless per call** (no process-wide singleton): the
//! post-session engine can run in a Dart isolate without clobbering a live
//! stacking session (which *is* a singleton). The one exception is the
//! cancellation registry in [`cancel`], which holds a polled flag per run id and
//! no pipeline state — a synchronous FFI descent has no other way to be stopped.
//! The calls are CPU-bound and synchronous; the Dart side runs them off the UI
//! isolate.

use crate::event::equipment::EventSeverity;
use crate::event::imaging::ImagingEvent;
use crate::state::get_state;

mod args;
mod calibration_master;
mod calibration_report;
pub(crate) mod cancel;
#[cfg(test)]
mod darkroom_regression_tests;
mod delivery;
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

/// Publish a single [`ImagingEvent::IntegrationProgress`] on the global event
/// bus so Dart can drive a progress bar for the offline integration pipeline.
///
/// Cheap by construction: it only clones a short phase string and touches the
/// `Arc<EventBus>` broadcast sender (non-blocking, no-ops with no receivers).
/// [`api_integrate_session`] runs on FRB's `wrap_normal` worker thread (not the
/// Dart UI isolate), so emitting from inside the orchestration loops is safe.
/// Callers must emit per *phase boundary* (and per *frame* inside the register
/// loop) — never per pixel.
fn emit_integration_progress(
    phase: &str,
    fraction: f32,
    frames_done: Option<u32>,
    frames_total: Option<u32>,
) {
    get_state().publish_imaging_event(
        ImagingEvent::IntegrationProgress {
            phase: phase.to_string(),
            fraction: fraction.clamp(0.0, 1.0),
            frames_done,
            frames_total,
        },
        EventSeverity::Info,
    );
}
