//! Public API exposed to Dart via flutter_rust_bridge
//!
//! This module contains all the functions that can be called from Dart.
//! Each function is marked with the appropriate flutter_rust_bridge attributes.

// Submodule declarations (api.rs decomposition).

pub mod connection;
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
pub mod guiding;
pub mod heartbeat;
// `pub(crate)` not `pub`: keep this submodule's name out of the crate-root
// glob (`pub use api::*` in lib.rs) so it doesn't shadow `crate::hotplug`,
// the top-level listener module. The single Dart-callable function inside
// is re-exported by name below.
pub(crate) mod hotplug;
pub mod imaging;
pub mod init;
pub mod mosaic;
pub mod mount_guard;
pub mod phd2;
pub mod plate_solve;
pub mod polar_alignment;
pub mod post_session;
pub mod secondary_rig;
pub mod sequencer;
pub mod sky_atlas;
pub mod storage;
