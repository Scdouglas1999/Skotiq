//! Native Driver Support
//!
//! Provides direct integration with vendor SDKs (ZWO, QHY, Player One, etc.)
//! without requiring ASCOM, INDI, or Alpaca intermediaries.
//!
//! This module follows a similar architecture to NINA's native driver system,
//! where vendor SDKs are wrapped in a common interface for unified access.
//!
//! ## Thread Safety
//!
//! Vendor SDKs are NOT thread-safe. All SDK operations are protected by
//! per-vendor mutexes in the `sync` module. See `sync.rs` for details.

#![allow(
    clippy::doc_overindented_list_items,
    clippy::duplicated_attributes,
    clippy::empty_line_after_doc_comments,
    clippy::field_reassign_with_default,
    clippy::if_same_then_else,
    clippy::manual_strip,
    clippy::map_identity,
    clippy::needless_range_loop
)]

/// Temporary names for the vocabulary that moved to `skotiq_device`.
pub mod camera {
    pub use skotiq_device::camera::*;
}
pub mod discovery;
pub mod quirks;
pub mod sync;
pub mod traits {
    pub use skotiq_device::{
        CameraDriver as NativeCamera, DeviceDriver as NativeDevice, DriverError as NativeError,
        FilterWheelDriver as NativeFilterWheel, FocuserDriver as NativeFocuser, GuideDirection,
        MountClock, MountDriver as NativeMount, MountSiteInfo, PierSide, TrackingRate,
    };
}
pub use skotiq_device::Vendor as NativeVendor;
pub mod utils;
pub mod vendor;

pub use camera::*;
pub use discovery::*;
pub use quirks::*;
pub use sync::*;
pub use traits::*;
pub use utils::*;
pub use vendor::*;

/// Canonical lower-case vendor tokens accepted by bridge device IDs.
pub const SUPPORTED_NATIVE_VENDORS: &[&str] = &[
    "zwo",
    "zwo_eaf",
    "zwo_efw",
    "qhy",
    "qhy_cfw",
    "playerone",
    "player_one",
    "playerone_pw",
    "svbony",
    "atik",
    "atik_efw",
    "fli",
    "fli_focuser",
    "fli_fw",
    "touptek",
    "moravian",
    "fujifilm",
    "gphoto2",
    "ascom",
    "skywatcher",
    "ioptron",
    "lx200",
    "meade",
    "onstep",
    "losmandy",
    "10micron",
    // Pegasus NYX speaks the OnStep/LX200 mount path; this is a
    // protocol-backed alias, not a standalone Pegasus Astro SDK module.
    "pegasus",
    "builtin_guider",
];

/// Native vendor subtype tokens carried as a separate device ID segment.
pub const NATIVE_VENDOR_SUBTYPES: &[(&str, &[&str])] = &[
    ("zwo", &["eaf", "efw"]),
    ("qhy", &["cfw"]),
    ("atik", &["efw"]),
    ("fli", &["focuser", "fw"]),
];
