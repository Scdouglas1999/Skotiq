//! Public API exposed to Dart via flutter_rust_bridge
//!
//! This module contains all the functions that can be called from Dart.
//! Each function is marked with the appropriate flutter_rust_bridge attributes.

use crate::device::*;
use crate::device_manager::get_device_manager;
use crate::error::*;
use crate::event::*;
use crate::state::*;

// Submodule declarations (api.rs decomposition).

pub(crate) mod connection;
pub mod darkroom;
pub mod depthlock;
pub mod devices;
pub mod diagnostics;
pub mod difference_image;
pub(crate) mod discovery;
pub mod event_stream;
pub mod finishing_analyze;
pub mod finishing_combine;
pub mod finishing_enhance;
pub mod guiding;
pub(crate) mod heartbeat;
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
pub(crate) mod storage;

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
pub use guiding::*;
pub use heartbeat::*;
// Re-export the hotplug FFI function explicitly rather than glob-importing
// the submodule — `crate::hotplug` (the listener / poll implementation) is
// also a top-level module, and a glob `pub use hotplug::*` would shadow it
// in the crate root namespace.
pub use hotplug::api_rescan_devices;
pub use imaging::*;
pub use init::*;
pub use mosaic::*;
pub use mount_guard::*;
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
pub use sky_atlas::*;
pub use storage::*;
