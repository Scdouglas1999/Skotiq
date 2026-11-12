//! The device registry and the per-device state that goes with it.
//!
//! `DeviceManager` is split over sibling modules: `connection` (register,
//! connect, disconnect, reconnect), `heartbeat`, and `ops/*` (one module per
//! device type). The per-protocol connect and health-check helpers live in
//! `crate::dispatch`.

pub(crate) mod accessory;
pub(crate) mod connection;
pub(crate) mod epoch;
pub(crate) mod handle;
pub(crate) mod heartbeat;
pub mod identity;
pub(crate) mod motion_guard;
pub(crate) mod ops;
pub(crate) mod policy;
pub(crate) mod read_health;
pub(crate) mod rig;
pub(crate) mod simulated;

use crate::device::*;
use crate::state::SharedAppState;
use skotiq_device::DeviceDriver;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

#[derive(Debug, Clone)]
pub struct ReconnectConfig {
    /// Whether auto-reconnection is enabled
    pub enabled: bool,
    /// Maximum number of reconnection attempts (0 = unlimited)
    pub max_attempts: u32,
    /// Initial delay between reconnection attempts
    pub initial_delay_secs: u64,
    /// Maximum delay between reconnection attempts
    pub max_delay_secs: u64,
    /// Backoff multiplier for exponential backoff
    pub backoff_multiplier: f64,
}

/// How a device's heartbeat is run; one value per device type in
/// [`policy::policy`].
#[derive(Debug, Clone, Copy)]
pub struct HeartbeatConfig {
    /// Seconds between heartbeats while the device answers.
    pub base_interval_secs: u64,
    /// Longest interval the backoff grows to, in seconds.
    pub max_interval_secs: u64,
    /// Consecutive failed heartbeats before the device counts as lost.
    pub failure_threshold: u32,
    /// Interval growth per failed heartbeat; 1.0 keeps a fixed cadence.
    pub backoff_multiplier: f64,
    /// Whether a lost device is handed to the reconnection loop.
    pub auto_reconnect: bool,
    /// Whether crossing `failure_threshold` tears the device down (disconnect
    /// and reconnection loop) or only latches a `Degraded` "stale" status
    /// while the device stays connected and monitored.
    pub escalate_to_disconnect: bool,
}

impl Default for ReconnectConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            max_attempts: 10,
            initial_delay_secs: 2,
            max_delay_secs: 60,
            backoff_multiplier: 1.5,
        }
    }
}

/// State of a managed device
#[derive(Debug, Clone)]
pub struct ManagedDevice {
    pub info: DeviceInfo,
    pub connection_state: ConnectionState,
    pub last_error: Option<String>,
    pub reconnect_attempts: u32,
    pub auto_reconnect: bool,
    /// Last successful communication timestamp (milliseconds since epoch)
    pub last_successful_comm: Option<i64>,
    /// When the heartbeat last held off its poll (a camera download on a
    /// shared USB bus, or an operation in flight) while the device was
    /// healthy at its last poll (milliseconds since epoch). A held-off poll
    /// is neither a success nor a failure; cleared by the next failure.
    pub heartbeat_deferred_at: Option<i64>,
    /// Whether heartbeat monitoring is active
    pub heartbeat_active: bool,
    /// Last commanded camera cooler state `(enabled, target_temp_c)`, recorded
    /// whenever `camera_set_cooler` succeeds. Re-applied after an unplanned
    /// reconnect so a USB yank mid-run does not silently leave the sensor
    /// warming up (the driver comes back with the cooler off / setpoint
    /// cleared). `None` until the cooler has been commanded at least once;
    /// cameras only.
    pub desired_cooler: Option<(bool, Option<f64>)>,
    /// Last commanded mount tracking state, recorded whenever
    /// `mount_set_tracking` succeeds. Re-applied after an unplanned reconnect
    /// so a mount that was tracking before the disconnect resumes tracking
    /// instead of sitting parked while the sequence "resumes". `None` until
    /// tracking has been commanded at least once; mounts only.
    pub desired_tracking: Option<bool>,
    /// The equatorial frame the mount's driver declared at its last connect
    /// (ASCOM `EquatorialSystem`). `None` when it declared none Skotiq can
    /// use; [`DeviceManager::mount_frame`] then falls back to the driver
    /// type's frame. Mounts only.
    pub(crate) declared_mount_frame: Option<epoch::MountFrame>,
}

