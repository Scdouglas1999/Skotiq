//! Hot-plug device detection.
//!
//! Three complementary surfaces feed the same downstream event so the UI sees
//! sub-second arrival latency without wasting CPU on idle re-enumeration:
//!
//!   1. **OS bus notifications** (`start_os_hotplug_listener`): a hidden Win32
//!      window subscribes to `WM_DEVICECHANGE` (Linux/macOS use libusb
//!      `Hotplug`). The kernel event fires within ~100 ms of a USB arrival but
//!      is unspecific — it tells you that *some* device changed, not which
//!      one. On receipt we (a) invalidate the discovery cache, (b) emit a
//!      coarse `PropertyChanged { property: "device_change" }` event for
//!      legacy listeners, and (c) trigger an off-cadence `poll_once` so typed
//!      `device_discovered` / `device_lost` events flow without waiting for
//!      the slow-poll tick.
//!
//!   2. **Slow polling watcher** (`start_device_poll_watcher`): a tokio task
//!      that walks the native (vendor-SDK) and, on Windows, ASCOM registry
//!      device lists every `HOTPLUG_POLL_INTERVAL` (5 min). It diffs the live
//!      list against a cached set keyed by `(driver_type, device_id)` and
//!      emits one `device_discovered` event per new arrival and one
//!      `device_lost` event per removal. This cadence is the safety net for
//!      changes that don't fire a kernel event:
//!        * ASCOM Profile registry edits (driver install via the Chooser
//!          mid-session) — registry writes don't notify userland.
//!        * Serial-port (COM) churn for FTDI / CH340 adapters that some
//!          mount drivers cycle without raising a USB hotplug event.
//!        * Last-resort coverage if the WM_DEVICECHANGE pump is wedged.
//!
//!   3. **Manual rescan** (`trigger_rescan`): the equipment screen "Rescan"
//!      button calls `api_rescan_devices`, which invokes `trigger_rescan` to
//!      run a full diff pass immediately, independent of the slow-poll
//!      schedule. This is what the user reaches for when they plugged in a
//!      device the slow-poll hasn't picked up yet (typically because the OS
//!      didn't surface a hotplug for it, e.g. a quirky USB hub).
//!
//! INDI and Alpaca are intentionally NOT polled here:
//!
//!   * INDI publishes device-list changes as `getProperties` notifications
//!     on the persistent client connection. The INDI client (in
//!     `skotiq_indi`) already raises those into the event bus when a
//!     remote driver attaches / detaches.
//!   * Alpaca is broadcast-discovered when the UI requests it. Polling on a
//!     fixed cadence would saturate the LAN with UDP broadcasts and drain
//!     battery on paired mobile clients.
//!
//! Dart consumers filter on `EventCategory::Equipment` + the
//! `DeviceDiscovered` / `DeviceLost` event types. The wave-6b unified
//! discovery provider invalidates its cache and refreshes the visible list on
//! receipt so the equipment screen refreshes without pull-to-refresh.
//!
//! These arrivals/removals are emitted as the first-class
//! `EquipmentEvent::DeviceDiscovered` / `EquipmentEvent::DeviceLost` variants
//! (see `event.rs`); the FRB bindings carry the typed fields directly, so the
//! Dart side maps the variant without decoding a hand-built JSON payload.

use crate::api::{api_invalidate_discovery_cache, get_state};
use crate::device::{ConnectionState, DeviceType, DriverType};
use crate::event::{EquipmentEvent, EventSeverity};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex as StdMutex;
use std::sync::OnceLock;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

static LISTENER_STARTED: AtomicBool = AtomicBool::new(false);
static POLL_WATCHER_STARTED: AtomicBool = AtomicBool::new(false);
static LAST_PUBLISHED_MS: AtomicU64 = AtomicU64::new(0);

const HOTPLUG_DEBOUNCE_MS: u64 = 500;

