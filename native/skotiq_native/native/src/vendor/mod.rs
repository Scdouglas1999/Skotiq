//! Vendor-specific SDK implementations
//!
//! Each vendor module wraps their SDK and implements the native driver traits.
//!
//! ## SDK loading
//!
//! Path search + library open + symbol resolution + `OnceLock` storage is shared
//! across all vendors via [`sdk_loader`]. New vendors should use the
//! `load_vendor_sdk!` macro instead of duplicating the boilerplate.

// Shared SDK loading infrastructure (trait + macro + path-search helper).
pub mod sdk_loader;

// Camera SDKs
pub mod atik;
pub mod fli;
#[cfg(target_os = "windows")]
pub mod fujifilm;
pub mod gphoto2;
pub mod moravian;
pub mod player_one;
pub mod qhy;
pub mod svbony;
pub mod touptek;
pub mod zwo;

// Mount protocols (serial communication)
pub mod ioptron;
pub mod lx200;
pub mod serial_link;
mod sexagesimal;
pub mod skywatcher;

#[cfg(all(test, target_os = "linux"))]
mod serial_wire_tests;
