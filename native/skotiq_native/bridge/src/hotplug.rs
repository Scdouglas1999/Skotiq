//! Hot-plug device detection.
//!
//! Two surfaces feed the same `DeviceDiscovered` / `DeviceLost` events:
//!
//!   1. **OS bus notifications** (`start_os_hotplug_listener`): a hidden Win32
//!      window subscribes to `WM_DEVICECHANGE` (Linux/macOS use libusb
//!      `Hotplug`). The event fires within ~100 ms of a USB change but does
//!      not say which device changed. On receipt the discovery caches are
//!      forgotten, a coarse `PropertyChanged { property: "device_change" }`
//!      event goes out, and the device lists are polled now and again a few
//!      seconds later, since a fresh USB device is not usable at once.
//!
//!   2. **Manual rescan** (`trigger_rescan`): the equipment screen "Rescan"
//!      button, through `api_rescan_devices`, polls the device lists now.
//!
//! A poll after a bus event is a discovery nobody asked for, so it opens no
//! serial port and leaves alone the SDK of every vendor with a connected
//! device (`discovery::native_scope`). Nothing polls on a timer: a timer poll
//! enumerated the vendor SDKs every few minutes through the night, during
//! exposures. A change the OS does not signal (an ASCOM driver installed,
//! a serial adapter) is found by the user's Scan or Rescan.
//!
//! INDI and Alpaca are not polled here: INDI publishes device-list changes
//! on its persistent client connection, and Alpaca is broadcast-discovered
//! when the UI asks.
//!
//! Dart consumers filter on `EventCategory::Equipment` + the
//! `DeviceDiscovered` / `DeviceLost` event types and refresh the device
//! lists on receipt.

use crate::device::{DeviceInfo, DeviceType, DriverType};
use crate::device_manager::get_device_manager;
use crate::discovery::Asker;
use crate::event::equipment::{EquipmentEvent, EventSeverity};
use crate::state::get_state;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex as StdMutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

static LISTENER_STARTED: AtomicBool = AtomicBool::new(false);
static LAST_PUBLISHED_MS: AtomicU64 = AtomicU64::new(0);

const HOTPLUG_DEBOUNCE_MS: u64 = 500;

/// Re-probe delays after a bus event, measured from the previous probe.
///
/// A WM_DEVICECHANGE arrives the instant the kernel sees a device, which is
/// before the device is usable: Windows may still be installing the driver
/// for the new instance ("requires further installation"), and the ZWO SDKs
/// report the camera as present-but-unqueryable (`CAMERA_REMOVED`) or simply
/// absent for a few seconds after a re-enumeration. These follow-ups
/// re-probe at ~3 s, ~13 s and ~43 s after the event; a newer bus event takes
/// over the schedule so a re-plug storm does not fan out into dozens of
/// overlapping SDK scans.
const HOTPLUG_FOLLOW_UP_DELAYS: &[Duration] = &[
    Duration::from_secs(3),
    Duration::from_secs(10),
    Duration::from_secs(30),
];

/// Bumped per bus event; a follow-up chain stops when it no longer owns it.
static DEVICE_CHANGE_GENERATION: AtomicU64 = AtomicU64::new(0);

/// Device types we poll for hot-plug events: the classes that are
/// realistically hot-pluggable. Domes, weather and safety monitors are
/// fixtures of an observatory install.
const POLLED_DEVICE_TYPES: &[DeviceType] = &[
    DeviceType::Camera,
    DeviceType::Mount,
    DeviceType::Focuser,
    DeviceType::FilterWheel,
    DeviceType::Rotator,
];

#[cfg(windows)]
const DBT_DEVNODES_CHANGED: usize = 0x0007;
#[cfg(windows)]
const DBT_DEVICEARRIVAL: usize = 0x8000;
#[cfg(windows)]
const DBT_DEVICEREMOVECOMPLETE: usize = 0x8004;

/// Device snapshot keyed by `(DriverType, device_id)`. Held in a
/// std::sync::Mutex because no `await` happens while it is locked.
type DeviceCache = HashMap<(DriverType, String), CachedDevice>;

