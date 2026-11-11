// split from monolithic api.rs
#![allow(unused_imports)]
// Shared imports inherited from the monolithic api.rs.
use crate::device::*;
use crate::device_id::{parse_device_id_cached, ConnectionInfo};
use crate::device_manager::DeviceManager;
use crate::error::*;
use crate::event::*;
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
use super::*;

/// Try to construct a DeviceInfo from a device ID string without running discovery.
/// This avoids opening/closing hardware (e.g. ZWO EFW) which can interfere with
/// subsequent position reads.
pub(crate) fn device_info_from_id(device_id: &str, device_type: DeviceType) -> Option<DeviceInfo> {
    let parsed = parse_device_id_cached(device_id).ok()?;
    match parsed.connection_info {
        ConnectionInfo::Native {
            vendor,
            device_id: native_device_id,
            vendor_brand,
            device_subtype,
            ..
        } => {
            let name = native_display_name(
                &vendor,
                vendor_brand.as_deref(),
                device_subtype.as_deref(),
                &native_device_id,
            );
            Some(DeviceInfo {
                id: device_id.to_string(),
                name: name.clone(),
                device_type,
                driver_type: DriverType::Native,
                description: format!("Native {} driver", vendor),
                driver_version: "Native".to_string(),
                serial_number: None,
                unique_id: None,
                display_name: name,
            })
        }
        ConnectionInfo::Ascom { prog_id } => {
            let name = prog_id.split('.').skip(1).collect::<Vec<_>>().join(" ");
            let name = if name.is_empty() {
                prog_id.clone()
            } else {
                name
            };
            Some(DeviceInfo {
                id: device_id.to_string(),
                name: name.clone(),
                device_type,
                driver_type: DriverType::Ascom,
                description: format!("ASCOM driver: {}", prog_id),
                driver_version: "ASCOM".to_string(),
                serial_number: None,
                unique_id: None,
                display_name: name,
            })
        }
        ConnectionInfo::Alpaca {
            host,
            port,
            device_type: alpaca_type,
            device_num,
            ..
        } => {
            let name = format!("Alpaca {} {}", alpaca_type, device_num);
            Some(DeviceInfo {
                id: device_id.to_string(),
                name: name.clone(),
                device_type,
                driver_type: DriverType::Alpaca,
                description: format!("Alpaca device on {}:{}", host, port),
                driver_version: "Alpaca".to_string(),
                serial_number: None,
                unique_id: None,
                display_name: name,
            })
        }
        ConnectionInfo::Indi { device_name, .. } => Some(DeviceInfo {
            id: device_id.to_string(),
            name: device_name.clone(),
            device_type,
            driver_type: DriverType::Indi,
            description: "INDI device".to_string(),
            driver_version: "INDI".to_string(),
            serial_number: None,
            unique_id: None,
            display_name: device_name,
        }),
        ConnectionInfo::Simulator {
            device_type: simulator_type,
            instance,
        } => {
            let name = crate::api::discovery::simulator_display_name(device_id, device_type)
                .unwrap_or_else(|| format!("Simulator {} {}", simulator_type, instance));
            Some(DeviceInfo {
                id: device_id.to_string(),
                name: name.clone(),
                device_type,
                driver_type: DriverType::Simulator,
                description: "Simulator device".to_string(),
                driver_version: "Simulator".to_string(),
                serial_number: None,
                unique_id: None,
                display_name: name,
            })
        }
    }
}

fn native_display_name(
    vendor: &str,
    vendor_brand: Option<&str>,
    device_subtype: Option<&str>,
    native_device_id: &str,
) -> String {
    if vendor == "builtin_guider" {
        return "Built-in Multi-Star Guider".to_string();
    }

    let vendor_label = match vendor {
        "zwo" | "zwo_eaf" | "zwo_efw" => "ZWO",
        "qhy" | "qhy_cfw" => "QHY",
        "fli" | "fli_fw" | "fli_focuser" => "FLI",
        "player_one" | "playerone" => "Player One",
        "svbony" => "SVBony",
        "atik" => "Atik",
        "moravian" => "Moravian",
        "touptek" => "Touptek",
        "starlightxpress" => "Starlight Xpress",
        "fujifilm" => "Fujifilm",
        "gphoto2" => "gPhoto2",
        "skywatcher" => "Sky-Watcher",
        "ioptron" => "iOptron",
        "lx200" => "LX200",
        "10micron" => "10Micron",
        "ascom" => "Native ASCOM",
        other => other,
    };

    let subtype_label = match (vendor, device_subtype) {
        ("zwo", Some("eaf")) | ("zwo_eaf", _) => Some("EAF"),
        ("zwo", Some("efw")) | ("zwo_efw", _) => Some("EFW"),
        ("qhy", Some("cfw")) | ("qhy_cfw", _) => Some("CFW"),
        ("fli", Some("focuser")) | ("fli_focuser", _) => Some("Focuser"),
        ("fli", Some("fw")) | ("fli_fw", _) => Some("Filter Wheel"),
        _ => None,
    };

    let brand = vendor_brand.filter(|brand| !brand.is_empty());
    match (brand, subtype_label) {
        (Some(brand), Some(subtype)) => {
            format!(
                "{} {} {} {}",
                vendor_label, brand, subtype, native_device_id
            )
        }
        (Some(brand), None) => format!("{} {} {}", vendor_label, brand, native_device_id),
        (None, Some(subtype)) => format!("{} {} {}", vendor_label, subtype, native_device_id),
        (None, None) => format!("{} {}", vendor_label, native_device_id),
    }
}

