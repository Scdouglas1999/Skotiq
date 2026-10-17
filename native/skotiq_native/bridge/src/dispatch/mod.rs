//! Per-driver device dispatch modules.
//!
//! The `DeviceManager` defined in `crate::device_manager` keeps the public
//! dispatcher surface (top-level methods that match on `DriverType` and route
//! per device ID). Driver-specific helper methods live here, one module per
//! driver, split across impl blocks.
//!
//! Each module is `pub(crate)` and contributes additional methods to
//! `impl DeviceManager`; none of them adds public surface.

pub(crate) mod error;
pub use error::DeviceOpError;

pub(crate) mod alpaca;
pub(crate) mod alpaca_device_common;
pub(crate) mod ascom;
// `ascom_device_common` only contains `DeviceCommonMetadata` trait impls for the
// typed ASCOM COM wrappers in `crate::ascom_wrapper`, which exist only on
// Windows. Gating the whole module keeps it off non-Windows targets where those
// wrapper types (and the underlying COM) don't exist.
#[cfg(windows)]
pub(crate) mod ascom_device_common;
pub(crate) mod device_common_metadata;
pub(crate) mod indi;
pub(crate) mod native;