#[derive(Debug, Clone)]
struct CachedDevice {
    device_type: DeviceType,
    name: String,
    unique_id: Option<String>,
    display_name: String,
}

impl From<&DeviceInfo> for CachedDevice {
    fn from(dev: &DeviceInfo) -> Self {
        CachedDevice {
            device_type: dev.device_type,
            name: dev.name.clone(),
            unique_id: dev.unique_id.clone(),
            display_name: dev.display_name.clone(),
        }
    }
}

static DEVICE_CACHE: OnceLock<StdMutex<DeviceCache>> = OnceLock::new();

fn device_cache() -> &'static StdMutex<DeviceCache> {
    DEVICE_CACHE.get_or_init(|| StdMutex::new(HashMap::new()))
}

pub(crate) fn start_os_hotplug_listener() {
    if !LISTENER_STARTED.swap(true, Ordering::AcqRel) {
        start_platform_hotplug_listener();
    }
}

/// Poll the device lists now, for the user's Rescan: emits one event per
/// device that arrived or left since the last poll. A failing backend is
/// logged inside the poll and does not stop the others.
pub async fn trigger_rescan() {
    poll_once(Asker::User).await;
}

#[cfg(windows)]
fn start_platform_hotplug_listener() {
    match std::thread::Builder::new()
        .name("skotiq-windows-device-change".to_string())
        .spawn(windows_device_change_thread)
    {
        Ok(_) => {}
        Err(err) => {
            LISTENER_STARTED.store(false, Ordering::Release);
            tracing::warn!("Failed to start Windows device-change listener: {}", err);
        }
    }
}

