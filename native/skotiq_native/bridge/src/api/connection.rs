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
use skotiq_imaging::{
    calculate_airmass, validate_fits_header, validate_image, write_fits, BayerPattern,
    DebayerAlgorithm, FitsHeader, ImageData,
};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
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
            let name = format!("Simulator {} {}", simulator_type, instance);
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
        .connect_device(&device_id)
        .await
        .map_err(|e| SkotiqError::connection_failed(&device_id, e))
}

pub(crate) fn is_phd2_device_id(device_id: &str) -> bool {
    device_id == crate::api::phd2::PHD2_DEVICE_ID
        || device_id == "phd2"
        || device_id.starts_with("phd2:")
        || device_id.starts_with("phd2://")
}

/// Get the display name for a device that's already registered in the device manager.
/// Returns None if the device isn't registered.
/// This avoids running a full discovery just to resolve a device name.
pub async fn api_get_device_display_name(device_id: String) -> Option<String> {
    get_device_manager()
        .get_device_display_name(&device_id)
        .await
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

// Alpaca device connection (cross-platform)

pub mod alpaca_connections {
    use super::*;
    // Re-export AlpacaClient for FRB bindings
    pub use skotiq_alpaca::AlpacaClient;
    use skotiq_alpaca::AlpacaDeviceType;

    /// Parse an Alpaca device ID into its components.
    ///
    /// Canonical format: `alpaca:{protocol}://{host}:{port}:{device_type}:{device_num}`
    /// (e.g. `alpaca:http://192.168.1.100:11111:camera:0`). Uses the shared
    /// `ParsedDeviceId` parser so all Alpaca connect paths agree on base_url.
    #[cfg_attr(not(test), allow(dead_code))]
    fn parse_alpaca_id(device_id: &str) -> Option<(String, AlpacaDeviceType, u32)> {
        let parsed = crate::device_id::parse_device_id_cached(device_id).ok()?;
        match parsed.connection_info {
            crate::device_id::ConnectionInfo::Alpaca {
                base_url,
                device_type,
                device_num,
                ..
            } => {
                let alpaca_type = AlpacaDeviceType::from_str(&device_type)?;
                Some((base_url, alpaca_type, device_num))
            }
            _ => None,
        }
    }

    /// Connect to an Alpaca device (delegates to unified `DeviceManager` registry).
    pub async fn connect_alpaca_device(
        device_type: DeviceType,
        device_id: &str,
    ) -> Result<(), SkotiqError> {
        api_connect_device(device_type, device_id.to_string()).await
    }

    /// Disconnect from an Alpaca device (delegates to unified `DeviceManager` registry).
    pub async fn disconnect_alpaca_device(device_id: &str) -> Result<(), SkotiqError> {
        let device_type = get_device_manager()
            .get_device(device_id)
            .await
            .map(|d| d.info.device_type)
            .or_else(|| device_info_from_id(device_id, DeviceType::Camera).map(|i| i.device_type))
            .unwrap_or(DeviceType::Camera);

        api_disconnect_device(device_type, device_id.to_string()).await
    }

    /// Get an Alpaca client from the `DeviceManager` typed Alpaca maps.
    pub async fn get_alpaca_client(device_id: &str) -> Option<Arc<AlpacaClient>> {
        get_device_manager()
            .alpaca_client_for_device(device_id)
            .await
    }

    /// Check if Alpaca is connected via `DeviceManager` (not a separate static map).
    pub async fn is_connected(device_id: &str) -> bool {
        get_device_manager().is_connected(device_id).await
    }

    #[cfg(test)]
    mod parse_alpaca_id_tests {
        use super::*;

        #[test]
        fn canonical_camera_id_matches_parsed_device_id() {
            let device_id = "alpaca:http://192.168.1.8:11111:camera:0";
            let (base_url, alpaca_type, device_number) =
                parse_alpaca_id(device_id).expect("parse_alpaca_id must succeed");
            assert_eq!(base_url, "http://192.168.1.8:11111");
            assert_eq!(alpaca_type, AlpacaDeviceType::Camera);
            assert_eq!(device_number, 0);
        }

        #[test]
        fn https_telescope_and_filterwheel_types() {
            let tel = "alpaca:https://observatory.local:11111:telescope:0";
            let (base, ty, num) = parse_alpaca_id(tel).unwrap();
            assert_eq!(base, "https://observatory.local:11111");
            assert_eq!(ty, AlpacaDeviceType::Telescope);
            assert_eq!(num, 0);

            let fw = "alpaca:http://host:11111:filterwheel:3";
            let (base, ty, num) = parse_alpaca_id(fw).unwrap();
            assert_eq!(base, "http://host:11111");
            assert_eq!(ty, AlpacaDeviceType::FilterWheel);
            assert_eq!(num, 3);
        }

        #[test]
        fn rejects_non_alpaca_and_malformed_ids() {
            assert!(parse_alpaca_id("ascom:ASCOM.Camera.Simulator").is_none());
            assert!(parse_alpaca_id("alpaca:http://host:11111:camera:notanum").is_none());
            assert!(parse_alpaca_id("alpaca:broken").is_none());
        }
    }
}

// Real ASCOM device connection

#[cfg(windows)]
pub mod ascom_connections {
    use super::*;
    use std::collections::HashMap;

    // Storage for active ASCOM connections
    static ASCOM_CAMERAS: OnceLock<Arc<RwLock<HashMap<String, skotiq_ascom::AscomCamera>>>> =
        OnceLock::new();
    static ASCOM_MOUNTS: OnceLock<Arc<RwLock<HashMap<String, skotiq_ascom::AscomMount>>>> =
        OnceLock::new();
    static ASCOM_FOCUSERS: OnceLock<Arc<RwLock<HashMap<String, skotiq_ascom::AscomFocuser>>>> =
        OnceLock::new();

    fn get_ascom_cameras() -> &'static Arc<RwLock<HashMap<String, skotiq_ascom::AscomCamera>>> {
        ASCOM_CAMERAS.get_or_init(|| Arc::new(RwLock::new(HashMap::new())))
    }

    fn get_ascom_mounts() -> &'static Arc<RwLock<HashMap<String, skotiq_ascom::AscomMount>>> {
        ASCOM_MOUNTS.get_or_init(|| Arc::new(RwLock::new(HashMap::new())))
    }

    fn get_ascom_focusers() -> &'static Arc<RwLock<HashMap<String, skotiq_ascom::AscomFocuser>>>
    {
        ASCOM_FOCUSERS.get_or_init(|| Arc::new(RwLock::new(HashMap::new())))
    }

    /// Connect to a real ASCOM camera
    pub async fn connect_ascom_camera(prog_id: &str) -> Result<(), SkotiqError> {
        let mut camera = skotiq_ascom::AscomCamera::new(prog_id)
            .map_err(|e| SkotiqError::connection_failed(prog_id, e))?;

        camera
            .connect()
            .map_err(|e| SkotiqError::connection_failed(prog_id, e))?;

        // Why: name() is optional per ASCOM ICameraV3;
        // when the driver omits it (rare, but seen on some custom DLs),
        // the ProgID is the well-known fallback used across the
        // equipment-compatibility matrix UI.
        let name = camera.name().unwrap_or_else(|_| prog_id.to_string());
        tracing::info!("Connected to ASCOM camera: {}", name);

        // Store the connection
        let mut cameras = get_ascom_cameras().write().await;
        cameras.insert(prog_id.to_string(), camera);

        Ok(())
    }

    /// Connect to a real ASCOM mount
    pub async fn connect_ascom_mount(prog_id: &str) -> Result<(), SkotiqError> {
        let mut mount = skotiq_ascom::AscomMount::new(prog_id)
            .map_err(|e| SkotiqError::connection_failed(prog_id, e))?;

        mount
            .connect()
            .map_err(|e| SkotiqError::connection_failed(prog_id, e))?;

        // Why: same fallback as the ASCOM camera path
        // above — Name is optional per ITelescope; ProgID is the
        // documented display fallback.
        let name = mount.name().unwrap_or_else(|_| prog_id.to_string());
        tracing::info!("Connected to ASCOM mount: {}", name);

        // Store the connection
        let mut mounts = get_ascom_mounts().write().await;
        mounts.insert(prog_id.to_string(), mount);

        Ok(())
    }

    /// Connect to a real ASCOM focuser
    pub async fn connect_ascom_focuser(prog_id: &str) -> Result<(), SkotiqError> {
        let mut focuser = skotiq_ascom::AscomFocuser::new(prog_id)
            .map_err(|e| SkotiqError::connection_failed(prog_id, e))?;

        focuser
            .connect()
            .map_err(|e| SkotiqError::connection_failed(prog_id, e))?;

        tracing::info!("Connected to ASCOM focuser: {}", prog_id);

        // Store the connection
        let mut focusers = get_ascom_focusers().write().await;
        focusers.insert(prog_id.to_string(), focuser);

        Ok(())
    }

    /// Get real ASCOM camera temperature
    pub async fn get_ascom_camera_temp(prog_id: &str) -> Result<f64, SkotiqError> {
        let cameras = get_ascom_cameras().read().await;
        let camera = cameras
            .get(prog_id)
            .ok_or_else(|| SkotiqError::NotConnected(prog_id.to_string()))?;

        camera
            .ccd_temperature()
            .map_err(|e| SkotiqError::OperationFailed(e))
    }

    /// Get real ASCOM mount coordinates
    pub async fn get_ascom_mount_coords(prog_id: &str) -> Result<(f64, f64), SkotiqError> {
        let mounts = get_ascom_mounts().read().await;
        let mount = mounts
            .get(prog_id)
            .ok_or_else(|| SkotiqError::NotConnected(prog_id.to_string()))?;

        let ra = mount
            .right_ascension()
            .map_err(|e| SkotiqError::OperationFailed(e))?;
        let dec = mount
            .declination()
            .map_err(|e| SkotiqError::OperationFailed(e))?;

        Ok((ra, dec))
    }

    /// Slew real ASCOM mount
    pub async fn slew_ascom_mount(prog_id: &str, ra: f64, dec: f64) -> Result<(), SkotiqError> {
        let mut mounts = get_ascom_mounts().write().await;
        let mount = mounts
            .get_mut(prog_id)
            .ok_or_else(|| SkotiqError::NotConnected(prog_id.to_string()))?;

        mount
            .slew_to_coordinates_async(ra, dec)
            .map_err(|e| SkotiqError::OperationFailed(e))
    }

    /// Get real ASCOM focuser position
    pub async fn get_ascom_focuser_position(prog_id: &str) -> Result<i32, SkotiqError> {
        let focusers = get_ascom_focusers().read().await;
        let focuser = focusers
            .get(prog_id)
            .ok_or_else(|| SkotiqError::NotConnected(prog_id.to_string()))?;

        focuser
            .position()
            .map_err(|e| SkotiqError::OperationFailed(e))
    }

    /// Move real ASCOM focuser
    pub async fn move_ascom_focuser(prog_id: &str, position: i32) -> Result<(), SkotiqError> {
        let mut focusers = get_ascom_focusers().write().await;
        let focuser = focusers
            .get_mut(prog_id)
            .ok_or_else(|| SkotiqError::NotConnected(prog_id.to_string()))?;

        focuser
            .move_to(position)
            .map_err(|e| SkotiqError::OperationFailed(e))
    }
}

