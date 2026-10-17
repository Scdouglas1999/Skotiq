//! Public API exposed to Dart via flutter_rust_bridge
//!
//! This module contains all the functions that can be called from Dart.
//! Each function is marked with the appropriate flutter_rust_bridge attributes.

use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::error::*;
use crate::event::*;
use crate::state::*;
use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

/// Global application state singleton
static APP_STATE: OnceLock<SharedAppState> = OnceLock::new();

/// Get or initialize the global application state
#[flutter_rust_bridge::frb(ignore)]
pub fn get_state() -> &'static SharedAppState {
    APP_STATE.get_or_init(AppState::new)
}

/// Global device manager singleton
static DEVICE_MANAGER: OnceLock<Arc<DeviceManager>> = OnceLock::new();

/// Get or initialize the global device manager
#[flutter_rust_bridge::frb(ignore)]
pub fn get_device_manager() -> &'static Arc<DeviceManager> {
    DEVICE_MANAGER.get_or_init(|| DeviceManager::new(get_state().clone()))
}

// Per-(DeviceType, DriverType) discovery cache

/// Cached outcome of a single (DeviceType, DriverType) discovery scan.
///
/// Each (type, driver) pair has its own entry so that:
///   * Asking for cameras does not force a mount-driver scan.
///   * An error in one backend (e.g. ASCOM) cannot poison another (e.g. Alpaca)
///     for the same device type — each entry holds its own `result`.
///   * Backends that errored still respect the TTL, preventing a tight
///     hammer-the-broken-backend loop; the failure is still surfaced to the
///     caller rather than swallowed.
pub(crate) struct DiscoveryCacheEntry {
    /// Outcome of the last discovery scan: either the discovered devices
    /// (possibly empty if the backend ran cleanly but found nothing) or the
    /// error string from the failing backend.
    pub(crate) result: Result<Vec<DeviceInfo>, String>,
    /// When this entry was last populated.
    pub(crate) timestamp: Instant,
}

/// Global per-pair discovery cache keyed by (device type, driver type).
pub(crate) type DiscoveryCacheMap = HashMap<(DeviceType, DriverType), DiscoveryCacheEntry>;

static DISCOVERY_CACHE: OnceLock<Mutex<DiscoveryCacheMap>> = OnceLock::new();

// Event stream overflow tracking

use std::sync::atomic::AtomicU64;

/// Global counter for total events dropped across all event streams.
/// This is incremented when a receiver falls behind and events are skipped.
static TOTAL_DROPPED_EVENTS: AtomicU64 = AtomicU64::new(0);
static TEMP_FITS_FILE_COUNTER: AtomicU64 = AtomicU64::new(0);

/// How long to cache per-(type, driver) discovery results (60 seconds).
pub(crate) const DISCOVERY_CACHE_TTL: Duration = Duration::from_secs(60);

/// Get or initialize the per-pair discovery cache.
pub(crate) fn get_discovery_cache() -> &'static Mutex<DiscoveryCacheMap> {
    DISCOVERY_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Discovery state to prevent thundering-herd concurrent discovery scans.
/// Held briefly across the scan dispatch loop in `api_discover_devices` so that
/// two simultaneous calls for the same device type do not both run the
/// expensive backend probes; the second caller will see the freshly written
/// cache entries and short-circuit.
static DISCOVERY_IN_PROGRESS: OnceLock<Mutex<()>> = OnceLock::new();

pub(crate) fn get_discovery_lock() -> &'static Mutex<()> {
    DISCOVERY_IN_PROGRESS.get_or_init(|| Mutex::new(()))
}

