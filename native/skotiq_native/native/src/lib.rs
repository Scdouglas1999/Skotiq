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
//! Vendor SDKs are not thread-safe. Each SDK's function table can only be
//! reached through a guard that holds that SDK's lock; see
//! `vendor::sdk_loader`.

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
pub(crate) mod camera_core;
pub mod catalog;
pub mod discovery;
pub mod quirks;
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
pub use traits::*;
pub use utils::*;
pub use vendor::*;
