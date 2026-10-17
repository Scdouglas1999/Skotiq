//! Device Manager with connection state management and auto-reconnection
//!
//! Provides a unified interface for managing device connections across
//! different driver backends (ASCOM, Alpaca, INDI, Native vendor SDKs).
//!
//! This module is the residual shell: it holds the `DeviceManager` and
//! `ManagedDevice` struct definitions, configuration types, constructors, and
//! lightweight query helpers (`get_all_devices`, `get_devices_by_type`,
//! `get_device`, `is_connected`). Heavier method groups live in sibling
//! submodules using Rust's split-impl-block feature:
//!
//! - `connection` — `register_device`, `connect_device`, `disconnect_device`,
//!   `reconnection_loop`, `set_auto_reconnect`, `report_error`, `shutdown`,
//!   `unregister_device`.
//! - `api_version` — cached `DeviceApiVersion` access + `query_*` dispatch +
//!   `device_supports_*` predicates.
//! - Per-driver `connect_*` and `query_*_api_version` helpers live in
//!   `crate::dispatch::{ascom,alpaca,indi,native}`.

pub(crate) mod api_version;
pub(crate) mod connection;
pub(crate) mod epoch;
pub(crate) mod heartbeat;
pub mod identity;
pub(crate) mod ops;

use crate::device::*;
use crate::state::SharedAppState;
use skotiq_native::traits::{
    NativeCamera, NativeDevice, NativeFilterWheel, NativeFocuser, NativeMount,
};
// Vendor SDK imports moved to crate::dispatch::native (the only consumer of
// the camera/mount/filter wheel/focuser constructors).
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

/// Configuration for automatic reconnection
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

/// Configuration for heartbeat monitoring (per device type)
#[derive(Debug, Clone, Copy)]
#[flutter_rust_bridge::frb]
pub struct HeartbeatConfig {
    /// Base interval between heartbeats in seconds (default: 10)
    pub base_interval_secs: u64,
    /// Maximum interval (after backoff) in seconds (default: 60)
    pub max_interval_secs: u64,
    /// Number of consecutive failures before marking device disconnected (default: 3)
    pub failure_threshold: u32,
    /// Backoff multiplier when failures occur (default: 2.0)
    pub backoff_multiplier: f64,
    /// Whether to attempt automatic reconnection after disconnect (default: false)
    pub auto_reconnect: bool,
    /// Maximum number of reconnection attempts (0 = unlimited, default: 3)
    pub max_reconnect_attempts: u32,
    /// Delay before first reconnection attempt in seconds (default: 5)
    pub reconnect_delay_secs: u64,
    /// Whether crossing `failure_threshold` tears the device down (disconnect
    /// + reconnection loop) or merely latches a `Degraded` "stale" status while
    /// keeping the device connected and monitored.
    ///
    /// `true` where liveness is itself a signal the run depends on: a dead
    /// camera stalls every frame, a dead mount drifts off target or slews into
    /// the pier, and a dead accessory left registered as Connected is worse than
    /// one being reconnected — escalating hands the device to the auto-reconnect
    /// and recovery machinery. Slow, USB-contention-prone auxiliaries reach that
    /// point later, through higher failure thresholds, a per-poll retry and
    /// suppression during camera USB contention.
    ///
    /// `false` only where another path already carries the real signal: safety
    /// monitors read `IsSafe` on their own fail-closed paths, so a missed
    /// liveness ping earns a stale badge and nothing more.
    ///
    /// Defaults to `true`, so a device type that does not explicitly opt out
    /// escalates rather than staying registered as Connected while dead.
    pub escalate_to_disconnect: bool,
}

impl Default for HeartbeatConfig {
    fn default() -> Self {
        Self {
            base_interval_secs: 10,
            max_interval_secs: 60,
            failure_threshold: 3,
            // Default to fixed cadence; device-specific constructors may
            // select exponential backoff when that better fits the hardware.
            backoff_multiplier: 1.0,
            auto_reconnect: false,
            max_reconnect_attempts: 3,
            reconnect_delay_secs: 5,
            escalate_to_disconnect: true,
        }
    }
}

