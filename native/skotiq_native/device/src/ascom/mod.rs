//! The ASCOM standard, as both transports of it see it.
//!
//! ASCOM devices are reached through COM (`skotiq_ascom`, Windows) or through
//! Alpaca, the same interfaces over HTTP (`skotiq_alpaca`). This module names
//! each member of each device interface once ([`interfaces`]) and holds the
//! ASCOM enumerations ([`types`]); the transport crates generate their
//! wrapper functions from the member lists.

mod errors;
pub mod interfaces;
pub mod members;
mod types;

pub use errors::classify_error_number;
pub use types::*;