/// The Device Manager handles all device connections
pub struct DeviceManager {
    /// Application state for publishing events
    app_state: SharedAppState,

    /// Managed devices by their ID
    pub(crate) devices: RwLock<HashMap<String, ManagedDevice>>,

    /// Identity last OBSERVED from a live driver, keyed by device id.
    ///
    /// Written only after a successful connect, from what the driver itself
    /// reported — never from `device_info_from_id`, whose name is derived from
    /// the id string and would happily "confirm" a swapped camera. This is the
    /// baseline the next connect for the same id is checked against; see
    /// [`identity`].
    pub(crate) observed_identities: RwLock<HashMap<String, identity::DeviceIdentity>>,

    /// The model the caller that connects an id expects to find there, keyed
    /// by device id (a profile's saved camera name, or the device the user
    /// picked). Takes precedence over [`Self::observed_identities`], whose
    /// entry for an id describes whatever answered it last: after the bus
    /// re-enumerates, that is the device that moved away.
    pub(crate) expected_models: std::sync::Mutex<HashMap<String, String>>,

    reconnect_config: ReconnectConfig,

    /// Flag to stop the reconnection task
    stop_reconnect: Arc<RwLock<bool>>,

    /// The connected devices' handles: every device type but the guider.
    pub(crate) handles: handle::Handles,

    /// A vendor camera registered as a guider, held as a plain device.
    pub(crate) native_devices: RwLock<HashMap<String, Box<dyn DeviceDriver>>>,

    /// Active INDI clients (key: "host:port")
    pub(crate) indi_clients: RwLock<HashMap<String, Arc<RwLock<skotiq_indi::IndiClient>>>>,

    /// Active heartbeat monitoring tasks (device_id -> join handle)
    heartbeat_tasks: RwLock<HashMap<String, tokio::task::JoinHandle<()>>>,

    /// Per-device cancellation tokens for in-flight reconnect attempts.
    ///
    /// The `reconnection_loop` (see `device_manager::connection`) sleeps for
    /// backoff and then issues a `connect_device_internal` call OUTSIDE the
    /// `devices` lock. If a user manually disconnects the device during that
    /// window, `disconnect_device` flips the token to `true` so the reconnect
    /// path bails before publishing a spurious `Connected` event.
    ///
    /// Lock ordering:
    ///   1. `devices`           (read or write)
    ///   2. `reconnect_cancel_tokens`  (read or write)
    ///
    /// Never hold `devices` while awaiting on a token; never hold a token-map
    /// lock across a sleep or a driver dispatch call.
    ///
    /// `disconnect_device` trips the token AFTER releasing the `devices` write
    /// lock (so the reconnect path can acquire it to bail), and the reconnect
    /// loop checks the token both during backoff and immediately after the
    /// driver dispatch returns so a late-arriving `Connected` event from a
    /// just-canceled attempt never reaches subscribers.
    pub(crate) reconnect_cancel_tokens: RwLock<HashMap<String, tokio::sync::watch::Sender<bool>>>,

    /// Device ids that currently have a long-running blocking operation in
    /// flight (e.g. a focuser move). While a device is in this set the
    /// heartbeat loop skips its poll, because a status read contended with the
    /// operation can block, queue behind the move on the single ASCOM STA
    /// thread, or be rejected by the driver — and must not be miscounted as a
    /// heartbeat failure that escalates to a spurious disconnect.
    ///
    /// A plain `std::sync::Mutex` (not a tokio lock) so the RAII
    /// [`OperationGuard`] can clear its entry from `Drop`, which cannot await.
    /// It is only ever held for the duration of a single insert/remove/contains
    /// and never across an `.await`, so it cannot deadlock with the async
    /// device locks.
    pub(crate) active_operations: Arc<std::sync::Mutex<std::collections::HashSet<String>>>,