pub(crate) fn create_unique_temp_fits_path(prefix: &str) -> std::path::PathBuf {
    let counter = TEMP_FITS_FILE_COUNTER.fetch_add(1, Ordering::Relaxed);
    // Why: timestamp `unwrap_or_default()` recovers
    // `Duration::ZERO` on a pre-1970 clock. The atomic `counter` and
    // `process::id()` still guarantee uniqueness — the timestamp is only
    // a secondary disambiguator, so a zero value in that case still
    // produces a valid unique path.
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    std::env::temp_dir().join(format!(
        "{}_{}_{}_{}.fits",
        prefix,
        std::process::id(),
        timestamp,
        counter
    ))
}

/// Invalidate the per-(type, driver) discovery cache, forcing fresh discovery
/// on the next call. Also invalidates the native SDK discovery cache so vendor
/// SDKs are re-queried. Called when the user explicitly requests a rescan and
/// when the hot-plug watcher observes an arrival/removal.
///
/// Note: there is intentionally no separate capability-cache invalidation
/// here. The `device_capabilities` module re-queries each device per call
/// rather than caching, so dropping a cache that does not exist would be a
/// silent no-op — and silent no-ops mask real bugs. If a
/// capability cache is added later, invalidate it explicitly here.
pub async fn api_invalidate_discovery_cache() {
    // Invalidate every per-pair entry.
    let mut cache = get_discovery_cache().lock().await;
    cache.clear();
    // Also invalidate the native vendor SDK cache so it re-queries all SDKs.
    skotiq_native::invalidate_discovery_cache().await;
    tracing::info!("Discovery cache invalidated");
}

// Submodule declarations (api.rs decomposition).

pub(crate) mod api_version;
pub(crate) mod connection;
pub mod darkroom;
pub mod depthlock;
pub mod devices;
pub mod diagnostics;
pub mod difference_image;
pub mod discovery;
pub mod event_stream;
pub mod finishing_analyze;
pub mod finishing_combine;
pub mod finishing_enhance;
pub(crate) mod heartbeat;
// `pub(crate)` not `pub`: keep this submodule's name out of the crate-root
// glob (`pub use api::*` in lib.rs) so it doesn't shadow `crate::hotplug`,
// the top-level listener module. The single Dart-callable function inside
// is re-exported by name below.
pub(crate) mod hotplug;
pub mod imaging;
pub mod init;
pub mod mosaic;
pub mod phd2;
pub mod plate_solve;
pub mod polar_alignment;
pub mod post_session;
pub mod secondary_rig;
pub mod sequencer;
pub mod session;
pub mod sky_atlas;
pub(crate) mod storage;

pub use api_version::*;
pub use connection::*;
// Re-exported by name, not by glob: `darkroom` and `post_session` both carry an
// `entrypoints` submodule, and two globs re-exporting that name make it
// ambiguous at the crate root.
pub use darkroom::{
    api_darkroom_cancel, api_darkroom_registry, api_darkroom_render_export,
    api_darkroom_render_preview, api_darkroom_validate, DarkroomPreview,
};
pub use depthlock::*;
pub use devices::*;
pub use diagnostics::*;
pub use difference_image::*;
pub use discovery::*;
pub use event_stream::*;
pub use finishing_analyze::*;
pub use finishing_combine::*;
pub use finishing_enhance::*;
pub use heartbeat::*;
// Re-export the hotplug FFI function explicitly rather than glob-importing
// the submodule — `crate::hotplug` (the listener / poll implementation) is
// also a top-level module, and a glob `pub use hotplug::*` would shadow it
// in the crate root namespace.
pub use hotplug::api_rescan_devices;
pub use imaging::*;
pub use init::*;
pub use mosaic::*;
pub use phd2::*;
pub use plate_solve::*;
// Both carry an `entrypoints` submodule, so the globs re-export that one NAME
// ambiguously. Only the items matter; nothing references `crate::entrypoints`.
#[allow(ambiguous_glob_reexports)]
pub use polar_alignment::*;
#[allow(ambiguous_glob_reexports)]
pub use post_session::*;
pub use secondary_rig::*;
pub use sequencer::*;
pub use session::*;
pub use sky_atlas::*;
pub use storage::*;