#[cfg(all(unix, any(target_os = "linux", target_os = "macos")))]
fn start_platform_hotplug_listener() {
    match std::thread::Builder::new()
        .name("skotiq-usb-hotplug".to_string())
        .spawn(usb_hotplug_thread)
    {
        Ok(_) => {}
        Err(err) => {
            LISTENER_STARTED.store(false, Ordering::Release);
            tracing::warn!("Failed to start USB hotplug listener: {}", err);
        }
    }
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
fn start_platform_hotplug_listener() {
    tracing::debug!("USB hotplug listener is not implemented for this Unix platform yet");
}

/// The device lists as a poll `asker` started sees them, for every polled
/// type, with `connected` connected now. A device the poll does not look
/// for keeps its entry from `previous`: one the native scope leaves alone,
/// or one of a type whose ASCOM driver is connected.
async fn observe(asker: Asker, connected: &[DeviceInfo], previous: &DeviceCache) -> DeviceCache {
    let scope = crate::discovery::native_scope(asker, connected);
    let mut observed: DeviceCache = previous
        .iter()
        .filter(|((driver, id), _)| *driver == DriverType::Native && scope.leaves_alone(id))
        .map(|(key, dev)| (key.clone(), dev.clone()))
        .collect();
    #[cfg(windows)]
    let connected_types: HashSet<(DriverType, DeviceType)> = connected
        .iter()
        .map(|d| (d.driver_type, d.device_type))
        .collect();

    for &device_type in POLLED_DEVICE_TYPES {
        match crate::discovery::scan_native_for_type_with(device_type, &scope).await {
            Ok(devices) => {
                for dev in &devices {
                    observed.insert((DriverType::Native, dev.id.clone()), dev.into());
                }
            }
            Err(err) => {
                tracing::debug!(
                    "Hot-plug poll: native scan for {:?} failed: {}",
                    device_type,
                    err
                );
            }
        }

        // The ASCOM Profile registry: catches a driver registered through
        // the Chooser. A connected ASCOM driver of the type is not reopened.
        #[cfg(windows)]
        if connected_types.contains(&(DriverType::Ascom, device_type)) {
            for (key, dev) in previous {
                if key.0 == DriverType::Ascom && dev.device_type == device_type {
                    observed.insert(key.clone(), dev.clone());
                }
            }
        } else {
            match crate::discovery::scan_ascom_for_type(device_type).await {
                Ok(devices) => {
                    for dev in &devices {
                        observed.insert((DriverType::Ascom, dev.id.clone()), dev.into());
                    }
                }
                Err(err) => {
                    tracing::debug!(
                        "Hot-plug poll: ASCOM scan for {:?} failed: {}",
                        device_type,
                        err
                    );
                }
            }
        }
    }
    observed
}

type Change = (DriverType, String, CachedDevice);

/// The devices in `observed` that `previous` lacked, and the ones it held
/// that `observed` lacks. A connected device is never reported gone: the
/// disconnect path alone retires it.
fn diff(
    previous: &DeviceCache,
    observed: &DeviceCache,
    connected_keys: &HashSet<(DriverType, String)>,
) -> (Vec<Change>, Vec<Change>) {
    let arrivals = observed
        .iter()
        .filter(|(key, _)| !previous.contains_key(*key))
        .map(|(key, dev)| (key.0, key.1.clone(), dev.clone()))
        .collect();
    let removals = previous
        .iter()
        .filter(|(key, _)| !observed.contains_key(*key) && !connected_keys.contains(*key))
        .map(|(key, dev)| (key.0, key.1.clone(), dev.clone()))
        .collect();
    (arrivals, removals)
}

/// Poll the device lists and emit one event per device that arrived or
/// left since the last poll.
async fn poll_once(asker: Asker) {
    // A poll asks what is on the bus now, not what an enumeration a few
    // seconds ago found.
    skotiq_native::invalidate_discovery_cache().await;
    let connected = get_device_manager().get_connected_device_infos().await;
    let connected_keys: HashSet<(DriverType, String)> = connected
        .iter()
        .map(|d| (d.driver_type, d.id.clone()))
        .collect();
    let previous = device_cache()
        .lock()
        .expect("device cache mutex poisoned")
        .clone();
    let observed = observe(asker, &connected, &previous).await;

    let (arrivals, removals) = {
        let mut cache = device_cache().lock().expect("device cache mutex poisoned");
        let changes = diff(&cache, &observed, &connected_keys);
        *cache = observed;
        changes
    };

    if arrivals.is_empty() && removals.is_empty() {
        return;
    }

    // Real change set — flush the discovery cache so the next user-driven
    // discovery scan picks up the new state instead of serving the stale TTL.
    invalidate_discovery_caches();

    for (driver, id, dev) in arrivals {
        tracing::info!(
            "Hot-plug arrival: driver={:?} type={:?} id={} name={}",
            driver,
            dev.device_type,
            id,
            dev.name
        );
        get_state().publish_equipment_event(
            EquipmentEvent::DeviceDiscovered {
                device_class: device_type_str(dev.device_type).to_string(),
                driver: driver_type_str(driver).to_string(),
                id,
                name: dev.name,
                display_name: dev.display_name,
                unique_id: dev.unique_id,
            },
            EventSeverity::Info,
        );
    }

    for (driver, id, dev) in removals {
        tracing::info!(
            "Hot-plug removal: driver={:?} type={:?} id={} name={}",
            driver,
            dev.device_type,
            id,
            dev.name
        );
        get_state().publish_equipment_event(
            EquipmentEvent::DeviceLost {
                device_class: device_type_str(dev.device_type).to_string(),
                driver: driver_type_str(driver).to_string(),
                id,
            },
            EventSeverity::Warning,
        );
    }
}

fn device_type_str(t: DeviceType) -> &'static str {
    match t {
        DeviceType::Camera => "camera",
        DeviceType::Mount => "mount",
        DeviceType::Focuser => "focuser",
        DeviceType::FilterWheel => "filterWheel",
        DeviceType::Rotator => "rotator",
        DeviceType::Dome => "dome",
        DeviceType::Weather => "weather",
        DeviceType::SafetyMonitor => "safetyMonitor",
        DeviceType::CoverCalibrator => "coverCalibrator",
        DeviceType::Switch => "switch",
        DeviceType::Guider => "guider",
    }
}

