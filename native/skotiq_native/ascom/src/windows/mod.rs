//! Windows COM plumbing for ASCOM devices: COM initialization, driver
//! discovery in the registry, and the `IDispatch` connection every device
//! wrapper calls through.

pub mod connection;
pub mod variant;

pub use connection::{discover_devices, init_com, uninit_com, AscomDeviceConnection};