    /// Number of camera exposure/download windows currently in flight across
    /// the whole rig.
    ///
    /// On shared-USB rigs (a ZWO EAF/EFW behind an ASI camera) the real cause
    /// of transient auxiliary read failures is the camera saturating the USB
    /// bus during frame download. While this counter is non-zero the heartbeat
    /// loop SKIPS polls for the device types that yield to camera USB
    /// ([`policy::DevicePolicy::yields_to_camera_usb`]) — the same skip path as a per-device
    /// active operation — so a status read that merely lost a race with the
    /// download is never miscounted as a heartbeat failure.
    ///
    /// A counter (not a bool) so concurrent/overlapping exposures across
    /// multiple cameras nest correctly: contention is "active" until the LAST
    /// exposure window closes. An [`AtomicUsize`] (not a mutex) because the
    /// RAII [`UsbContentionGuard`] decrements it from `Drop`, which cannot
    /// await, and the heartbeat loop only ever reads it.
    pub(crate) usb_contention: Arc<std::sync::atomic::AtomicUsize>,

    /// Commands in flight per device, and how many have started or ended; the
    /// backstop poll skips a device while one runs and does not report the
    /// change a command made (the command published it). See
    /// [`ops::backstop`].
    pub(crate) command_activity: ops::backstop::CommandActivity,

    /// The last sensor temperature and cooler power published per camera, so
    /// `CameraTemperatureChanged` goes out only when the reading changes.
    pub(crate) published_temperatures: ops::backstop::PublishedTemperatures,

    /// Whether each device's status reads are still succeeding; the heartbeat
    /// counts a run of failures as a failed poll. See [`read_health`].
    pub(crate) status_reads: read_health::StatusReadHealth,
}

/// RAII marker that keeps a device id in [`DeviceManager::active_operations`]
/// for as long as it is alive, clearing it on drop — including on early
/// return, error, or panic — so a marker can never leak and permanently
/// silence a device's heartbeat. Created via [`DeviceManager::begin_operation`].
pub(crate) struct OperationGuard {
    active: Arc<std::sync::Mutex<std::collections::HashSet<String>>>,
    device_id: String,
}

impl Drop for OperationGuard {
    fn drop(&mut self) {
        // A poisoned lock means a previous holder panicked mid-mutation; the
        // set is still structurally valid, so recover the guard via
        // `into_inner` and clear our entry. Failing to clear would leave the
        // device's heartbeat suppressed forever, which is worse than a
        // momentary inconsistency.
        let mut set = match self.active.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        set.remove(&self.device_id);
    }
}

/// RAII marker that keeps the rig in a "USB contention" state (a camera is
/// exposing/downloading) for as long as it is alive, decrementing the
/// [`DeviceManager::usb_contention`] counter on drop — including on early
/// return, error, or panic — so the marker can never leak and permanently
/// silence the auxiliary heartbeats. Created via
/// [`DeviceManager::begin_usb_contention`].
pub(crate) struct UsbContentionGuard {
    counter: Arc<std::sync::atomic::AtomicUsize>,
}

impl Drop for UsbContentionGuard {
    fn drop(&mut self) {
        // `fetch_sub` wraps on underflow; that would only happen if a guard were
        // dropped twice, which the type system prevents (it is moved, not
        // cloned). Relaxed is sufficient: the heartbeat loop tolerates reading a
        // momentarily-stale value (it just polls one tick later or skips one
        // tick early), and there is no other memory we publish through this.
        self.counter
            .fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
    }
}

impl DeviceManager {
    /// Mark the rig as being in a camera exposure/download window until the
    /// returned [`UsbContentionGuard`] is dropped. While the window is open the
    /// heartbeat loop skips polls for the device types that yield to camera USB
    /// ([`policy::DevicePolicy::yields_to_camera_usb`]) — see [`Self::is_usb_contended`]
    /// and `run_heartbeat_loop` — so a status read that merely lost a race with
    /// the frame download on a shared USB bus is not miscounted as a heartbeat
    /// failure. Hold the guard for the full exposure+download window via
    /// `let _contention = mgr.begin_usb_contention();`.
    pub(crate) fn begin_usb_contention(&self) -> UsbContentionGuard {
        self.usb_contention
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        UsbContentionGuard {
            counter: self.usb_contention.clone(),
        }
    }

