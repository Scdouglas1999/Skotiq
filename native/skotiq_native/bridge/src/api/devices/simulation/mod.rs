// split from monolithic api.rs
#![allow(unused_imports)]
// Shared imports inherited from the monolithic api.rs.
//
// # `as`-cast policy
//
// Numeric casts in this file are simulator-only device wrappers:
// - **i32 duration_ms → u64 sleep / u32 pulse** (lines 441, 448):
//   simulator-side wrappers; durations are user-supplied milliseconds
//   capped by the same UI as real hardware (typically ≤ ~2000 ms for
//   guide pulses). `as u64` widens; `as u32` is bounded by UI clamp.
// - **i32 step distance → f64 move time** (lines 551, 593): exact widening.
// - **i32 ↔ i32 filter wheel pos** (lines 786, 804): no-op widenings
//   around `Option::map` plumbing.
// - **f64 panel brightness → i32** (`SimulatedCoverCalibrator::brightness`):
//   the simulated panel ramps on a continuous scale but the ASCOM
//   `Brightness` property is an integer, so the reported value is rounded
//   before the cast. The ramp is clamped to `0..=max_brightness`, so the
//   rounded value is always inside `i32`.
use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::error::*;
use crate::event::*;
use crate::filter_matching::find_filter_match;
use crate::state::*;
use crate::storage::{AppSettings, ObserverLocation};
use crate::unified_device_ops::create_unified_device_ops;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use skotiq_imaging::{
    calculate_airmass, validate_fits_header, validate_image, write_fits, BayerPattern,
    DebayerAlgorithm, FitsHeader, ImageData,
};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;
use tokio::sync::RwLock;
// Sibling-module items via the parent's pub use re-exports.
use super::super::*;
use super::*;
use crate::adaptive_polling::ConsecutiveFailureBackoff;
use std::sync::Mutex as StdMutex;

pub mod camera;
pub use camera::*;
mod cover_calibrator;
pub use cover_calibrator::*;
pub mod environment;
pub use environment::*;
mod errors;
pub use errors::*;
pub mod filter_wheel;
pub use filter_wheel::*;
pub mod focuser;
pub use focuser::*;
pub mod guiding;
pub use guiding::*;
pub mod mount;
pub use mount::*;
pub mod rotator;
pub use rotator::*;
#[cfg(test)]
mod sim_motion_tests;
mod switch;
pub use switch::*;

/// Serializes every test that drives the process-global simulator singletons.
///
/// `SIM_CAMERA`, `SIM_MOUNT` and the exposure/slew clocks are one shared
/// instance per process, and cargo runs tests in parallel threads, so without
/// this one test's abort lands in the middle of another's exposure. It is
/// deliberately a SINGLE lock covering all the singletons: the connection-gate
/// tests flip several device types at once, so per-device locks would not
/// actually exclude each other.
#[cfg(test)]
static SIM_SINGLETON_TEST_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

#[cfg(test)]
pub(crate) fn sim_singleton_test_lock() -> &'static Mutex<()> {
    SIM_SINGLETON_TEST_LOCK.get_or_init(|| Mutex::new(()))
}