impl HeartbeatConfig {
    /// Create a new config with the specified interval
    pub fn with_interval(interval_secs: u64) -> Self {
        Self {
            base_interval_secs: interval_secs,
            ..Default::default()
        }
    }

    /// Create a config with auto-reconnect enabled
    pub fn with_auto_reconnect(mut self, enabled: bool) -> Self {
        self.auto_reconnect = enabled;
        self
    }

    /// Set the failure threshold
    pub fn with_failure_threshold(mut self, threshold: u32) -> Self {
        self.failure_threshold = threshold;
        self
    }

    /// Set max reconnection attempts
    pub fn with_max_reconnect_attempts(mut self, attempts: u32) -> Self {
        self.max_reconnect_attempts = attempts;
        self
    }

    /// Camera liveness checks keep a fixed cadence after failures.
    pub fn for_camera() -> Self {
        Self {
            base_interval_secs: 10,
            max_interval_secs: 60,
            failure_threshold: 3,
            // Three failed polls already debounce transient errors; backing off
            // adds another 40 seconds before confirming a lost camera.
            backoff_multiplier: 1.0,
            auto_reconnect: false,
            max_reconnect_attempts: 3,
            reconnect_delay_secs: 10,
            // Liveness genuinely matters: a dead camera stalls every frame, so
            // a sustained heartbeat loss should escalate to disconnect/recovery.
            escalate_to_disconnect: true,
        }
    }

    /// Create config optimized for mounts (frequent for tracking status)
    pub fn for_mount() -> Self {
        Self {
            base_interval_secs: 5,
            max_interval_secs: 30,
            // One transient timeout pair must not drop a tracking mount: the
            // ASCOM probe shares a process-wide STA worker thread, so a slow
            // driver call can starve a single get_tracking() round-trip. The
            // sequencer's own slew/sync calls surface a genuinely dead mount
            // sooner than the heartbeat anyway.
            failure_threshold: 3,
            backoff_multiplier: 1.5,
            auto_reconnect: true, // Mounts should auto-reconnect to maintain tracking
            max_reconnect_attempts: 5,
            reconnect_delay_secs: 3,
            // Liveness genuinely matters: a dead mount drifts off target and can
            // slew into the pier, so escalate to disconnect/recovery on loss.
            escalate_to_disconnect: true,
        }
    }

    /// Create config optimized for focusers (relatively stable)
    pub fn for_focuser() -> Self {
        Self {
            base_interval_secs: 15,
            max_interval_secs: 60,
            // Why: tolerate transient single-client USB contention (e.g. NINA
            // briefly holding the focuser). Each poll is also retried once.
            failure_threshold: 5,
            // Five consecutive, double-probed misses already provide strong
            // debounce. Keep polling at a fixed cadence so a genuinely dead
            // focuser is recovered in ~75s instead of several minutes.
            backoff_multiplier: 1.0,
            auto_reconnect: false,
            max_reconnect_attempts: 2,
            reconnect_delay_secs: 5,
            // Per-poll retry + camera-contention suppression handle transient
            // misses. Five sustained failures mean the registry must demote
            // the device so the Dart reconnect owner can recover it.
            escalate_to_disconnect: true,
        }
    }

    /// Create config optimized for filter wheels (rarely polled)
    pub fn for_filter_wheel() -> Self {
        Self {
            base_interval_secs: 20,
            max_interval_secs: 120,
            // Why: tolerate transient single-client USB contention (e.g. NINA
            // briefly holding the filter wheel). Each poll is retried once.
            failure_threshold: 5,
            // Fixed cadence recovers a genuinely lost wheel in ~100s while
            // retaining five consecutive double-probed misses as debounce.
            backoff_multiplier: 1.0,
            auto_reconnect: false,
            max_reconnect_attempts: 2,
            reconnect_delay_secs: 5,
            // Do not leave an unresponsive wheel in the connected inventory
            // indefinitely; sustained failures trigger Dart-owned reconnect.
            escalate_to_disconnect: true,
        }
    }