    /// Whether at least one camera exposure/download window is currently open
    /// (the rig is contending for shared USB bandwidth). The heartbeat loop
    /// consults this for the auxiliary device types so a contended status read
    /// is not counted as a failure.
    pub(crate) fn is_usb_contended(&self) -> bool {
        self.usb_contention
            .load(std::sync::atomic::Ordering::Relaxed)
            > 0
    }

    /// Mark `device_id` as having a blocking operation in flight until the
    /// returned [`OperationGuard`] is dropped. The heartbeat loop skips its
    /// poll for a device with an active operation (see `run_heartbeat_loop`),
    /// so a status read merely contended with the operation is not counted as a
    /// heartbeat failure. Hold the returned guard for the full duration of the
    /// operation (e.g. a focuser move) via `let _op = self.begin_operation(id);`.
    pub(crate) fn begin_operation(&self, device_id: &str) -> OperationGuard {
        let mut set = match self.active_operations.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        set.insert(device_id.to_string());
        drop(set);
        OperationGuard {
            active: self.active_operations.clone(),
            device_id: device_id.to_string(),
        }
    }

    /// Whether a blocking operation (e.g. a focuser move) is currently in
    /// flight for `device_id`. A poisoned lock is treated as "no active
    /// operation" so a panic elsewhere can never wedge the heartbeat into
    /// skipping forever.
    pub(crate) fn is_operation_active(&self, device_id: &str) -> bool {
        self.active_operations
            .lock()
            .map(|set| set.contains(device_id))
            .unwrap_or(false)
    }
}

impl DeviceManager {
    /// Create a new device manager
    pub fn new(app_state: SharedAppState) -> Arc<Self> {
        let manager = Arc::new(Self {
            app_state,
            devices: RwLock::new(HashMap::new()),
            observed_identities: RwLock::new(HashMap::new()),
            expected_models: Default::default(),
            reconnect_config: ReconnectConfig::default(),
            stop_reconnect: Arc::new(RwLock::new(false)),
            handles: Default::default(),
            native_devices: RwLock::new(HashMap::new()),
            indi_clients: RwLock::new(HashMap::new()),
            heartbeat_tasks: RwLock::new(HashMap::new()),
            reconnect_cancel_tokens: RwLock::new(HashMap::new()),
            active_operations: Arc::new(std::sync::Mutex::new(std::collections::HashSet::new())),
            usb_contention: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
            command_activity: Default::default(),
            published_temperatures: Default::default(),
            status_reads: Default::default(),
        });

        // Start the reconnection background task
        // Note: Must have runtime available - ensured by api_init() calling ensure_runtime()
        let manager_clone = Arc::clone(&manager);
        // Get the runtime handle and spawn the task
        // We use the crate-level runtime which must be initialized first
        if let Ok(runtime) = crate::ensure_runtime() {
            runtime.handle().spawn(async move {
                manager_clone.reconnection_loop().await;
            });
        } else {
            tracing::error!("Cannot start reconnection loop: runtime initialization failed");
        }

        manager
    }

    /// Get all managed devices, in [`listing_order`].
    pub async fn get_all_devices(&self) -> Vec<ManagedDevice> {
        let devices = self.devices.read().await;
        let mut all: Vec<ManagedDevice> = devices.values().cloned().collect();
        all.sort_by(|a, b| listing_order(&a.info, &b.info));
        all
    }

    /// Get devices by type, in [`listing_order`].
    pub async fn get_devices_by_type(&self, device_type: DeviceType) -> Vec<ManagedDevice> {
        let devices = self.devices.read().await;
        let mut of_type: Vec<ManagedDevice> = devices
            .values()
            .filter(|d| d.info.device_type == device_type)
            .cloned()
            .collect();
        of_type.sort_by(|a, b| listing_order(&a.info, &b.info));
        of_type
    }