/// Connect to a device
pub async fn api_connect_device(
    device_type: DeviceType,
    device_id: String,
) -> Result<(), SkotiqError> {
    connect_device_expecting(device_type, device_id, None).await
}

/// Connect to a device, naming the model expected at the id (the profile's
/// saved device name, or the one the user picked). A device that answers as
/// another model is refused, whatever answered at the id before. See
/// `DeviceManager::connect_device_expecting`.
pub async fn api_connect_device_expecting(
    device_type: DeviceType,
    device_id: String,
    expected_model: Option<String>,
) -> Result<(), SkotiqError> {
    connect_device_expecting(device_type, device_id, expected_model).await
}

async fn connect_device_expecting(
    device_type: DeviceType,
    device_id: String,
    expected_model: Option<String>,
) -> Result<(), SkotiqError> {
    tracing::info!(
        "Connecting to {} device: {}",
        device_type.as_str(),
        device_id
    );

    // Special handling for PHD2 auto-launch
    if is_phd2_device_id(&device_id) {
        if !skotiq_imaging::is_phd2_running() {
            tracing::info!("PHD2 not running, attempting to launch...");
            if let Err(e) = skotiq_imaging::launch_phd2() {
                tracing::error!("Failed to launch PHD2: {}", e);
                return Err(SkotiqError::connection_failed(
                    &device_id,
                    format!("Failed to launch PHD2: {}", e),
                ));
            }

            // Wait for it to start
            tracing::info!("Waiting for PHD2 to start...");
            let mut started = false;
            for _ in 0..20 {
                // Wait up to 10 seconds
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                if skotiq_imaging::is_phd2_running() {
                    started = true;
                    break;
                }
            }

            if !started {
                return Err(SkotiqError::connection_failed(
                    &device_id,
                    "Timed out waiting for PHD2 to start",
                ));
            }
        }
    }

    // Check if device is registered in DeviceManager, if not, discover and register it
    let device_manager = get_device_manager();

    // Check if device is already registered
    let is_registered = device_manager.is_device_registered(&device_id).await;

    // If not registered, register it so the DeviceManager can connect.
    // Try to construct DeviceInfo from the device ID first (avoids running
    // native discovery which opens/closes hardware and can interfere with
    // subsequent position reads on filter wheels).
    if !is_registered {
        tracing::info!("Device {} not registered, registering...", device_id);

        let device_info = device_info_from_id(&device_id, device_type.clone());
        if let Some(info) = device_info {
            device_manager.register_device(info.clone(), false).await;
            tracing::info!("Registered device from ID: {} ({})", info.name, device_id);
        } else {
            // Fallback: run full discovery to find the device
            tracing::info!(
                "Could not construct DeviceInfo from ID, running discovery for {}",
                device_id
            );
            let discovered_devices = api_discover_devices(device_type.clone()).await?;
            if let Some(info) = discovered_devices.iter().find(|d| d.id == device_id) {
                device_manager.register_device(info.clone(), false).await;
                tracing::info!(
                    "Registered device via discovery: {} ({})",
                    info.name,
                    device_id
                );
            } else {
                return Err(SkotiqError::connection_failed(
                    &device_id,
                    "Device not found during discovery",
                ));
            }
        }
    }

    // Use the DeviceManager to handle the connection
    device_manager
        .connect_device_expecting(&device_id, expected_model.as_deref())
        .await
        .map_err(|e| SkotiqError::connection_failed(&device_id, e))
}

pub(crate) fn is_phd2_device_id(device_id: &str) -> bool {
    device_id == crate::api::phd2::PHD2_DEVICE_ID
        || device_id == "phd2"
        || device_id.starts_with("phd2:")
        || device_id.starts_with("phd2://")
}

/// Disconnect from a device
pub async fn api_disconnect_device(
    device_type: DeviceType,
    device_id: String,
) -> Result<(), SkotiqError> {
    tracing::info!(
        "Disconnecting from {} device: {}",
        device_type.as_str(),
        device_id
    );

    // Use the DeviceManager to handle disconnection
    get_device_manager()
        .disconnect_device(&device_id)
        .await
        .map_err(|e| SkotiqError::OperationFailed(e))
}

/// Check if a device is connected
pub async fn api_is_device_connected(device_type: DeviceType, device_id: String) -> bool {
    get_device_manager()
        .is_device_connected(device_type, &device_id)
        .await
}

/// Get list of connected devices
pub async fn api_get_connected_devices() -> Vec<DeviceInfo> {
    get_device_manager().get_connected_device_infos().await
}

#[cfg(test)]
mod simulator_name_tests {
    use super::*;

    /// A linked client lists the host's connected devices from this; it read
    /// "Simulator camera 1" while the host's own screens said "Simulated
    /// Camera".
    #[test]
    fn connected_simulators_carry_their_discovery_names() {
        let camera = device_info_from_id("sim_camera_1", DeviceType::Camera).unwrap();
        assert_eq!(camera.name, "Simulated Camera");
        assert_eq!(camera.display_name, "Simulated Camera");
        let guide = device_info_from_id("sim_camera_2", DeviceType::Camera).unwrap();
        assert_eq!(guide.name, "Simulated Guide Camera");
        let wheel = device_info_from_id("sim_filterwheel_1", DeviceType::FilterWheel).unwrap();
        assert_eq!(wheel.name, "Simulated Filter Wheel");
    }
}