    /// Create config optimized for domes (slow operations, need patience)
    pub fn for_dome() -> Self {
        Self {
            base_interval_secs: 15,
            max_interval_secs: 90,
            failure_threshold: 4,
            backoff_multiplier: 2.0,
            auto_reconnect: true, // Domes should auto-reconnect for safety
            max_reconnect_attempts: 5,
            reconnect_delay_secs: 10,
            // Domes are a safety-relevant enclosure (rain/roof): keep today's
            // escalate-on-loss behavior so recovery runs.
            escalate_to_disconnect: true,
        }
    }

    /// Create config optimized for rotators
    pub fn for_rotator() -> Self {
        Self {
            base_interval_secs: 15,
            max_interval_secs: 60,
            // Why: tolerate transient single-client USB contention (e.g. NINA
            // briefly holding the rotator). Each poll is retried once.
            failure_threshold: 5,
            backoff_multiplier: 1.0,
            auto_reconnect: false,
            max_reconnect_attempts: 2,
            reconnect_delay_secs: 5,
            // Sustained failures must demote stale registry state so the Dart
            // reconnect owner can restore the rotator.
            escalate_to_disconnect: true,
        }
    }

    /// Create config optimized for weather stations (infrequent updates acceptable)
    pub fn for_weather() -> Self {
        Self {
            base_interval_secs: 30,
            max_interval_secs: 180,
            failure_threshold: 5,
            backoff_multiplier: 2.0,
            auto_reconnect: true, // Weather monitoring should auto-reconnect
            max_reconnect_attempts: 10,
            reconnect_delay_secs: 15,
            // Safety-relevant (clouds/rain): keep escalate-on-loss so recovery
            // runs and the session can react.
            escalate_to_disconnect: true,
        }
    }

    /// Create config for safety monitors.
    ///
    /// IMPORTANT: this heartbeat is only a LIVENESS ping. A SafetyMonitor's
    /// actual safety signal (`IsSafe`) is read on its OWN paths — the Dart
    /// environment poll and, during a run, the sequencer's fail-closed safety
    /// check — NOT via this heartbeat.
    ///
    /// So liveness is treated like the focuser/filter-wheel/rotator: latch a
    /// Degraded "stale" badge and KEEP monitoring, never tear the device down
    /// on a missed ping. On an aggressive escalate-to-disconnect config a flaky
    /// network hub missing the occasional ping drives an endless
    /// disconnect -> error -> reconnect cycle, each iteration emitting fresh
    /// error toasts. Genuine loss of safety is still caught by the real
    /// `IsSafe` read, which fails closed during a run.
    pub fn for_safety_monitor() -> Self {
        Self {
            base_interval_secs: 15,
            max_interval_secs: 60,
            failure_threshold: 4,
            backoff_multiplier: 2.0,
            auto_reconnect: false,
            max_reconnect_attempts: 2,
            reconnect_delay_secs: 10,
            escalate_to_disconnect: false,
        }
    }

    /// Create config optimized for guiders (critical during active guiding)
    pub fn for_guider() -> Self {
        Self {
            base_interval_secs: 5,
            max_interval_secs: 30,
            failure_threshold: 2,
            backoff_multiplier: 1.5,
            auto_reconnect: true,
            max_reconnect_attempts: 5,
            reconnect_delay_secs: 3,
            // Guiding liveness is critical during an exposure: escalate on loss
            // so recovery runs rather than silently letting guiding lapse.
            escalate_to_disconnect: true,
        }
    }