    pub async fn get_device(&self, device_id: &str) -> Option<ManagedDevice> {
        let devices = self.devices.read().await;
        devices.get(device_id).cloned()
    }

    /// The frame a registered mount takes and reports equatorial coordinates
    /// in; `None` for an id that is not registered.
    pub(crate) async fn mount_frame(&self, device_id: &str) -> Option<epoch::MountFrame> {
        let devices = self.devices.read().await;
        devices.get(device_id).map(|device| {
            device
                .declared_mount_frame
                .unwrap_or_else(|| epoch::MountFrame::for_driver(device.info.driver_type))
        })
    }

    /// Records the frame a mount's driver declared at connect, from its ASCOM
    /// `EquatorialSystem` read.
    pub(crate) async fn record_declared_mount_frame<E: std::fmt::Display>(
        &self,
        device_id: &str,
        equatorial_system: Result<i32, E>,
    ) {
        let declared = match equatorial_system {
            Ok(value) => {
                let frame = epoch::MountFrame::from_equatorial_system(value);
                match frame {
                    Some(frame) => tracing::info!(
                        "Mount {device_id} takes and reports {frame} (EquatorialSystem {value})"
                    ),
                    None => tracing::warn!(
                        "Mount {device_id} reports EquatorialSystem {value}, which names no \
                         frame Skotiq converts to; sending it coordinates of date"
                    ),
                }
                frame
            }
            Err(error) => {
                tracing::info!(
                    "Mount {device_id} did not report its EquatorialSystem ({error}); \
                     sending it coordinates of date"
                );
                None
            }
        };
        if let Some(device) = self.devices.write().await.get_mut(device_id) {
            device.declared_mount_frame = declared;
        }
    }

    /// Whether a device is connected. An id that is not registered is not
    /// connected: a third answer would only be mapped back to "not connected"
    /// by every caller.
    pub async fn is_connected(&self, device_id: &str) -> bool {
        let devices = self.devices.read().await;
        devices
            .get(device_id)
            .map(|d| d.connection_state == ConnectionState::Connected)
            .unwrap_or(false)
    }

    /// Whether a device of the given type and id is in the `Connected` state.
    pub async fn is_device_connected(&self, device_type: DeviceType, device_id: &str) -> bool {
        let devices = self.devices.read().await;
        devices
            .get(device_id)
            .map(|d| {
                d.info.device_type == device_type
                    && d.connection_state == ConnectionState::Connected
            })
            .unwrap_or(false)
    }

    /// The connected device of a type that comes first in [`listing_order`]
    /// (live `DeviceManager` registry).
    pub async fn first_connected_device_id(&self, device_type: DeviceType) -> Option<String> {
        let devices = self.devices.read().await;
        devices
            .values()
            .filter(|d| {
                d.info.device_type == device_type
                    && d.connection_state == ConnectionState::Connected
            })
            .map(|d| d.info.id.clone())
            .min()
    }

    /// Connected devices for FFI / Dart (`api_get_connected_devices` source of
    /// truth), in [`listing_order`].
    pub async fn get_connected_device_infos(&self) -> Vec<DeviceInfo> {
        let devices = self.devices.read().await;
        let mut connected: Vec<DeviceInfo> = devices
            .values()
            .filter(|d| d.connection_state == ConnectionState::Connected)
            .map(|d| d.info.clone())
            .collect();
        connected.sort_by(listing_order);
        connected
    }
}

/// The order devices are listed in: by kind, in [`DeviceType`] declaration
/// order, then by id.
///
/// The registry is a hash map, so its own iteration order differs from one
/// process to the next. Without this the same rig lists its devices in a
/// different order after every restart, and "the first connected camera" is
/// whichever of two the hasher happened to put first.
fn listing_order(a: &DeviceInfo, b: &DeviceInfo) -> std::cmp::Ordering {
    (a.device_type as u8)
        .cmp(&(b.device_type as u8))
        .then_with(|| a.id.cmp(&b.id))
}

#[cfg(test)]
mod tests;
