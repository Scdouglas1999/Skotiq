//! The simulator backend: the simulated devices' state, their handles, the
//! frames they produce and the faults a test can arm in them.
//!
//! Numeric casts in the device models are bounded by the UI that supplies
//! the value (pulse and exposure durations, focuser steps, filter slots); the
//! simulated flat panel rounds its continuous ramp, clamped to
//! `0..=max_brightness`, before the cast to ASCOM's integer `Brightness`.

use crate::device::*;
use crate::storage::ObserverLocation;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::sync::OnceLock;
use std::time::Instant;
#[cfg(test)]
use tokio::sync::Mutex;
use tokio::sync::RwLock;

pub(crate) mod capture;
pub(crate) mod driver;
pub(crate) mod faults;
pub(crate) mod frame;
pub(crate) mod gate;
pub(crate) mod replay;
pub(crate) mod runaway;
pub(crate) mod sky;

pub(crate) mod camera;
pub(crate) use camera::*;
pub(crate) mod cover_calibrator;
pub(crate) use cover_calibrator::*;
pub(crate) mod environment;
pub(crate) use environment::*;
pub(crate) mod errors;
pub(crate) use errors::*;
pub(crate) mod filter_wheel;
pub(crate) use filter_wheel::*;
pub(crate) mod focuser;
pub(crate) use focuser::*;
pub(crate) mod guiding;
pub(crate) use guiding::*;
pub(crate) mod mount;
pub(crate) use mount::*;
pub(crate) mod rotator;
pub(crate) use rotator::*;
#[cfg(test)]
mod sim_motion_tests;
pub(crate) mod switch;
pub(crate) use switch::*;

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
