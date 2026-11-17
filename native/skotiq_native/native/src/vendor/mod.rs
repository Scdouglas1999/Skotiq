//! Vendor-specific SDK implementations
//!
//! Each vendor module wraps their SDK and implements the native driver traits.
//!
//! ## SDK loading
//!
//! Path search, library open, symbol resolution, lazy storage and the lock
//! that serializes calls into each SDK are shared across all vendors via
//! [`sdk_loader`]. New vendors should use the `load_vendor_sdk!` macro instead
//! of duplicating the boilerplate.

// Shared SDK loading infrastructure (slot + guard + macro + path-search helper).
pub mod sdk_loader;

// Camera SDKs
pub mod atik;
pub mod fli;
pub mod fujifilm;
pub mod gphoto2;
pub mod moravian;
pub mod player_one;
pub mod qhy;
pub mod svbony;
pub mod touptek;
pub mod zwo;

/// Whether a camera error, in the words the device layer passed on, means the
/// camera's vendor SDK session is broken: the camera still answers status
/// reads but takes no exposure until it is closed and opened again. Only the
/// ZWO SDK is known to fail this way.
pub fn camera_session_broken(message: &str) -> bool {
    zwo::session_broken(message)
}

// Mount protocols (serial communication)
pub mod ioptron;
pub mod lx200;
pub mod serial_link;
mod sexagesimal;
pub mod skywatcher;

#[cfg(all(test, target_os = "linux"))]
mod serial_wire_tests;
