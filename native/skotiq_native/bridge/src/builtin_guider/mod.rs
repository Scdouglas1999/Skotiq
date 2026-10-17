//! Built-in multi-star guider.
//!
//! # `as`-cast policy
//!
//! - **Timing nanoseconds u128 → f64** (line 361): wall-clock elapsed in
//!   nanoseconds; f64 holds nanosecond precision for ~104 days of
//!   monotonic elapsed time, far longer than any guiding session.
//! - **u32 image coords → f64** (lines 438, 439, 1142, 1143, 1165, 1166):
//!   exact widening; pixel coordinates are bounded by sensor size.
//! - **Calibration ms u32 → f64** (line 813): exact widening; pulse width
//!   ≤ a few thousand ms in practice.
//! - **Rounded f64 → u32 frame rate** (line 943): bounded by FPS measured
//!   over the calibration window; reasonable values ≤ thousands.
//! - **Crop / sensor i32/u32 box math** (lines 1112-1166): every cast is
//!   either i32 → u32 after explicit `>= 0` clamps (x_start/y_start are
//!   bounded by `max(0)`) or u32 → usize widening for indexing. Per-pixel
//!   index `((y * width + x) * 2) as usize` is bounded by the buffer
//!   length we then `<` -check against `expected_data_len`.
//!
//! Sites with a local `Why:` comment override the module-level reasoning.
//!
//! # `unwrap_or` policy
//!
//! * `unwrap_or(Ordering::Equal)` — required because `f64::partial_cmp`
//!   returns `Option` (NaN handling). Star detection upstream filters NaN
//!   centroids; the fallback only protects the sort from a malformed
//!   `StarMass`/`StarSnr` produced by a misbehaving SDK.
//! * `unwrap_or(0.0)` on selected star SNR/flux — when no star is currently
//!   tracked (between frames, or before lock acquisition), the public
//!   status struct reports `snr = 0.0, star_mass = 0.0`. The UI's "guiding
//!   inactive" badge keys off `selected.is_none()`, not these numbers, so
//!   the zero is a display-only convention.
//! * `unwrap_or(1)` (frame width when image-format probe absent) — falls
//!   through to the post-validation pipeline; 1×1 image immediately fails
//!   star detection with a real `NoStarsDetected` error.
//! * `unwrap_or_default()` on profile-name lookup — guider profile may not
//!   yet exist on first run; empty name flows through to default config.
use crate::api::{get_device_manager, get_state, Phd2StarImage, Phd2Status};
use crate::device::DeviceType;
use crate::error::SkotiqError;
use crate::event::{EventSeverity, GuidingEvent, SystemEvent};
use serde::Serialize;
use skotiq_imaging::{detect_stars_with_stats, DetectedStar, ImageData, StarDetectionConfig};
use std::sync::Arc;
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use tokio::sync::{Mutex, RwLock};
use tokio::task::JoinHandle;

pub(crate) mod calibration;
pub(crate) use calibration::*;
pub(crate) mod config;
pub(crate) use config::*;
pub(crate) mod control;
pub(crate) use control::*;
pub(crate) mod dither;
pub(crate) use dither::*;
pub(crate) mod loop_runner;
pub(crate) use loop_runner::*;
pub(crate) mod metrics;
pub(crate) use metrics::*;
pub(crate) mod state;
pub(crate) use state::*;
#[cfg(test)]
mod tests;
