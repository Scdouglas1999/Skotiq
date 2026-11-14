//! The simulator backend: the simulated devices' state, their handles, the
//! frames they produce and the faults a test can arm in them.
//!
//! Numeric casts in the device models are bounded by the UI that supplies
//! the value (pulse and exposure durations, focuser steps, filter slots); the
//! simulated flat panel rounds its continuous ramp, clamped to
//! `0..=max_brightness`, before the cast to ASCOM's integer `Brightness`.

#[cfg(test)]
use std::sync::OnceLock;
#[cfg(test)]
use tokio::sync::Mutex;

pub(crate) mod capabilities;
pub(crate) mod capture;
pub(crate) mod driver;
pub(crate) mod faults;
pub(crate) mod frame;
pub(crate) mod gate;
pub(crate) mod replay;
pub(crate) mod runaway;
pub(crate) mod sky;

pub(crate) mod camera;
pub(crate) mod cover_calibrator;
pub(crate) mod environment;
pub(crate) mod errors;
pub(crate) mod filter_wheel;
pub(crate) mod focuser;
pub(crate) mod guiding;
pub(crate) mod mount;
pub(crate) mod rotator;
#[cfg(test)]
mod sim_motion_tests;
pub(crate) mod switch;

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

/// Registers a simulated device and connects it the way the app does, so
/// it has a handle.
#[cfg(test)]
pub(crate) async fn register_connected(
    manager: &crate::device_manager::DeviceManager,
    info: crate::device::DeviceInfo,
) {
    manager
        .connect_simulator(&info)
        .await
        .expect("simulator connects");
    manager.register_device(info, false).await;
}