fn driver_type_str(d: DriverType) -> &'static str {
    match d {
        DriverType::Native => "native",
        DriverType::Ascom => "ascom",
        DriverType::Alpaca => "alpaca",
        DriverType::Indi => "indi",
        DriverType::Simulator => "simulator",
    }
}

fn publish_device_change(action: &str) {
    invalidate_discovery_caches();
    get_state().publish_equipment_event(
        EquipmentEvent::PropertyChanged {
            device_type: "system".to_string(),
            device_id: "device-bus".to_string(),
            property: "device_change".to_string(),
            value: action.to_string(),
        },
        EventSeverity::Info,
    );
}

fn invalidate_discovery_caches() {
    match crate::get_runtime() {
        Ok(runtime) => {
            runtime.spawn(async {
                crate::discovery::forget().await;
            });
        }
        Err(err) => {
            tracing::warn!(
                "Device-change event could not invalidate discovery cache: {}",
                err
            );
        }
    }
}

/// Poll the device lists now and at each follow-up delay, on the bridge
/// runtime. Called from the OS listener threads (the Win32 window procedure,
/// the libusb hotplug thread), which are not tokio contexts.
fn poll_after_bus_event() {
    let generation = DEVICE_CHANGE_GENERATION.fetch_add(1, Ordering::AcqRel) + 1;
    match crate::get_runtime() {
        Ok(runtime) => {
            runtime.spawn(async move {
                poll_once(Asker::Background).await;
                for delay in HOTPLUG_FOLLOW_UP_DELAYS {
                    tokio::time::sleep(*delay).await;
                    if !follow_up_still_owned(generation) {
                        return;
                    }
                    tracing::debug!(
                        "Hot-plug follow-up probe {}s after bus event (generation {})",
                        delay.as_secs(),
                        generation
                    );
                    poll_once(Asker::Background).await;
                }
            });
        }
        Err(err) => {
            // A missing runtime must be visible: without it the user simply
            // stops seeing arrival events, with nothing to say why.
            tracing::warn!(
                "Hot-plug poll could not acquire runtime: {} (a plugged-in device shows after the next Scan)",
                err,
            );
        }
    }
}

/// A follow-up chain keeps probing only while no newer bus event has arrived.
fn follow_up_still_owned(generation: u64) -> bool {
    DEVICE_CHANGE_GENERATION.load(Ordering::Acquire) == generation
}

fn should_publish_device_change(now_ms: u64) -> bool {
    let previous = LAST_PUBLISHED_MS.load(Ordering::Acquire);
    if now_ms.saturating_sub(previous) < HOTPLUG_DEBOUNCE_MS {
        return false;
    }

    LAST_PUBLISHED_MS
        .compare_exchange(previous, now_ms, Ordering::AcqRel, Ordering::Acquire)
        .is_ok()
}

fn current_time_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u128::from(u64::MAX)) as u64
}

#[cfg(all(unix, any(target_os = "linux", target_os = "macos")))]
struct UsbHotplugHandler;

#[cfg(all(unix, any(target_os = "linux", target_os = "macos")))]
impl<T: rusb::UsbContext> rusb::Hotplug<T> for UsbHotplugHandler {
    fn device_arrived(&mut self, device: rusb::Device<T>) {
        handle_usb_hotplug("arrival", &device);
    }

    fn device_left(&mut self, device: rusb::Device<T>) {
        handle_usb_hotplug("removal", &device);
    }
}

#[cfg(all(unix, any(target_os = "linux", target_os = "macos")))]
fn handle_usb_hotplug<T: rusb::UsbContext>(action: &'static str, device: &rusb::Device<T>) {
    let now_ms = current_time_ms();
    if !should_publish_device_change(now_ms) {
        tracing::debug!(
            "Debounced USB hotplug action={} bus={} address={}",
            action,
            device.bus_number(),
            device.address()
        );
        return;
    }

    tracing::info!(
        "USB hotplug event received: action={} bus={} address={}",
        action,
        device.bus_number(),
        device.address()
    );
    publish_device_change(action);
    poll_after_bus_event();
}