    /// Create config optimized for switch devices (slow-changing power/relay state)
    pub fn for_switch() -> Self {
        Self {
            base_interval_secs: 20,
            max_interval_secs: 120,
            // Why: tolerate transient single-client USB contention (e.g. NINA
            // briefly holding the switch); with 2.0 backoff + 20s base, 5
            // failures is well over a minute of genuine unresponsiveness.
            failure_threshold: 5,
            backoff_multiplier: 2.0,
            auto_reconnect: false,
            max_reconnect_attempts: 2,
            reconnect_delay_secs: 5,
            // A switch often controls rig power (dew heaters, the mount's own
            // supply). Keep escalate-on-loss so a genuinely-gone power controller
            // surfaces loudly rather than silently latching "stale". The raised
            // failure_threshold already absorbs transient USB contention.
            escalate_to_disconnect: true,
        }
    }

    /// Create config optimized for cover calibrators (session-safety accessory)
    pub fn for_cover_calibrator() -> Self {
        Self {
            base_interval_secs: 10,
            max_interval_secs: 60,
            failure_threshold: 3,
            backoff_multiplier: 2.0,
            auto_reconnect: true,
            max_reconnect_attempts: 5,
            reconnect_delay_secs: 5,
            // Session-safety accessory (flat panel / dust cover): keep
            // escalate-on-loss so recovery runs.
            escalate_to_disconnect: true,
        }
    }

    /// Get configuration for a specific device type
    pub fn for_device_type(device_type: &DeviceType) -> Self {
        match device_type {
            DeviceType::Camera => Self::for_camera(),
            DeviceType::Mount => Self::for_mount(),
            DeviceType::Focuser => Self::for_focuser(),
            DeviceType::FilterWheel => Self::for_filter_wheel(),
            DeviceType::Dome => Self::for_dome(),
            DeviceType::Rotator => Self::for_rotator(),
            DeviceType::Weather => Self::for_weather(),
            DeviceType::SafetyMonitor => Self::for_safety_monitor(),
            DeviceType::Guider => Self::for_guider(),
            DeviceType::Switch => Self::for_switch(),
            DeviceType::CoverCalibrator => Self::for_cover_calibrator(),
        }
    }
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

// INDI device-type inference helpers were moved to `crate::dispatch::indi`.

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
    /// Whether heartbeat monitoring is active
    pub heartbeat_active: bool,
    /// Cached API version information for the device
    pub api_version: Option<DeviceApiVersion>,
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

    /// Reconnection configuration
    reconnect_config: ReconnectConfig,

    /// Flag to stop the reconnection task
    stop_reconnect: Arc<RwLock<bool>>,

    /// Active native device instances
    // Visibility bumped to pub(crate) so dispatch/native.rs can insert connected
    // generic NativeDevice handles without an extra accessor layer.
    pub(crate) native_devices: RwLock<HashMap<String, Box<dyn NativeDevice>>>,

    /// Active ASCOM camera wrappers (for typed access, wrapped in RwLock for interior mutability)
    #[cfg(windows)]
    /// Active ASCOM camera wrappers (for typed access, wrapped in RwLock for interior mutability)
    // Visibility bumped to pub(crate) so dispatch/ascom.rs can manage the typed
    // wrappers directly during connect / query / health-check paths.
    #[cfg(windows)]
    pub(crate) ascom_cameras:
        RwLock<HashMap<String, Arc<RwLock<crate::ascom_wrapper::camera::AscomCameraWrapper>>>>,

    /// Active ASCOM mount wrappers
    #[cfg(windows)]
    pub(crate) ascom_mounts:
        RwLock<HashMap<String, Arc<RwLock<crate::ascom_wrapper::mount::AscomMountWrapper>>>>,

    /// Active ASCOM focuser wrappers
    #[cfg(windows)]
    pub(crate) ascom_focusers:
        RwLock<HashMap<String, Arc<RwLock<crate::ascom_wrapper::focuser::AscomFocuserWrapper>>>>,