// Real ASCOM device connection — non-Windows
//
// ASCOM is a Windows-only standard built on COM; the `skotiq_ascom` crate
// only defines the `AscomCamera`/`AscomMount`/`AscomFocuser` types on Windows.
// The flutter_rust_bridge bindings (`frb_generated.rs`) reference these eight
// entry points unconditionally on every platform, so Linux/macOS need a real,
// honest implementation: there is no ASCOM here, so every call returns a clear
// "not supported on this platform" error. This is the same convention the
// `skotiq_ascom` crate already uses for its `#[cfg(not(windows))]`
// `discover_devices` shim — not a placeholder, but the correct terminal
// behavior for a platform where COM/ASCOM cannot exist.
#[cfg(not(windows))]
pub mod ascom_connections {
    use super::*;

    fn unavailable(op: &str) -> SkotiqError {
        SkotiqError::OperationFailed(format!(
            "ASCOM is only available on Windows; cannot {op} on this platform"
        ))
    }

    pub async fn connect_ascom_camera(_prog_id: &str) -> Result<(), SkotiqError> {
        Err(unavailable("connect ASCOM camera"))
    }

    pub async fn connect_ascom_mount(_prog_id: &str) -> Result<(), SkotiqError> {
        Err(unavailable("connect ASCOM mount"))
    }

    pub async fn connect_ascom_focuser(_prog_id: &str) -> Result<(), SkotiqError> {
        Err(unavailable("connect ASCOM focuser"))
    }

    pub async fn get_ascom_camera_temp(_prog_id: &str) -> Result<f64, SkotiqError> {
        Err(unavailable("read ASCOM camera temperature"))
    }

    pub async fn get_ascom_mount_coords(_prog_id: &str) -> Result<(f64, f64), SkotiqError> {
        Err(unavailable("read ASCOM mount coordinates"))
    }

    pub async fn slew_ascom_mount(
        _prog_id: &str,
        _ra: f64,
        _dec: f64,
    ) -> Result<(), SkotiqError> {
        Err(unavailable("slew ASCOM mount"))
    }

    pub async fn get_ascom_focuser_position(_prog_id: &str) -> Result<i32, SkotiqError> {
        Err(unavailable("read ASCOM focuser position"))
    }

    pub async fn move_ascom_focuser(_prog_id: &str, _position: i32) -> Result<(), SkotiqError> {
        Err(unavailable("move ASCOM focuser"))
    }
}
