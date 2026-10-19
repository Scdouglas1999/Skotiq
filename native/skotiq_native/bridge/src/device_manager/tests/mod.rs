//! Tests for [`crate::device_manager`].
//!
//! An out-of-line test module: `use super::*` still reaches the private items
//! of `device_manager`, so this is the same module it was when it lived at the
//! bottom of `mod.rs`.

use super::*;
#[cfg(windows)]
use crate::ascom_wrapper::mount::test_support::{build_test_mount_wrapper, TestMountResponses};
use crate::state::AppState;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{Mutex, RwLock};

mod guards;
mod heartbeat_config;
mod heartbeat_events;
mod identity;
mod indi_ids;
mod mount_home;
mod mount_ops;
mod mount_set_park;
mod reconnect_state;
mod simulator;
mod switch_ops;

/// The one crate-wide lock over the simulator singletons. It lives next to
/// the singletons themselves so every test module that touches them takes
/// the SAME lock — two independent mutexes over one shared state exclude
/// nothing.
fn simulator_singleton_test_lock() -> &'static Mutex<()> {
    crate::api::devices::simulation::sim_singleton_test_lock()
}

fn build_switch_info(id: &str, driver_type: DriverType) -> DeviceInfo {
    DeviceInfo {
        id: id.to_string(),
        name: "Test Switch".to_string(),
        device_type: DeviceType::Switch,
        driver_type,
        description: "Test switch device".to_string(),
        driver_version: "1.0".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: "Test Switch".to_string(),
    }
}

fn build_mount_info(id: &str, driver_type: DriverType) -> DeviceInfo {
    DeviceInfo {
        id: id.to_string(),
        name: "Test Mount".to_string(),
        device_type: DeviceType::Mount,
        driver_type,
        description: "Test mount device".to_string(),
        driver_version: "1.0".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: "Test Mount".to_string(),
    }
}

fn build_device_manager() -> DeviceManager {
    DeviceManager {
        app_state: AppState::new(),
        devices: RwLock::new(HashMap::new()),
        observed_identities: RwLock::new(HashMap::new()),
        reconnect_config: ReconnectConfig::default(),
        stop_reconnect: Arc::new(RwLock::new(false)),
        native_devices: RwLock::new(HashMap::new()),
        #[cfg(windows)]
        ascom_cameras: RwLock::new(HashMap::new()),
        #[cfg(windows)]
        ascom_mounts: RwLock::new(HashMap::new()),
        #[cfg(windows)]
        ascom_focusers: RwLock::new(HashMap::new()),
        #[cfg(windows)]
        ascom_filter_wheels: RwLock::new(HashMap::new()),
        #[cfg(windows)]
        ascom_rotators: RwLock::new(HashMap::new()),
        #[cfg(windows)]
        ascom_domes: RwLock::new(HashMap::new()),
        #[cfg(windows)]
        ascom_weather: RwLock::new(HashMap::new()),
        #[cfg(windows)]
        ascom_safety_monitors: RwLock::new(HashMap::new()),
        #[cfg(windows)]
        ascom_switches: RwLock::new(HashMap::new()),
        #[cfg(windows)]
        ascom_cover_calibrators: RwLock::new(HashMap::new()),
        indi_clients: RwLock::new(HashMap::new()),
        alpaca_cameras: RwLock::new(HashMap::new()),
        alpaca_mounts: RwLock::new(HashMap::new()),
        alpaca_focusers: RwLock::new(HashMap::new()),
        alpaca_filter_wheels: RwLock::new(HashMap::new()),
        alpaca_rotators: RwLock::new(HashMap::new()),
        alpaca_domes: RwLock::new(HashMap::new()),
        alpaca_weather: RwLock::new(HashMap::new()),
        alpaca_safety_monitors: RwLock::new(HashMap::new()),
        alpaca_switches: RwLock::new(HashMap::new()),
        alpaca_cover_calibrators: RwLock::new(HashMap::new()),
        native_cameras: RwLock::new(HashMap::new()),
        native_focusers: RwLock::new(HashMap::new()),
        native_filter_wheels: RwLock::new(HashMap::new()),
        native_mounts: RwLock::new(HashMap::new()),
        heartbeat_tasks: RwLock::new(HashMap::new()),
        reconnect_cancel_tokens: RwLock::new(HashMap::new()),
        active_operations: Arc::new(std::sync::Mutex::new(std::collections::HashSet::new())),
        usb_contention: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
    }
}

// Device identity: a positional id must not silently re-bind

/// A connected vendor-SDK device whose reported identity the test controls.
///
/// Stands in for the real thing behind `native:zwo:{n}`: on the reference
/// rig that id is an ASI enumeration index, so replugging swapped
/// `native:zwo:1` from the ASI1600MM-Cool to the ASI178MM while the id, the
/// displayed name and the cached capabilities all stayed put.
#[derive(Debug)]
struct FakeIdentityDevice {
    id: String,
    model: String,
    serial: Option<String>,
}

#[async_trait::async_trait]
impl skotiq_native::traits::NativeDevice for FakeIdentityDevice {
    fn id(&self) -> &str {
        &self.id
    }
    fn name(&self) -> &str {
        &self.model
    }
    fn vendor(&self) -> skotiq_native::NativeVendor {
        skotiq_native::NativeVendor::Zwo
    }
    fn serial_number(&self) -> Option<String> {
        self.serial.clone()
    }
    fn is_connected(&self) -> bool {
        true
    }
    async fn connect(&mut self) -> Result<(), skotiq_native::traits::NativeError> {
        Ok(())
    }
    async fn disconnect(&mut self) -> Result<(), skotiq_native::traits::NativeError> {
        Ok(())
    }
}

fn build_identity_camera_info() -> DeviceInfo {
    DeviceInfo {
        id: "sim_camera_1".to_string(),
        // The placeholder `device_info_from_id` derives from the id string:
        // it knows the vendor token and the index, and nothing else.
        name: "ZWO 1".to_string(),
        device_type: DeviceType::Camera,
        driver_type: DriverType::Simulator,
        description: "Native zwo driver".to_string(),
        driver_version: "Native".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: "ZWO 1".to_string(),
    }
}

async fn install_fake_device(manager: &DeviceManager, id: &str, model: &str, serial: Option<&str>) {
    manager.native_devices.write().await.insert(
        id.to_string(),
        Box::new(FakeIdentityDevice {
            id: id.to_string(),
            model: model.to_string(),
            serial: serial.map(|s| s.to_string()),
        }),
    );
}

// `connect_simulator` / `disconnect_simulator` must flip the matching
// `simulation.rs` singleton's `connected` flag, and the heartbeat path for
// `DriverType::Simulator` must read that flag rather than report healthy
// unconditionally — otherwise a "connected" simulator has no driver state
// behind it.
//
// Tests use distinct device_type prefixes to avoid cross-test interference
// through the process-wide simulation.rs singletons.
fn build_sim_info(id: &str, device_type: DeviceType) -> DeviceInfo {
    DeviceInfo {
        id: id.to_string(),
        name: format!("Simulated {}", device_type.as_str()),
        device_type,
        driver_type: DriverType::Simulator,
        description: "Simulator under test".to_string(),
        driver_version: "1.0".to_string(),
        serial_number: None,
        unique_id: None,
        display_name: format!("Simulated {}", device_type.as_str()),
    }
}
