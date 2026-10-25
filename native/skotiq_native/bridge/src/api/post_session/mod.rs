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

use serde::{Deserialize, Serialize};
use skotiq_imaging::calibration_masters::{
    build_master_flat, cosmetic_correct_transient, CosmeticConfig, MasterFlatConfig,
};
use skotiq_imaging::frame_weighting::{
    accumulation_weights, analyze_frame_quality, weight_frames, CullPolicy, FrameQuality,
    FrameQualityConfig, WeightFormula,
};
use skotiq_imaging::integration::{
    integrate_frames, Combine, IntegrationConfig, IntegrationFrame, Reject,
};
use skotiq_imaging::master_accumulation::{
    AccumulationMode, IntegratedMaster, MasterCreateConfig, OnlineClip,
};
use skotiq_imaging::normalization::{
    apply_normalization, estimate_normalization, CoverageMask, NormMode, NormalizationConfig,
};
use skotiq_imaging::registration::{
    min_registration_stars, register_frame, registrable_star_count, Interpolator,
    RegistrationConfig, TransformKind, TransformModel,
};
use skotiq_imaging::stacking::{CombineMethod, MasterOutputType};
use skotiq_imaging::{
    add_wcs_headers, apply_stretch, apply_stretch_rgb_per_channel, auto_stretch_rgb_with_mode,
    auto_stretch_stf, read_fits, read_fits_header, read_image, write_fits, FitsHeader, ImageData,
    PixelType, RgbStretchMode, WcsInfo,
};
use std::path::Path;

use crate::api::get_state;
use crate::event::{EventSeverity, ImagingEvent};

mod args;
pub(crate) use args::*;
mod calibration_master;
pub(crate) use calibration_master::*;
mod calibration_report;
pub(crate) use calibration_report::*;
mod cancel;
pub(crate) use cancel::*;
pub mod entrypoints;
pub use entrypoints::*;
mod helpers;
pub(crate) use helpers::*;
mod integrate;
pub(crate) use integrate::*;
mod masters;
pub(crate) use masters::*;
mod master_cards;
pub(crate) use master_cards::*;
mod multi_night;
pub(crate) use multi_night::*;
mod delivery;
mod spool;
mod uniform_delivery;
pub(crate) use delivery::*;
mod telemetry;
pub(crate) use telemetry::*;
#[cfg(test)]
mod darkroom_regression_tests;
#[cfg(test)]
mod multi_night_tests;
#[cfg(test)]
mod pass_view_capture_tests;
#[cfg(test)]
mod real_frame_harness_tests;
#[cfg(test)]
mod reference_choice_tests;
#[cfg(test)]
mod tests;

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
