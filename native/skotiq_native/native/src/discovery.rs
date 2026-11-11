//! Device Discovery for Native Drivers
//!
//! Discovers devices by querying vendor SDKs directly.
//! Each vendor SDK provides its own discovery mechanism.
//!
//! IMPORTANT: Most vendor SDKs are NOT thread-safe. This module uses a mutex
//! to ensure only one discovery operation runs at a time, plus caching to
//! avoid redundant SDK queries.

use crate::catalog::{Discover, FAMILIES};
use skotiq_device::DeviceKind;
use skotiq_device::DriverError;
use skotiq_device::Vendor;
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

/// Global mutex to serialize all native SDK discovery calls.
/// Most vendor SDKs (ZWO, QHY, etc.) are NOT thread-safe and will crash
/// if called concurrently from multiple threads.
static DISCOVERY_MUTEX: OnceLock<Mutex<()>> = OnceLock::new();

fn get_discovery_mutex() -> &'static Mutex<()> {
    DISCOVERY_MUTEX.get_or_init(|| Mutex::new(()))
}

/// Cached discovery results with timestamp
struct DiscoveryCache {
    devices: Vec<NativeDeviceInfo>,
    timestamp: Instant,
}

/// Global cache for discovery results (protected by DISCOVERY_MUTEX)
static DISCOVERY_CACHE: OnceLock<Mutex<Option<DiscoveryCache>>> = OnceLock::new();

fn get_discovery_cache() -> &'static Mutex<Option<DiscoveryCache>> {
    DISCOVERY_CACHE.get_or_init(|| Mutex::new(None))
}

/// How long to cache discovery results before re-querying SDKs
/// Set to 60 seconds to avoid redundant discovery during the same session.
/// Discovery can still be triggered manually via the UI refresh button.
const CACHE_TTL: Duration = Duration::from_secs(60);

const SERIAL_SCAN_GAP: Duration = Duration::from_millis(200);

/// An absent SDK is the normal case for gear the user does not own and is
/// not worth a warning on every scan. An SDK that is present and fails is.
fn is_sdk_not_installed_error(e: &DriverError) -> bool {
    matches!(
        e,
        DriverError::SdkNotInstalled(_) | DriverError::SdkNotLoaded
    )
}

/// Information about a discovered native device
#[derive(Debug, Clone)]
pub struct NativeDeviceInfo {
    pub id: String,
    pub name: String,
    pub vendor: Vendor,
    pub device_type: DeviceKind,
    pub serial_number: Option<String>,
    pub sdk_version: Option<String>,
    /// Human-readable name for UI display (includes serial/index for disambiguation)
    pub display_name: String,
}

/// Whether a discovery may open serial ports to look for serial-protocol
/// mounts (Sky-Watcher, iOptron, LX200).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SerialProbe {
    Probe,
    /// Vendor SDK enumeration only. Used while a connected mount owns a
    /// serial port: probing the ports then only disturbs the rig.
    Skip,
}

/// Discover all native devices from all vendors
///
/// This function is protected by a mutex to ensure thread-safety since most
/// vendor SDKs are NOT thread-safe. Results are cached for CACHE_TTL seconds
/// to avoid redundant SDK queries when multiple device types are discovered.
pub async fn discover_all_devices() -> Result<Vec<NativeDeviceInfo>, DriverError> {
    discover_native_devices(SerialProbe::Probe).await
}

/// [`discover_all_devices`], probing serial ports only when `serial` allows.
/// A discovery that skipped the serial ports is not cached, so a later full
/// discovery still looks for serial mounts.
pub async fn discover_native_devices(
    serial: SerialProbe,
) -> Result<Vec<NativeDeviceInfo>, DriverError> {
    // Publish libusb symbols globally BEFORE probing any vendor SDK. Some SDKs
    // (SVBony) expect the host to provide libusb and otherwise abort the whole
    // process with `undefined symbol: libusb_init` on first use. Idempotent.
    crate::vendor::sdk_loader::ensure_libusb_global();

    // Acquire the discovery mutex to ensure only one discovery runs at a time
    let _guard = get_discovery_mutex().lock().await;

    // Check if we have a valid cached result
    {
        let cache = get_discovery_cache().lock().await;
        if let Some(ref cached) = *cache {
            if cached.timestamp.elapsed() < CACHE_TTL {
                tracing::debug!(
                    "Using cached discovery results ({} devices, {:.1}s old)",
                    cached.devices.len(),
                    cached.timestamp.elapsed().as_secs_f32()
                );
                return Ok(cached.devices.clone());
            }
        }
    }

    tracing::debug!("Starting native device discovery sequence...");
    let mut devices = Vec::new();
    let mut scanned_serial_ports = false;

    for family in FAMILIES {
        let scan = match family.discover {
            Discover::Sdk(scan) => scan,
            Discover::SerialPorts(_) if serial == SerialProbe::Skip => continue,
            Discover::SerialPorts(scan) => {
                if scanned_serial_ports {
                    // Windows needs time to release a COM port the previous
                    // protocol's scan just closed; reopening it at once fails
                    // with "Access is denied".
                    tokio::time::sleep(SERIAL_SCAN_GAP).await;
                }
                scanned_serial_ports = true;
                scan
            }
            Discover::ByAnotherFamily | Discover::NotOnThisPlatform => continue,
        };

        tracing::debug!("Discovering {}s...", family.noun);
        match scan().await {
            Ok(found) => {
                tracing::debug!("Found {} {}s", found.len(), family.noun);
                devices.extend(found.into_iter().map(|device| {
                    let family = device.family.unwrap_or(family);
                    NativeDeviceInfo {
                        id: family.device_id(&device.address),
                        name: device.name,
                        vendor: (family.vendor)(),
                        device_type: family.kind,
                        serial_number: device.serial_number,
                        sdk_version: device.sdk_version,
                        display_name: device.display_name,
                    }
                }));
            }
            Err(e) if is_sdk_not_installed_error(&e) => {
                tracing::debug!(
                    "{} discovery skipped (SDK not installed): {}",
                    family.noun,
                    e
                );
            }
            Err(e) => tracing::warn!("{} discovery failed: {}", family.noun, e),
        }
    }
    if serial == SerialProbe::Skip {
        tracing::debug!("Skipping serial mount discovery: a connected mount holds a serial port");
    }

    tracing::info!(
        "Native discovery complete: found {} total devices",
        devices.len()
    );

    // Cache the results for future calls
    if serial == SerialProbe::Probe {
        let mut cache = get_discovery_cache().lock().await;
        *cache = Some(DiscoveryCache {
            devices: devices.clone(),
            timestamp: Instant::now(),
        });
    }

    Ok(devices)
}

/// Invalidate the discovery cache, forcing the next discovery call to re-query all SDKs
pub async fn invalidate_discovery_cache() {
    let _guard = get_discovery_mutex().lock().await;
    let mut cache = get_discovery_cache().lock().await;
    *cache = None;
    tracing::debug!("Discovery cache invalidated");
}

/// Discover devices of a specific type
pub async fn discover_devices(
    device_type: DeviceKind,
) -> Result<Vec<NativeDeviceInfo>, DriverError> {
    let all_devices = discover_all_devices().await?;
    Ok(all_devices
        .into_iter()
        .filter(|d| d.device_type == device_type)
        .collect())
}