#[cfg(all(unix, any(target_os = "linux", target_os = "macos")))]
fn usb_hotplug_thread() {
    use rusb::{Context, HotplugBuilder, UsbContext};
    use std::time::Duration;

    if !rusb::has_hotplug() {
        LISTENER_STARTED.store(false, Ordering::Release);
        tracing::warn!("libusb hotplug support is unavailable on this platform");
        return;
    }

    let context = match Context::new() {
        Ok(context) => context,
        Err(err) => {
            LISTENER_STARTED.store(false, Ordering::Release);
            tracing::warn!("Failed to initialize libusb hotplug context: {}", err);
            return;
        }
    };

    // `UsbHotplugHandler` implements `Hotplug<T>` for every `T: UsbContext`, so
    // the `U` type parameter of `register` is otherwise ambiguous. Pin it to the
    // concrete `Context` we created above.
    let _registration: rusb::Registration<Context> = match HotplugBuilder::new()
        .enumerate(false)
        .register(&context, Box::new(UsbHotplugHandler))
    {
        Ok(registration) => registration,
        Err(err) => {
            LISTENER_STARTED.store(false, Ordering::Release);
            tracing::warn!("Failed to register libusb hotplug callback: {}", err);
            return;
        }
    };

    tracing::info!("USB hotplug listener started");
    loop {
        if let Err(err) = context.handle_events(None) {
            tracing::warn!("USB hotplug event loop error: {}", err);
            std::thread::sleep(Duration::from_millis(250));
        }
    }
}

#[cfg(windows)]
fn device_change_action(wparam: usize) -> Option<&'static str> {
    match wparam {
        DBT_DEVICEARRIVAL => Some("arrival"),
        DBT_DEVICEREMOVECOMPLETE => Some("removal"),
        DBT_DEVNODES_CHANGED => Some("changed"),
        _ => None,
    }
}

#[cfg(windows)]
fn handle_windows_device_change(wparam: usize) {
    let Some(action) = device_change_action(wparam) else {
        return;
    };

    let now_ms = current_time_ms();
    if !should_publish_device_change(now_ms) {
        tracing::debug!("Debounced Windows WM_DEVICECHANGE action={}", action);
        return;
    }

    tracing::info!("Windows device-change event received: {}", action);
    publish_device_change(action);
    poll_after_bus_event();
}

