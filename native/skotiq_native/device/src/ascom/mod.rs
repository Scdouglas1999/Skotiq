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

pub mod cover_calibrator;
pub mod dome;
mod errors;
pub mod interfaces;
pub mod members;
pub mod observing_conditions;
mod types;

pub use errors::classify_error_number;
pub use types::*;

use crate::DriverError;

/// A member the device may lack: `NotImplemented` reads as `None`, any other
/// failure stays a failure.
pub fn optional<T>(read: Result<T, DriverError>) -> Result<Option<T>, DriverError> {
    match read {
        Ok(value) => Ok(Some(value)),
        Err(DriverError::NotSupported) => Ok(None),
        Err(error) => Err(error),
    }
}