    /// Active ASCOM filter wheel wrappers
    #[cfg(windows)]
    pub(crate) ascom_filter_wheels: RwLock<
        HashMap<String, Arc<RwLock<crate::ascom_wrapper::filterwheel::AscomFilterWheelWrapper>>>,
    >,

    /// Active ASCOM rotator wrappers
    #[cfg(windows)]
    pub(crate) ascom_rotators:
        RwLock<HashMap<String, Arc<RwLock<crate::ascom_wrapper::rotator::AscomRotatorWrapper>>>>,

    /// Active ASCOM dome wrappers
    #[cfg(windows)]
    pub(crate) ascom_domes:
        RwLock<HashMap<String, Arc<RwLock<crate::ascom_wrapper::dome::AscomDomeWrapper>>>>,

    /// Active ASCOM weather wrappers
    #[cfg(windows)]
    pub(crate) ascom_weather: RwLock<
        HashMap<
            String,
            Arc<RwLock<crate::ascom_wrapper::weather::AscomObservingConditionsWrapper>>,
        >,
    >,

    /// Active ASCOM safety monitor wrappers
    #[cfg(windows)]
    pub(crate) ascom_safety_monitors: RwLock<
        HashMap<
            String,
            Arc<RwLock<crate::ascom_wrapper::safetymonitor::AscomSafetyMonitorWrapper>>,
        >,
    >,

    /// Active ASCOM switch wrappers
    #[cfg(windows)]
    pub(crate) ascom_switches:
        RwLock<HashMap<String, Arc<RwLock<crate::ascom_wrapper::switch::AscomSwitchWrapper>>>>,

    /// Active ASCOM cover calibrator wrappers
    #[cfg(windows)]
    pub(crate) ascom_cover_calibrators: RwLock<
        HashMap<
            String,
            Arc<RwLock<crate::ascom_wrapper::covercalibrator::AscomCoverCalibratorWrapper>>,
        >,
    >,

    /// Active INDI clients (key: "host:port")
    // Visibility bumped to pub(crate) so dispatch/indi.rs can manage the client
    // pool directly during connect / discover / health-check paths.
    pub(crate) indi_clients: RwLock<HashMap<String, Arc<RwLock<skotiq_indi::IndiClient>>>>,

    /// Active Alpaca camera clients
    // Visibility bumped to pub(crate) so dispatch/alpaca.rs can manage the typed
    // wrappers directly during connect / query / health-check paths.
    pub(crate) alpaca_cameras: RwLock<HashMap<String, Arc<skotiq_alpaca::AlpacaCamera>>>,

    /// Active Alpaca mount clients
    pub(crate) alpaca_mounts: RwLock<HashMap<String, Arc<skotiq_alpaca::AlpacaTelescope>>>,

    /// Active Alpaca focuser clients
    pub(crate) alpaca_focusers: RwLock<HashMap<String, Arc<skotiq_alpaca::AlpacaFocuser>>>,

    /// Active Alpaca filter wheel clients
    pub(crate) alpaca_filter_wheels:
        RwLock<HashMap<String, Arc<skotiq_alpaca::AlpacaFilterWheel>>>,

    /// Active Alpaca rotator clients
    pub(crate) alpaca_rotators: RwLock<HashMap<String, Arc<skotiq_alpaca::AlpacaRotator>>>,

    /// Active Alpaca dome clients
    pub(crate) alpaca_domes: RwLock<HashMap<String, Arc<skotiq_alpaca::AlpacaDome>>>,

    /// Active Alpaca observing conditions (weather) clients
    pub(crate) alpaca_weather:
        RwLock<HashMap<String, Arc<skotiq_alpaca::AlpacaObservingConditions>>>,

    /// Active Alpaca safety monitor clients
    pub(crate) alpaca_safety_monitors:
        RwLock<HashMap<String, Arc<skotiq_alpaca::AlpacaSafetyMonitor>>>,

    /// Active Alpaca switch clients
    pub(crate) alpaca_switches: RwLock<HashMap<String, Arc<skotiq_alpaca::AlpacaSwitch>>>,

