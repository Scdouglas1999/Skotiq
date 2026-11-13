//! The ASCOM standard, as both transports of it see it.
//!
//! ASCOM devices are reached through COM (`skotiq_ascom`, Windows) or through
//! Alpaca, the same interfaces over HTTP (`skotiq_alpaca`). This module names
//! each member of each device interface once ([`interfaces`]) and holds the
//! ASCOM enumerations ([`types`]); the transport crates generate their
//! wrapper functions from the member lists. Where using a member takes more
//! than calling it (which members a device may leave unimplemented, when an
//! asynchronous move has finished), the rule is written once here, over the
//! transport's calls.

pub mod camera;
pub mod cover_calibrator;
mod device_type;
pub mod dome;
mod errors;
pub mod interfaces;
pub mod members;
pub mod observing_conditions;
pub mod sensor_type;
pub mod telescope;
mod types;

pub use device_type::AscomDeviceType;
pub use errors::classify_error_number;
pub use types::*;

use crate::DriverError;

/// A failure that says the device has no such member (ASCOM
/// `NotImplemented`, Alpaca error 0x400), in a layer's own error type.
pub trait NotImplemented {
    fn is_not_implemented(&self) -> bool;
}

impl NotImplemented for DriverError {
    fn is_not_implemented(&self) -> bool {
        matches!(self, DriverError::NotSupported)
    }
}

/// A member the device may lack: `NotImplemented` reads as `None`, any other
/// failure stays a failure.
pub fn optional<T, E: NotImplemented>(read: Result<T, E>) -> Result<Option<T>, E> {
    match read {
        Ok(value) => Ok(Some(value)),
        Err(error) if error.is_not_implemented() => Ok(None),
        Err(error) => Err(error),
    }
}