/// Re-probe delays after a bus event, measured from the previous probe.
///
/// A WM_DEVICECHANGE arrives the instant the kernel sees a device, which is
/// before the device is usable: Windows may still be installing the driver
/// for the new instance ("requires further installation"), and the ZWO SDKs
/// report the camera as present-but-unqueryable (`CAMERA_REMOVED`) or simply
/// absent for a few seconds after a re-enumeration. A single immediate probe
/// therefore caches "nothing here" and, with no further bus event, the device
/// stays invisible until the five-minute fallback — which on the rig read as
/// "discovery doesn't see the camera until I restart". These follow-ups
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

/// Polling cadence for the native / ASCOM hot-plug watcher.
///
/// Five minutes is the fallback cadence in the hybrid architecture
/// (see module docs). The OS bus listener (WM_DEVICECHANGE / libusb hotplug)
/// is the primary low-latency path; this poll exists only to catch state
/// changes the kernel does not surface:
///   * ASCOM Profile registry writes (driver install / uninstall) — no
///     notification API exists, so we poll.
///   * Serial / COM-port changes for adapters that some mount drivers cycle
///     without producing a USB hotplug.
///   * Hub / chipset edge cases where WM_DEVICECHANGE is dropped.
///
/// Native discovery includes active serial protocol probes for Sky-Watcher,
/// iOptron, and LX200 mounts. On a real Windows rig that pass takes 10–15
/// seconds and opens every COM port, so a 30-second fallback spent a material
/// fraction of uptime probing hardware and could contend with an active ASCOM
/// driver. Five minutes retains a bounded fallback for missed kernel events
/// without treating expensive serial discovery as a heartbeat. USB
/// camera/mount/focuser arrivals do NOT wait this long — the
/// WM_DEVICECHANGE handler triggers an off-cadence `poll_once` immediately.
const HOTPLUG_POLL_INTERVAL: Duration = Duration::from_secs(5 * 60);

/// Device types we poll for hot-plug events. Keep this list narrow to the
/// classes that are realistically hot-pluggable from the user's perspective:
/// cameras, mounts, focusers, filter wheels, rotators. Domes / weather /
/// safety monitors are not polled — they are effectively permanent fixtures
/// of an observatory install and their drivers do not benefit from a 4 s
/// hot-plug poll.
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

/// Cached device snapshot keyed by `(DriverType, device_id)`. Held in a
/// std::sync::Mutex (not tokio) because we only touch it from the dedicated
/// poll task — there is no `await` while the lock is held.
type DeviceCache = HashMap<(DriverType, String), CachedDevice>;

#[derive(Debug, Clone)]
struct CachedDevice {
    device_type: DeviceType,
    name: String,
    unique_id: Option<String>,
    display_name: String,
}

static DEVICE_CACHE: OnceLock<StdMutex<DeviceCache>> = OnceLock::new();

fn device_cache() -> &'static StdMutex<DeviceCache> {
    DEVICE_CACHE.get_or_init(|| StdMutex::new(HashMap::new()))
}

pub(crate) fn start_os_hotplug_listener() {
    if !LISTENER_STARTED.swap(true, Ordering::AcqRel) {
        start_platform_hotplug_listener();
    }

    // The polling watcher is independent of the OS listener — on Linux/macOS
    // USB bus events cut through the discovery TTL immediately; the poller
    // fills in typed arrived/lost details for SDK-backed device lists.
    start_device_poll_watcher();
}