    /// Active Alpaca cover calibrator clients
    pub(crate) alpaca_cover_calibrators:
        RwLock<HashMap<String, Arc<skotiq_alpaca::AlpacaCoverCalibrator>>>,

    /// Active Native SDK cameras (stored separately for typed access)
    pub(crate) native_cameras: RwLock<HashMap<String, Box<dyn NativeCamera + Send + Sync>>>,

    /// Active Native SDK focusers (stored separately for typed access)
    pub(crate) native_focusers: RwLock<HashMap<String, Box<dyn NativeFocuser + Send + Sync>>>,

    /// Active Native SDK filter wheels (stored separately for typed access)
    pub(crate) native_filter_wheels:
        RwLock<HashMap<String, Box<dyn NativeFilterWheel + Send + Sync>>>,

    /// Active Native SDK mounts (stored separately for typed access)
    pub(crate) native_mounts: RwLock<HashMap<String, Box<dyn NativeMount + Send + Sync>>>,

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
    /// loop SKIPS polls for the USB-contention-prone auxiliary device types
    /// (focuser, filter wheel, rotator) — the same skip path as a per-device
    /// active operation — so a status read that merely lost a race with the
    /// download is never miscounted as a heartbeat failure.
    ///
    /// A counter (not a bool) so concurrent/overlapping exposures across
    /// multiple cameras nest correctly: contention is "active" until the LAST
    /// exposure window closes. An [`AtomicUsize`] (not a mutex) because the
    /// RAII [`UsbContentionGuard`] decrements it from `Drop`, which cannot
    /// await, and the heartbeat loop only ever reads it.
    pub(crate) usb_contention: Arc<std::sync::atomic::AtomicUsize>,
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
    /// heartbeat loop skips polls for the USB-contention-prone auxiliary device
    /// types (focuser, filter wheel, rotator) — see [`Self::is_usb_contended`]
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

