//! Device vocabulary shared by every driver crate, the sequencer and the bridge.
//!
//! This crate depends on no other Skotiq crate. It holds the words the rest of
//! the workspace uses to talk about devices: kinds, states, the per-device-type
//! driver traits and the driver error.

pub mod ascom;
