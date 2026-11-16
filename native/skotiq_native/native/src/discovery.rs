//! Device Discovery for Native Drivers
//!
//! Discovers devices by querying vendor SDKs directly.
//! Each vendor SDK provides its own discovery mechanism.
//!
//! IMPORTANT: Most vendor SDKs are NOT thread-safe. This module uses a mutex
//! to ensure only one discovery operation runs at a time, plus caching to
//! avoid redundant SDK queries.

use crate::catalog::{Discover, Family, FAMILIES};
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

/// Cached discovery results, with the scope they were found in.
struct DiscoveryCache {
    scope: DiscoveryScope,
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

/// What one discovery may touch. The caller decides it from who asked and
/// what is connected; the default touches everything.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DiscoveryScope {
    pub serial: SerialPorts,
    /// Vendors whose SDK is not asked to enumerate.
    pub vendors_left_alone: Vec<Vendor>,
}

/// Which serial ports the serial mount scans (Sky-Watcher, iOptron, LX200)
/// may open. A scan writes mount protocol bytes into every port it opens.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SerialPorts {
    /// None.
    None,
    /// Every port of the machine but these, named as device ids write them.
    AllBut(Vec<String>),
}

impl Default for SerialPorts {
    fn default() -> Self {
        SerialPorts::AllBut(Vec::new())
    }
}

impl DiscoveryScope {
    fn asks(&self, family: &Family) -> bool {
        if self.vendors_left_alone.contains(&(family.vendor)()) {
            return false;
        }
        match family.discover {
            Discover::Sdk(_) => true,
            Discover::SerialPorts(_) => self.serial != SerialPorts::None,
            Discover::ByAnotherFamily | Discover::NotOnThisPlatform => false,
        }
    }

    /// Whether this discovery does not look where the device `device_id`
    /// names would be found, so what was last known of it still stands.
    pub fn leaves_alone(&self, device_id: &str) -> bool {
        let Some((family, _)) = crate::catalog::family_of_id(device_id) else {
            return false;
        };
        if self.vendors_left_alone.contains(&(family.vendor)()) {
            return true;
        }
        match (&self.serial, serial_port_of_id(device_id)) {
            (_, None) => false,
            (SerialPorts::None, Some(_)) => true,
            (SerialPorts::AllBut(in_use), Some(port)) => in_use.contains(&port),
        }
    }

    fn describe(&self) -> String {
        let mut left_alone: Vec<String> = self
            .vendors_left_alone
            .iter()
            .map(|vendor| format!("{} SDK", vendor.as_str()))
            .collect();
        match &self.serial {
            SerialPorts::None => left_alone.push("every serial port".to_string()),
            SerialPorts::AllBut(in_use) if !in_use.is_empty() => {
                left_alone.push(format!("serial ports {}", in_use.join(", ")))
            }
            SerialPorts::AllBut(_) => {}
        }
        if left_alone.is_empty() {
            String::new()
        } else {
            format!(" (left alone: {})", left_alone.join("; "))
        }
    }
}

/// The serial port a native device id names, as ids write it: every native
/// mount is reached over one, and nothing else is.
pub fn serial_port_of_id(device_id: &str) -> Option<String> {
    let (family, address) = crate::catalog::family_of_id(device_id)?;
    (family.kind == DeviceKind::Mount)
        .then(|| address.split(':').next().unwrap_or(address).to_string())
}

/// Discover all native devices from all vendors
///
/// This function is protected by a mutex to ensure thread-safety since most
/// vendor SDKs are NOT thread-safe. Results are cached for CACHE_TTL seconds
/// to avoid redundant SDK queries when multiple device types are discovered.
pub async fn discover_all_devices() -> Result<Vec<NativeDeviceInfo>, DriverError> {
    discover_native_devices(&DiscoveryScope::default()).await
}