    /// Whether the given device type is one whose heartbeat we suppress during
    /// a camera USB-contention window. These are the slow auxiliary devices
    /// that typically share the camera's USB path (ZWO EAF/EFW behind an ASI
    /// camera, a Pegasus focuser on the same hub, …) and whose liveness polls
    /// lose races with frame downloads. The camera and mount are deliberately
    /// excluded: the camera is the one driving the contention (and we never
    /// want to stop watching it), and the mount is on its own link / matters
    /// for tracking safety.
    pub(crate) fn device_type_suppressed_by_usb_contention(device_type: &DeviceType) -> bool {
        matches!(
            device_type,
            DeviceType::Focuser | DeviceType::FilterWheel | DeviceType::Rotator
        )
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

    /// Create with custom reconnection config
    pub fn with_config(app_state: SharedAppState, config: ReconnectConfig) -> Arc<Self> {
        let manager = Arc::new(Self {
            app_state,
            devices: RwLock::new(HashMap::new()),
            observed_identities: RwLock::new(HashMap::new()),
            reconnect_config: config,
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

    // `parse_indi_device_id` and `indi_mount_tracking_rate` moved to
    // `crate::dispatch::indi` (split-impl-block); call sites use `Self::...`
    // unchanged.
    //
    // Connection lifecycle (reconnection_loop, calculate_backoff_delay,
    // register_device, is_device_registered, get_device_display_name,
    // connect_device, connect_device_internal, connect_simulator,
    // disconnect_device, set_auto_reconnect, report_error, shutdown,
    // unregister_device) moved to `crate::device_manager::connection`.
    //
    // API version helpers (get/set/query_device_api_version,
    // device_supports_version, device_supports_action) moved to
    // `crate::device_manager::api_version`.

    /// Get all managed devices
    pub async fn get_all_devices(&self) -> Vec<ManagedDevice> {
        let devices = self.devices.read().await;
        devices.values().cloned().collect()
    }

    /// Get devices by type
    pub async fn get_devices_by_type(&self, device_type: DeviceType) -> Vec<ManagedDevice> {
        let devices = self.devices.read().await;
        devices
            .values()
            .filter(|d| d.info.device_type == device_type)
            .cloned()
            .collect()
    }

    /// Get a specific device
    pub async fn get_device(&self, device_id: &str) -> Option<ManagedDevice> {
        let devices = self.devices.read().await;
        devices.get(device_id).cloned()
    }

    /// Check if a device is connected
    ///
    /// # `unwrap_or` policy
    ///
    /// Device-not-registered → "not connected". Same rationale as
    /// `state::SharedAppState::is_device_connected`: a tri-state return
    /// (yes/no/unknown) would force every caller to handle an "unknown"
    /// branch that the UI maps back to "not connected" anyway.
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

    /// First connected device id for a type (live `DeviceManager` registry).
    pub async fn first_connected_device_id(&self, device_type: DeviceType) -> Option<String> {
        let devices = self.devices.read().await;
        devices
            .values()
            .find(|d| {
                d.info.device_type == device_type
                    && d.connection_state == ConnectionState::Connected
            })
            .map(|d| d.info.id.clone())
    }

    /// Connected devices for FFI / Dart (`api_get_connected_devices` source of truth).
    pub async fn get_connected_device_infos(&self) -> Vec<DeviceInfo> {
        let devices = self.devices.read().await;
        devices
            .values()
            .filter(|d| d.connection_state == ConnectionState::Connected)
            .map(|d| d.info.clone())
            .collect()
    }

    /// Clone the shared Alpaca HTTP client for a connected device, if present.
    ///
    /// Reads the typed Alpaca maps owned by `DeviceManager` (not the legacy
    /// `ALPACA_CLIENTS` static in `api/connection.rs`).
    pub async fn alpaca_client_for_device(
        &self,
        device_id: &str,
    ) -> Option<Arc<skotiq_alpaca::AlpacaClient>> {
        let registered = self.alpaca_cameras.read().await.contains_key(device_id)
            || self.alpaca_mounts.read().await.contains_key(device_id)
            || self.alpaca_focusers.read().await.contains_key(device_id)
            || self
                .alpaca_filter_wheels
                .read()
                .await
                .contains_key(device_id)
            || self.alpaca_rotators.read().await.contains_key(device_id)
            || self.alpaca_domes.read().await.contains_key(device_id)
            || self.alpaca_weather.read().await.contains_key(device_id)
            || self
                .alpaca_safety_monitors
                .read()
                .await
                .contains_key(device_id)
            || self.alpaca_switches.read().await.contains_key(device_id)
            || self
                .alpaca_cover_calibrators
                .read()
                .await
                .contains_key(device_id);

        if registered {
            Self::alpaca_client_from_device_id(device_id)
        } else {
            None
        }
    }

    /// Construct an Alpaca HTTP client from a canonical device id (legacy API helper).
    fn alpaca_client_from_device_id(
        device_id: &str,
    ) -> Option<Arc<skotiq_alpaca::AlpacaClient>> {
        use crate::device_id::{parse_device_id_cached, ConnectionInfo};
        use skotiq_alpaca::{AlpacaClient, AlpacaDevice, AlpacaDeviceType};

        let parsed = parse_device_id_cached(device_id).ok()?;
        let ConnectionInfo::Alpaca {
            base_url,
            device_type,
            device_num,
            ..
        } = parsed.connection_info
        else {
            return None;
        };
        let alpaca_type = AlpacaDeviceType::from_str(&device_type)?;
        let device = AlpacaDevice {
            device_type: alpaca_type,
            device_number: device_num,
            server_name: base_url.clone(),
            manufacturer: String::new(),
            device_name: String::new(),
            unique_id: device_id.to_string(),
            base_url,
        };
        Some(Arc::new(AlpacaClient::new(&device)))
    }
}

#[cfg(test)]
mod tests;
