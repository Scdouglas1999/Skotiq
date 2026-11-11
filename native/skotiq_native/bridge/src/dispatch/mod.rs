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
pub(crate) mod ascom;
pub(crate) mod indi;
pub(crate) mod native;
