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

/// Serializes every test that drives the process-global rig: the simulator
/// singletons, the device registry and the guider (the PHD2 client slot and
/// the stop reason).
///
/// `SIM_CAMERA`, `SIM_MOUNT` and the exposure/slew clocks are one shared
/// instance per process, and cargo runs tests in parallel threads, so without
/// this one test's abort lands in the middle of another's exposure. It is
/// deliberately a SINGLE lock covering all of it: the connection-gate tests
/// flip several device types at once, and a sequence's slew stops whatever
/// guider is connected, so a guider test must not run beside a slewing one.
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

/// The simulator a type's discovery offers first: its id and the name every
/// screen shows for it.
pub(crate) fn listed_simulator(
    device_type: crate::device::DeviceType,
) -> Option<(&'static str, &'static str)> {
    use crate::device::DeviceType;
    Some(match device_type {
        DeviceType::Camera if camera::sim_imaging_camera_is_dslr() => {
            (camera::SIM_IMAGING_CAMERA_ID, camera::SIM_DSLR_NAME)
        }
        DeviceType::Camera => (camera::SIM_IMAGING_CAMERA_ID, "Simulated Camera"),
        DeviceType::Mount => ("sim_mount_1", "Simulated Mount"),
        DeviceType::Focuser => ("sim_focuser_1", "Simulated Focuser"),
        DeviceType::FilterWheel => ("sim_filterwheel_1", "Simulated Filter Wheel"),
        DeviceType::Rotator => ("sim_rotator_1", "Simulated Rotator"),
        DeviceType::Dome => ("sim_dome_1", "Simulated Dome"),
        DeviceType::Weather => ("sim_weather_1", "Simulated Weather Station"),
        DeviceType::SafetyMonitor => ("sim_safety_monitor_1", "Simulated Safety Monitor"),
        DeviceType::Switch => ("sim_switch_1", "Simulated Power Switch"),
        DeviceType::CoverCalibrator => ("sim_cover_calibrator_1", "Simulated Flat Panel"),
        _ => return None,
    })
}