/// Run a full hot-plug diff pass now, independent of the slow-poll cadence.
///
/// Used by:
///   * the OS bus listener (WM_DEVICECHANGE / libusb hotplug) to surface
///     typed arrival / removal events within a second of the kernel event,
///   * the equipment-screen Rescan button via `api::api_rescan_devices`,
///   * tests that want to force a deterministic poll cycle.
///
/// Errors from individual backend scans surface as `tracing::debug!` lines
/// inside `poll_once`; the caller does not see them because a single failing
/// driver must not block the diff for the other drivers. The diff itself is
/// guaranteed to complete (it is just a `HashMap` set-difference).
pub async fn trigger_rescan() {
    poll_once(false).await;
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

fn start_device_poll_watcher() {
    if POLL_WATCHER_STARTED.swap(true, Ordering::AcqRel) {
        return;
    }

    let runtime = match crate::get_runtime() {
        Ok(rt) => rt,
        Err(err) => {
            POLL_WATCHER_STARTED.store(false, Ordering::Release);
            tracing::warn!(
                "Hot-plug polling watcher could not acquire runtime: {} (skipping)",
                err
            );
            return;
        }
    };

    runtime.spawn(async {
        tracing::info!(
            "Hot-plug poll watcher started (interval={}s, types={:?})",
            HOTPLUG_POLL_INTERVAL.as_secs(),
            POLLED_DEVICE_TYPES
        );
        // Seed the cache on first tick without emitting events. Anything
        // that was already plugged in when the listener started is
        // already-known state, not a "newly arrived" device.
        let mut first_tick = true;
        loop {
            tokio::time::sleep(HOTPLUG_POLL_INTERVAL).await;
            poll_once(first_tick).await;
            first_tick = false;
        }
    });
}

/// Walk the native + ASCOM (on Windows) device lists for each polled device
/// type and diff against the cached set. Emits one event per (arrived /
/// removed) device.
async fn poll_once(suppress_events: bool) {
    let mut observed: HashMap<(DriverType, String), CachedDevice> = HashMap::new();

    // Snapshot the live connection state BEFORE probing any bus. A device that
    // is currently CONNECTED holds an exclusive serial/USB handle, so the SDK
    // enumerate would either fail to see it (producing a spurious `device_lost`
    // -> the UI drops a live device) or re-open the bus and disrupt the live
    // connection — the contention a remote connect racing this poll produces.
    // So (1) skip probing any (driver, device_type) bus that has a connected
    // device and carry its cached entries forward unchanged, and (2) never emit
    // a removal for a connected device id.
    let connected = get_state().get_all_device_states().await;
    let connected_keys: HashSet<(DriverType, String)> = connected
        .iter()
        .filter(|d| d.connection_state == ConnectionState::Connected)
        .map(|d| (d.driver_type, d.device_id.clone()))
        .collect();
    let connected_types: HashSet<(DriverType, DeviceType)> = connected
        .iter()
        .filter(|d| d.connection_state == ConnectionState::Connected)
        .map(|d| (d.driver_type, d.device_type))
        .collect();

    // Carry-forward helper: copy the cached entries for a paused (driver, type)
    // bus into `observed` so the diff sees no change for that bus — no re-open,
    // no spurious removal.
    fn carry_forward_cached(
        observed: &mut HashMap<(DriverType, String), CachedDevice>,
        driver: DriverType,
        device_type: DeviceType,
    ) {
        let cache = device_cache().lock().expect("device cache mutex poisoned");
        for (key, dev) in cache.iter() {
            if key.0 == driver && dev.device_type == device_type {
                observed.insert(key.clone(), dev.clone());
            }
        }
    }

    for &device_type in POLLED_DEVICE_TYPES {
        // Native (vendor SDK) backend — always polled, the SDK enumerates
        // are local and don't touch the network. BUT pause the probe if a
        // native device of this type is currently connected (bus in use).
        if connected_types.contains(&(DriverType::Native, device_type)) {
            tracing::debug!(
                "Hot-plug poll: skipping native scan for {:?} (device connected, bus in use)",
                device_type
            );
            carry_forward_cached(&mut observed, DriverType::Native, device_type);
        } else {
            match crate::api::discovery::scan_native_for_type_public(device_type).await {
                Ok(devices) => {
                    for dev in devices {
                        observed.insert(
                            (DriverType::Native, dev.id.clone()),
                            CachedDevice {
                                device_type: dev.device_type,
                                name: dev.name.clone(),
                                unique_id: dev.unique_id.clone(),
                                display_name: dev.display_name.clone(),
                            },
                        );
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
        }

        // ASCOM only on Windows. The ASCOM Profile registry doesn't model
        // hot-plug; this catches users registering a driver via the chooser
        // mid-session and is cheap (registry read). Same bus-pause rule:
        // don't re-open an ASCOM driver that is currently connected.
        #[cfg(windows)]
        if connected_types.contains(&(DriverType::Ascom, device_type)) {
            tracing::debug!(
                "Hot-plug poll: skipping ASCOM scan for {:?} (device connected, bus in use)",
                device_type
            );
            carry_forward_cached(&mut observed, DriverType::Ascom, device_type);
        } else {
            match crate::api::discovery::scan_ascom_for_type_public(device_type).await {
                Ok(devices) => {
                    for dev in devices {
                        observed.insert(
                            (DriverType::Ascom, dev.id.clone()),
                            CachedDevice {
                                device_type: dev.device_type,
                                name: dev.name.clone(),
                                unique_id: dev.unique_id.clone(),
                                display_name: dev.display_name.clone(),
                            },
                        );
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

    // Diff against the cache. We do the diff and the cache update in a single
    // lock scope so two concurrent poll ticks can't double-emit the same
    // arrival. POLL_WATCHER_STARTED guarantees only one tokio task is running,
    // but the lock is cheap insurance.
    let (arrivals, removals) = {
        let mut cache = device_cache().lock().expect("device cache mutex poisoned");
        let previous_keys: HashSet<(DriverType, String)> = cache.keys().cloned().collect();
        let observed_keys: HashSet<(DriverType, String)> = observed.keys().cloned().collect();

        let arrival_keys: Vec<(DriverType, String)> =
            observed_keys.difference(&previous_keys).cloned().collect();
        // Belt-and-suspenders: even if a probe partially enumerated and a
        // connected device slipped out of `observed`, never emit a removal for
        // a device that AppState still considers connected. The disconnect path
        // is the only thing allowed to retire a connected device.
        let removal_keys: Vec<(DriverType, String)> = previous_keys
            .difference(&observed_keys)
            .filter(|key| !connected_keys.contains(*key))
            .cloned()
            .collect();

        let arrivals: Vec<(DriverType, String, CachedDevice)> = arrival_keys
            .iter()
            .filter_map(|key| {
                observed
                    .get(key)
                    .map(|dev| (key.0, key.1.clone(), dev.clone()))
            })
            .collect();
        let removals: Vec<(DriverType, String, CachedDevice)> = removal_keys
            .iter()
            .filter_map(|key| {
                cache
                    .get(key)
                    .map(|dev| (key.0, key.1.clone(), dev.clone()))
            })
            .collect();

        *cache = observed;
        (arrivals, removals)
    };

    if suppress_events {
        if !arrivals.is_empty() {
            tracing::debug!(
                "Hot-plug poll: seeded cache with {} devices on first tick",
                arrivals.len()
            );
        }
        return;
    }

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
                api_invalidate_discovery_cache().await;
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

/// Spawn an off-cadence `poll_once` on the bridge tokio runtime so kernel
/// hotplug events surface typed arrival/removal events without waiting for
/// the slow-poll tick. Called from the OS bus listener threads (Win32 wnd
/// proc thread, libusb hotplug thread) which are NOT tokio contexts, so
/// this MUST go through `crate::get_runtime()` rather than
/// `tokio::spawn` directly.
fn schedule_off_cadence_poll() {
    let generation = DEVICE_CHANGE_GENERATION.fetch_add(1, Ordering::AcqRel) + 1;
    match crate::get_runtime() {
        Ok(runtime) => {
            runtime.spawn(async move {
                poll_once(false).await;
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
                    poll_once(false).await;
                }
            });
        }
        Err(err) => {
            // A missing runtime must be visible: without it the user simply
            // stops seeing arrival events, with nothing to say why.
            tracing::warn!(
                "Hot-plug off-cadence poll could not acquire runtime: {} (typed arrival events will be delayed up to {} s)",
                err,
                HOTPLUG_POLL_INTERVAL.as_secs(),
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
    // Trigger an off-cadence diff so typed device_discovered/device_lost
    // events flow within ~1 s instead of waiting for the slow poll tick.
    schedule_off_cadence_poll();
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
    // The coarse `device_change` notification above is for legacy listeners.
    // Kick an off-cadence diff so typed `device_discovered`/`device_lost`
    // events land within a second instead of waiting for the fallback poll
    // slow-poll tick. This is the whole point of the hybrid architecture.
    schedule_off_cadence_poll();
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
        assert!(
            total <= HOTPLUG_POLL_INTERVAL,
            "follow-ups must not outlive the slow poll"
        );

        // A newer bus event takes the chain over: the older generation stops.
        let mine = DEVICE_CHANGE_GENERATION.fetch_add(1, Ordering::AcqRel) + 1;
        assert!(follow_up_still_owned(mine));
        let newer = DEVICE_CHANGE_GENERATION.fetch_add(1, Ordering::AcqRel) + 1;
        assert!(!follow_up_still_owned(mine));
        assert!(follow_up_still_owned(newer));
    }

    #[test]
    fn slow_poll_interval_is_five_minutes() {
        // This is the slow safety-net cadence, not the fast one: the OS bus
        // listener (WM_DEVICECHANGE / libusb hotplug) delivers arrivals
        // promptly, and this poll only backstops it. A few-second cadence here
        // is the polling-only design, which burns CPU and hammers vendor SDKs —
        // native enumeration actively opens serial ports.
        assert_eq!(
            HOTPLUG_POLL_INTERVAL.as_secs(),
            5 * 60,
            "hot-plug slow-poll cadence must be 5m; fast arrivals come through the OS bus listener",
        );
    }

    #[test]
    fn first_tick_seeds_cache_without_emitting() {
        // poll_once(true) is what the slow-poll task uses on its first tick
        // to populate the cache without flooding listeners with arrivals
        // for every already-plugged device. The semantics: even when the
        // diff produces a non-empty `arrivals` vector, `suppress_events`
        // must short-circuit before publishing — the function logs and
        // returns.
        //
        // We can't run the full SDK scan in a unit test (no hardware,
        // no registry), so we exercise the suppression branch by hand:
        // build a non-empty arrivals list, then assert that with
        // `suppress_events == true` the publish branch is not entered.
        // (The publish branch requires the global app state singleton,
        // so taking it here would also test that init has happened —
        // we keep the test scope narrow.)

        let mut cache: DeviceCache = HashMap::new();
        let mut observed: HashMap<(DriverType, String), CachedDevice> = HashMap::new();
        observed.insert(
            (DriverType::Native, "native:test:seed".to_string()),
            CachedDevice {
                device_type: DeviceType::Camera,
                name: "Seed Cam".to_string(),
                unique_id: None,
                display_name: "Seed Cam".to_string(),
            },
        );

        let (arrivals, removals) = diff_for_test(&mut cache, observed);
        assert_eq!(arrivals.len(), 1, "first-tick diff should detect arrivals");
        assert!(removals.is_empty());
        // The suppression contract: poll_once with suppress=true would NOT
        // emit these. We can't observe "did not emit" without a real event
        // bus, but we DO want the cache to be populated so the SECOND tick
        // is the one that emits typed events. Confirm the cache absorbed
        // the observed set.
        assert_eq!(cache.len(), 1);
        assert!(cache.contains_key(&(DriverType::Native, "native:test:seed".to_string())));
    }

    /// Run the diff logic from `poll_once` against an arbitrary cache state
    /// without touching the global singleton. Returns `(arrivals, removals)`
    /// and replaces `cache` with `observed` (matching `poll_once`'s atomic
    /// swap). Kept private to tests so production code still goes through
    /// the singleton.
    fn diff_for_test(
        cache: &mut DeviceCache,
        observed: HashMap<(DriverType, String), CachedDevice>,
    ) -> (
        Vec<(DriverType, String, CachedDevice)>,
        Vec<(DriverType, String, CachedDevice)>,
    ) {
        let previous_keys: HashSet<(DriverType, String)> = cache.keys().cloned().collect();
        let observed_keys: HashSet<(DriverType, String)> = observed.keys().cloned().collect();
        let arrival_keys: Vec<(DriverType, String)> =
            observed_keys.difference(&previous_keys).cloned().collect();
        let removal_keys: Vec<(DriverType, String)> =
            previous_keys.difference(&observed_keys).cloned().collect();
        let arrivals: Vec<(DriverType, String, CachedDevice)> = arrival_keys
            .into_iter()
            .filter_map(|key| observed.get(&key).map(|dev| (key.0, key.1, dev.clone())))
            .collect();
        let removals: Vec<(DriverType, String, CachedDevice)> = removal_keys
            .into_iter()
            .filter_map(|key| cache.get(&key).map(|dev| (key.0, key.1, dev.clone())))
            .collect();
        *cache = observed;
        (arrivals, removals)
    }

    /// Mirror of `poll_once`'s connection-aware diff, isolated from the global
    /// singleton. Models the two guarantees: (1) for any paused bus
    /// (a `(driver, type)` with a connected device) the cached entries are
    /// carried forward into `observed` unchanged, and (2) a removal is never
    /// emitted for a key that is still in `connected_keys`. Returns
    /// `(arrivals, removals)` and swaps `cache <- observed` like `poll_once`.
    fn diff_with_connected_for_test(
        cache: &mut DeviceCache,
        mut observed: HashMap<(DriverType, String), CachedDevice>,
        connected_keys: &HashSet<(DriverType, String)>,
        connected_types: &HashSet<(DriverType, DeviceType)>,
    ) -> (
        Vec<(DriverType, String, CachedDevice)>,
        Vec<(DriverType, String, CachedDevice)>,
    ) {
        // Carry-forward: for every paused bus, copy its cached entries into
        // `observed` (simulating "we never re-probed that bus").
        for (key, dev) in cache.iter() {
            if connected_types.contains(&(key.0, dev.device_type)) {
                observed.entry(key.clone()).or_insert_with(|| dev.clone());
            }
        }

        let previous_keys: HashSet<(DriverType, String)> = cache.keys().cloned().collect();
        let observed_keys: HashSet<(DriverType, String)> = observed.keys().cloned().collect();
        let arrival_keys: Vec<(DriverType, String)> =
            observed_keys.difference(&previous_keys).cloned().collect();
        let removal_keys: Vec<(DriverType, String)> = previous_keys
            .difference(&observed_keys)
            .filter(|key| !connected_keys.contains(*key))
            .cloned()
            .collect();
        let arrivals: Vec<(DriverType, String, CachedDevice)> = arrival_keys
            .into_iter()
            .filter_map(|key| observed.get(&key).map(|dev| (key.0, key.1, dev.clone())))
            .collect();
        let removals: Vec<(DriverType, String, CachedDevice)> = removal_keys
            .into_iter()
            .filter_map(|key| cache.get(&key).map(|dev| (key.0, key.1, dev.clone())))
            .collect();
        *cache = observed;
        (arrivals, removals)
    }

    #[test]
    fn connected_device_missing_from_probe_emits_no_removal() {
        // A connected serial mount holds the COM handle, so an SDK enumerate
        // can't see it and `observed` comes back empty for that bus. Without
        // the connected-key guard this produced a spurious `device_lost` and
        // the UI dropped the live device. Assert: no removal.
        let mut cache: DeviceCache = HashMap::new();
        let key = (DriverType::Native, "native:sw:mount0".to_string());
        cache.insert(
            key.clone(),
            CachedDevice {
                device_type: DeviceType::Mount,
                name: "AZ-GTi".to_string(),
                unique_id: None,
                display_name: "AZ-GTi".to_string(),
            },
        );

        let connected_keys: HashSet<(DriverType, String)> = [key.clone()].into_iter().collect();
        let connected_types: HashSet<(DriverType, DeviceType)> =
            [(DriverType::Native, DeviceType::Mount)]
                .into_iter()
                .collect();

        // Probe returned NOTHING for the mount bus (device held the handle).
        let observed: HashMap<(DriverType, String), CachedDevice> = HashMap::new();
        let (arrivals, removals) =
            diff_with_connected_for_test(&mut cache, observed, &connected_keys, &connected_types);

        assert!(
            arrivals.is_empty(),
            "no arrivals expected, got {:?}",
            arrivals
        );
        assert!(
            removals.is_empty(),
            "connected device must NOT produce a removal, got {:?}",
            removals
        );
    }

    #[test]
    fn connected_device_cache_entry_is_carried_forward() {
        // Bus-pause: the connected device's cache entry must survive the poll
        // (carried forward into the new cache) so the device list is not wiped.
        let mut cache: DeviceCache = HashMap::new();
        let key = (DriverType::Native, "native:zwo:cam0".to_string());
        cache.insert(
            key.clone(),
            CachedDevice {
                device_type: DeviceType::Camera,
                name: "ZWO ASI533".to_string(),
                unique_id: Some("usb-533".to_string()),
                display_name: "ZWO ASI533".to_string(),
            },
        );

        let connected_keys: HashSet<(DriverType, String)> = [key.clone()].into_iter().collect();
        let connected_types: HashSet<(DriverType, DeviceType)> =
            [(DriverType::Native, DeviceType::Camera)]
                .into_iter()
                .collect();

        // Probe skipped (paused) -> observed has nothing for that bus.
        let observed: HashMap<(DriverType, String), CachedDevice> = HashMap::new();
        let (_arrivals, removals) =
            diff_with_connected_for_test(&mut cache, observed, &connected_keys, &connected_types);

        assert!(removals.is_empty(), "no removal for paused bus");
        assert!(
            cache.contains_key(&key),
            "connected device cache entry must be carried forward, cache: {:?}",
            cache.keys().collect::<Vec<_>>()
        );
        assert_eq!(
            cache.len(),
            1,
            "cache must retain exactly the carried entry"
        );
    }

    #[test]
    fn unconnected_devices_still_diff_normally() {
        // Regression guard alongside cache_diff_detects_arrival_and_removal:
        // with NO connected devices the connection-aware path must behave
        // identically to the plain diff — arrivals and removals both fire.
        let mut cache: DeviceCache = HashMap::new();
        let gone_key = (DriverType::Native, "native:test:gone".to_string());
        cache.insert(
            gone_key.clone(),
            CachedDevice {
                device_type: DeviceType::Focuser,
                name: "Old Focuser".to_string(),
                unique_id: None,
                display_name: "Old Focuser".to_string(),
            },
        );

        let new_key = (DriverType::Native, "native:test:fresh".to_string());
        let mut observed: HashMap<(DriverType, String), CachedDevice> = HashMap::new();
        observed.insert(
            new_key.clone(),
            CachedDevice {
                device_type: DeviceType::Rotator,
                name: "Fresh Rotator".to_string(),
                unique_id: None,
                display_name: "Fresh Rotator".to_string(),
            },
        );

        // Nothing connected.
        let connected_keys: HashSet<(DriverType, String)> = HashSet::new();
        let connected_types: HashSet<(DriverType, DeviceType)> = HashSet::new();

        let (arrivals, removals) =
            diff_with_connected_for_test(&mut cache, observed, &connected_keys, &connected_types);
        assert_eq!(
            arrivals.len(),
            1,
            "expected the fresh arrival, got {:?}",
            arrivals
        );
        assert_eq!(arrivals[0].1, "native:test:fresh");
        assert_eq!(
            removals.len(),
            1,
            "expected the gone removal, got {:?}",
            removals
        );
        assert_eq!(removals[0].1, "native:test:gone");
    }

    #[test]
    fn cache_diff_detects_arrival_and_removal() {
        // Exercises the (arrivals, removals) computation inside poll_once
        // against a LOCAL cache map (not the global singleton) so this test
        // is isolated from `trigger_rescan_executes_a_diff_pass` which can
        // run concurrently and mutate the global cache. The diff logic
        // itself is what we are pinning down — see `diff_for_test`.

        let mut cache: DeviceCache = HashMap::new();

        // Seed with a baseline device.
        let baseline_key = (DriverType::Native, "native:test:baseline".to_string());
        let baseline_dev = CachedDevice {
            device_type: DeviceType::Camera,
            name: "Baseline Cam".to_string(),
            unique_id: Some("baseline-uid".to_string()),
            display_name: "Baseline Cam".to_string(),
        };
        cache.insert(baseline_key.clone(), baseline_dev.clone());

        // Observed set drops the baseline and introduces a new mount.
        let new_key = (DriverType::Native, "native:test:new".to_string());
        let new_dev = CachedDevice {
            device_type: DeviceType::Mount,
            name: "New Mount".to_string(),
            unique_id: None,
            display_name: "New Mount".to_string(),
        };
        let mut observed: HashMap<(DriverType, String), CachedDevice> = HashMap::new();
        observed.insert(new_key.clone(), new_dev.clone());

        let (arrivals, removals) = diff_for_test(&mut cache, observed);
        assert_eq!(
            arrivals.len(),
            1,
            "expected one arrival, got {:?}",
            arrivals
        );
        assert_eq!(arrivals[0].1, "native:test:new");
        assert_eq!(arrivals[0].2.device_type, DeviceType::Mount);
        assert_eq!(
            removals.len(),
            1,
            "expected one removal, got {:?}",
            removals
        );
        assert_eq!(removals[0].1, "native:test:baseline");

        // Re-running with the same observed set must produce no arrivals
        // and no removals — the cache update inside the diff scope is what
        // makes the system idempotent across polls.
        let mut observed2: HashMap<(DriverType, String), CachedDevice> = HashMap::new();
        observed2.insert(new_key.clone(), new_dev.clone());
        let (arrivals2, removals2) = diff_for_test(&mut cache, observed2);
        assert!(
            arrivals2.is_empty(),
            "second poll must not re-emit arrivals, got {:?}",
            arrivals2
        );
        assert!(
            removals2.is_empty(),
            "second poll must not re-emit removals, got {:?}",
            removals2
        );
    }

    #[test]
    fn trigger_rescan_executes_a_diff_pass() {
        // trigger_rescan is what the equipment-screen Rescan button and the
        // OS bus listener both route through. The contract is "running this
        // performs a full diff cycle now". We can't fake the vendor SDK
        // calls inside poll_once, but we can verify that the call completes
        // without panicking and leaves the device cache in a defined
        // (possibly empty) state — which is the actual observable behaviour
        // for callers.

        // Pre-condition: cache exists (singleton initialised).
        let cache = device_cache();
        cache.lock().unwrap().clear();

        // trigger_rescan is async; build a single-threaded runtime to drive
        // it without depending on the bridge's global runtime singleton.
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("test runtime should build");
        rt.block_on(trigger_rescan());

        // Post-condition: cache is reachable (the call didn't poison the
        // mutex) and the function returned without unwinding. The cache
        // contents depend on whether any vendor SDK responded on the test
        // host, so we don't assert on length — just on liveness.
        let _snapshot: Vec<_> = cache.lock().unwrap().keys().cloned().collect();
    }
}
