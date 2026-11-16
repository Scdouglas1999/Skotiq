//! Hot-plug FFI surface.
//!
//! Exposes the manual rescan trigger used by the equipment-screen "Rescan
//! equipment" button. See `crate::hotplug`.
//!
//! Why a separate module: the rest of `crate::api` is large and topical
//! (discovery, devices, sequencer, ...). Pulling the rescan entry point into
//! its own file keeps the call graph obvious — every Dart-callable hotplug
//! function lives here, and the implementation it delegates to lives in
//! `crate::hotplug`. No business logic in this file beyond the FFI shim.

use crate::{discovery, hotplug};

/// The equipment-screen "Rescan equipment" button: forget every discovery
/// result, then poll the device lists as the user's scan (see
/// `hotplug::trigger_rescan`), emitting `device_discovered` /
/// `device_lost` for what changed. Returns when the poll is done; one
/// failing backend does not stop the others.
pub async fn api_rescan_devices() {
    tracing::info!("Manual hot-plug rescan triggered from UI");
    discovery::forget().await;
    hotplug::trigger_rescan().await;
}