/// The native devices found within `scope`. A result is reused for
/// [`CACHE_TTL`] by a discovery of the same scope.
pub async fn discover_native_devices(
    scope: &DiscoveryScope,
) -> Result<Vec<NativeDeviceInfo>, DriverError> {
    // Publish libusb symbols globally BEFORE probing any vendor SDK. Some SDKs
    // (SVBony) expect the host to provide libusb and otherwise abort the whole
    // process with `undefined symbol: libusb_init` on first use. Idempotent.
    crate::vendor::sdk_loader::ensure_libusb_global();

    let _guard = get_discovery_mutex().lock().await;

    {
        let cache = get_discovery_cache().lock().await;
        if let Some(ref cached) = *cache {
            if cached.scope == *scope && cached.timestamp.elapsed() < CACHE_TTL {
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
    let devices = discover_families(FAMILIES, scope).await;

    tracing::info!(
        "Native discovery complete{}: found {} total devices",
        scope.describe(),
        devices.len()
    );

    let mut cache = get_discovery_cache().lock().await;
    *cache = Some(DiscoveryCache {
        scope: scope.clone(),
        devices: devices.clone(),
        timestamp: Instant::now(),
    });

    Ok(devices)
}

/// Asks each of `families` that `scope` lets this discovery ask, in order.
async fn discover_families(
    families: &'static [Family],
    scope: &DiscoveryScope,
) -> Vec<NativeDeviceInfo> {
    let mut devices = Vec::new();
    let mut scanned_serial_ports = false;

    for family in families {
        if !scope.asks(family) {
            continue;
        }
        tracing::debug!("Discovering {}s...", family.noun);
        let result = match family.discover {
            Discover::Sdk(scan) => scan().await,
            Discover::SerialPorts(scan) => {
                if scanned_serial_ports {
                    // Windows needs time to release a COM port the previous
                    // protocol's scan just closed; reopening it at once fails
                    // with "Access is denied".
                    tokio::time::sleep(SERIAL_SCAN_GAP).await;
                }
                scanned_serial_ports = true;
                let ports_in_use = match &scope.serial {
                    SerialPorts::AllBut(in_use) => in_use.clone(),
                    SerialPorts::None => Vec::new(),
                };
                scan(ports_in_use).await
            }
            Discover::ByAnotherFamily | Discover::NotOnThisPlatform => continue,
        };

        match result {
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
    devices
}

/// Invalidate the discovery cache, forcing the next discovery call to re-query all SDKs
pub async fn invalidate_discovery_cache() {
    let _guard = get_discovery_mutex().lock().await;
    let mut cache = get_discovery_cache().lock().await;
    *cache = None;
    tracing::debug!("Discovery cache invalidated");
}

pub async fn discover_devices(
    device_type: DeviceKind,
) -> Result<Vec<NativeDeviceInfo>, DriverError> {
    let all_devices = discover_all_devices().await?;
    Ok(all_devices
        .into_iter()
        .filter(|d| d.device_type == device_type)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::Open;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Mutex as StdMutex;

    static ZWO_ASKED: AtomicUsize = AtomicUsize::new(0);
    static QHY_ASKED: AtomicUsize = AtomicUsize::new(0);
    static SERIAL_ASKED: StdMutex<Vec<Vec<String>>> = StdMutex::new(Vec::new());

    const fn camera(base: &'static str, vendor: fn() -> Vendor, discover: Discover) -> Family {
        Family {
            base,
            subtype: None,
            aliases: &[],
            kind: DeviceKind::Camera,
            vendor,
            label: base,
            subtype_label: None,
            noun: "test camera",
            sdk_present: None,
            discover,
            open: Open::NotOnThisPlatform("test family"),
        }
    }

    /// A ZWO and a QHY camera SDK and a serial mount scan, each counting the
    /// times it is asked.
    static FAMILIES_UNDER_TEST: [Family; 3] = [
        camera(
            "zwo",
            || Vendor::Zwo,
            Discover::Sdk(|| {
                ZWO_ASKED.fetch_add(1, Ordering::SeqCst);
                Box::pin(async { Ok(Vec::new()) })
            }),
        ),
        camera(
            "qhy",
            || Vendor::Qhy,
            Discover::Sdk(|| {
                QHY_ASKED.fetch_add(1, Ordering::SeqCst);
                Box::pin(async { Ok(Vec::new()) })
            }),
        ),
        Family {
            kind: DeviceKind::Mount,
            noun: "test mount",
            ..camera(
                "skywatcher",
                || Vendor::SkyWatcher,
                Discover::SerialPorts(|ports_in_use| {
                    SERIAL_ASKED.lock().unwrap().push(ports_in_use);
                    Box::pin(async { Ok(Vec::new()) })
                }),
            )
        },
    ];

    /// One test at a time reads the counters above.
    static COUNTERS: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    fn reset() {
        ZWO_ASKED.store(0, Ordering::SeqCst);
        QHY_ASKED.store(0, Ordering::SeqCst);
        SERIAL_ASKED.lock().unwrap().clear();
    }

    #[tokio::test]
    async fn a_vendor_left_alone_is_not_asked_and_no_serial_port_is_opened() {
        let _counters = COUNTERS.lock().await;
        reset();
        let scope = DiscoveryScope {
            serial: SerialPorts::None,
            vendors_left_alone: vec![Vendor::Zwo],
        };
        discover_families(&FAMILIES_UNDER_TEST, &scope).await;
        assert_eq!(
            ZWO_ASKED.load(Ordering::SeqCst),
            0,
            "the ZWO SDK enumerated"
        );
        assert!(
            SERIAL_ASKED.lock().unwrap().is_empty(),
            "the serial ports were scanned"
        );
        assert_eq!(QHY_ASKED.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn the_serial_scan_is_told_which_ports_connected_devices_hold() {
        let _counters = COUNTERS.lock().await;
        reset();
        let scope = DiscoveryScope {
            serial: SerialPorts::AllBut(vec!["COM4".to_string()]),
            vendors_left_alone: Vec::new(),
        };
        discover_families(&FAMILIES_UNDER_TEST, &scope).await;
        assert_eq!(
            *SERIAL_ASKED.lock().unwrap(),
            vec![vec!["COM4".to_string()]]
        );
        assert_eq!(ZWO_ASKED.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_scope_leaves_alone_the_devices_it_does_not_look_for() {
        let background = DiscoveryScope {
            serial: SerialPorts::None,
            vendors_left_alone: vec![Vendor::Zwo],
        };
        assert!(background.leaves_alone("native:zwo:1"));
        assert!(background.leaves_alone("native:zwo_eaf:0"));
        assert!(background.leaves_alone("native:skywatcher:COM4:9600"));
        assert!(!background.leaves_alone("native:qhy:QHY268M-abc"));

        let user = DiscoveryScope {
            serial: SerialPorts::AllBut(vec!["COM4".to_string()]),
            vendors_left_alone: Vec::new(),
        };
        assert!(user.leaves_alone("native:skywatcher:COM4:9600"));
        assert!(!user.leaves_alone("native:skywatcher:COM3:9600"));
        assert!(!user.leaves_alone("native:zwo:1"));
    }

    #[test]
    fn only_a_mount_id_names_a_serial_port() {
        assert_eq!(
            serial_port_of_id("native:ioptron:_dev_ttyUSB0:115200").as_deref(),
            Some("_dev_ttyUSB0")
        );
        assert_eq!(serial_port_of_id("native:zwo:1"), None);
    }
}