#[cfg(windows)]
fn windows_device_change_thread() {
    use windows::core::{w, PCWSTR};
    use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::WindowsAndMessaging::{
        CreateWindowExW, DefWindowProcW, DispatchMessageW, GetMessageW, RegisterClassW,
        TranslateMessage, MSG, WINDOW_EX_STYLE, WINDOW_STYLE, WM_DEVICECHANGE, WNDCLASSW,
    };

    unsafe extern "system" fn wnd_proc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        if msg == WM_DEVICECHANGE {
            handle_windows_device_change(wparam.0);
        }

        // SAFETY: Forwarding unhandled messages to DefWindowProcW is the
        // documented default window procedure path for a Win32 window proc.
        unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
    }

    // SAFETY: This thread owns the hidden window and its message loop. All
    // Win32 pointers passed here are either null/default handles or static
    // UTF-16 string pointers created by `w!`.
    unsafe {
        let Ok(module) = GetModuleHandleW(None) else {
            tracing::warn!("Windows device-change listener could not get module handle");
            LISTENER_STARTED.store(false, Ordering::Release);
            return;
        };
        let hinstance = module.into();
        let class_name = w!("SkotiqDeviceChangeWindow");
        let wnd_class = WNDCLASSW {
            hInstance: hinstance,
            lpszClassName: class_name,
            lpfnWndProc: Some(wnd_proc),
            ..Default::default()
        };

        if RegisterClassW(&wnd_class) == 0 {
            tracing::warn!("Windows device-change listener could not register window class");
            LISTENER_STARTED.store(false, Ordering::Release);
            return;
        }

        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            class_name,
            PCWSTR::null(),
            WINDOW_STYLE::default(),
            0,
            0,
            0,
            0,
            HWND::default(),
            None,
            hinstance,
            None,
        );

        if hwnd.0 == 0 {
            tracing::warn!("Windows device-change listener could not create hidden window");
            LISTENER_STARTED.store(false, Ordering::Release);
            return;
        }

        tracing::info!("Windows device-change listener started");
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, HWND::default(), 0, 0).into() {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::discovery::tests::NATIVE_SCOPES_ASKED;
    use skotiq_device::Vendor;
    use skotiq_native::SerialPorts;

    fn info(id: &str, device_type: DeviceType, driver_type: DriverType) -> DeviceInfo {
        DeviceInfo {
            id: id.to_string(),
            name: id.to_string(),
            device_type,
            driver_type,
            description: "test".to_string(),
            driver_version: "test".to_string(),
            serial_number: None,
            unique_id: None,
            display_name: id.to_string(),
        }
    }

    fn cached(device_type: DeviceType, name: &str) -> CachedDevice {
        CachedDevice {
            device_type,
            name: name.to_string(),
            unique_id: None,
            display_name: name.to_string(),
        }
    }

    /// The rig at night: the ZWO camera exposing, its EAF and EFW, and the
    /// mount through ASCOM. A bus event during the exposure polls without
    /// asking the ZWO SDKs and without opening a serial port, and the ZWO
    /// devices stay listed.
    #[tokio::test]
    async fn a_poll_after_a_bus_event_leaves_a_connected_vendor_and_the_serial_ports_alone() {
        let connected = [
            info("native:zwo:1", DeviceType::Camera, DriverType::Native),
            info("native:zwo_eaf:0", DeviceType::Focuser, DriverType::Native),
            info(
                "ascom:ASCOM.PegasusAstroNYX101.Telescope",
                DeviceType::Mount,
                DriverType::Ascom,
            ),
        ];
        let previous: DeviceCache = [
            (
                (DriverType::Native, "native:zwo:1".to_string()),
                cached(DeviceType::Camera, "ZWO ASI1600MM-Cool"),
            ),
            (
                (DriverType::Native, "native:zwo:0".to_string()),
                cached(DeviceType::Camera, "ZWO ASI178MM"),
            ),
        ]
        .into_iter()
        .collect();
        NATIVE_SCOPES_ASKED.with(|asked| asked.borrow_mut().clear());

        let observed = observe(Asker::Background, &connected, &previous).await;

        let asked = NATIVE_SCOPES_ASKED.with(|asked| asked.borrow().clone());
        assert!(!asked.is_empty(), "the poll asked no native scope at all");
        for scope in &asked {
            assert!(scope.vendors_left_alone.contains(&Vendor::Zwo), "{scope:?}");
            assert_eq!(scope.serial, SerialPorts::None, "{scope:?}");
        }
        let (_, removals) = diff(&previous, &observed, &HashSet::new());
        assert!(
            removals.is_empty(),
            "a ZWO device the poll did not look for went missing: {removals:?}"
        );
    }

    /// The user's Rescan with a native Sky-Watcher mount on COM4 probes the
    /// other ports, never COM4.
    #[tokio::test]
    async fn a_rescan_leaves_alone_the_port_of_a_connected_mount() {
        let connected = [info(
            "native:skywatcher:COM4:9600",
            DeviceType::Mount,
            DriverType::Native,
        )];
        NATIVE_SCOPES_ASKED.with(|asked| asked.borrow_mut().clear());

        observe(Asker::User, &connected, &DeviceCache::new()).await;

        let asked = NATIVE_SCOPES_ASKED.with(|asked| asked.borrow().clone());
        assert!(!asked.is_empty());
        for scope in &asked {
            assert_eq!(scope.serial, SerialPorts::AllBut(vec!["COM4".to_string()]));
            assert!(scope.vendors_left_alone.is_empty());
        }
    }

    #[test]
    fn debounce_suppresses_close_device_change_events() {
        LAST_PUBLISHED_MS.store(1_000, Ordering::Release);

        assert!(!should_publish_device_change(1_250));
        assert!(should_publish_device_change(1_600));
        assert_eq!(LAST_PUBLISHED_MS.load(Ordering::Acquire), 1_600);
    }

    #[cfg(windows)]
    #[test]
    fn windows_device_change_action_maps_known_messages() {
        assert_eq!(device_change_action(DBT_DEVICEARRIVAL), Some("arrival"));
        assert_eq!(
            device_change_action(DBT_DEVICEREMOVECOMPLETE),
            Some("removal")
        );
        assert_eq!(device_change_action(DBT_DEVNODES_CHANGED), Some("changed"));
        assert_eq!(device_change_action(0xFFFF), None);
    }

    #[test]
    fn driver_and_device_type_strings_are_stable() {
        // The Dart side keys off these strings — keep them lowercase and
        // matching the canonical enum names the rest of the bridge uses.
        assert_eq!(driver_type_str(DriverType::Native), "native");
        assert_eq!(driver_type_str(DriverType::Ascom), "ascom");
        assert_eq!(driver_type_str(DriverType::Alpaca), "alpaca");
        assert_eq!(driver_type_str(DriverType::Indi), "indi");
        assert_eq!(device_type_str(DeviceType::Camera), "camera");
        assert_eq!(device_type_str(DeviceType::FilterWheel), "filterWheel");
        assert_eq!(device_type_str(DeviceType::Mount), "mount");
    }

    #[test]
    fn follow_up_probes_outlast_a_driver_install_and_yield_to_newer_events() {
        // The first follow-up must land while the operator is still looking
        // at the device list; the last must reach past the tens of seconds a
        // fresh USB instance can spend in driver installation on Windows.
        let first = HOTPLUG_FOLLOW_UP_DELAYS[0];
        let total: Duration = HOTPLUG_FOLLOW_UP_DELAYS.iter().sum();
        assert!(
            first <= Duration::from_secs(5),
            "first follow-up too late: {first:?}"
        );
        assert!(
            total >= Duration::from_secs(40),
            "follow-ups end too soon: {total:?}"
        );

        // A newer bus event takes the chain over: the older generation stops.
        let mine = DEVICE_CHANGE_GENERATION.fetch_add(1, Ordering::AcqRel) + 1;
        assert!(follow_up_still_owned(mine));
        let newer = DEVICE_CHANGE_GENERATION.fetch_add(1, Ordering::AcqRel) + 1;
        assert!(!follow_up_still_owned(mine));
        assert!(follow_up_still_owned(newer));
    }

    #[test]
    fn a_poll_reports_arrivals_and_removals_once() {
        let gone = (DriverType::Native, "native:test:gone".to_string());
        let new = (DriverType::Native, "native:test:new".to_string());
        let previous: DeviceCache = [(gone.clone(), cached(DeviceType::Focuser, "Old Focuser"))]
            .into_iter()
            .collect();
        let observed: DeviceCache = [(new.clone(), cached(DeviceType::Mount, "New Mount"))]
            .into_iter()
            .collect();

        let (arrivals, removals) = diff(&previous, &observed, &HashSet::new());
        assert_eq!(arrivals.iter().map(|c| &c.1).collect::<Vec<_>>(), [&new.1]);
        assert_eq!(removals.iter().map(|c| &c.1).collect::<Vec<_>>(), [&gone.1]);

        let (arrivals, removals) = diff(&observed, &observed, &HashSet::new());
        assert!(arrivals.is_empty() && removals.is_empty());
    }

    /// A connected serial mount holds its port, so an enumerate cannot see
    /// it: that is not a removal.
    #[test]
    fn a_connected_device_missing_from_a_poll_is_not_reported_gone() {
        let key = (
            DriverType::Native,
            "native:skywatcher:COM4:9600".to_string(),
        );
        let previous: DeviceCache = [(key.clone(), cached(DeviceType::Mount, "AZ-GTi"))]
            .into_iter()
            .collect();
        let connected: HashSet<_> = [key].into_iter().collect();

        let (arrivals, removals) = diff(&previous, &DeviceCache::new(), &connected);
        assert!(arrivals.is_empty() && removals.is_empty(), "{removals:?}");
    }
}
