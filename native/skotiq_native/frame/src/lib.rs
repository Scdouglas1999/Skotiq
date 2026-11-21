//! The words every crate uses about a frame, below the drivers, imaging, the
//! sequencer and the bridge: the color filter array of a one-shot-color
//! sensor ([`cfa`]) and the filter-name rule ([`filter_name`]).

pub mod cfa;
pub mod filter_name;

pub use cfa::{BayerColor, BayerPattern, ColorFilterArray, XTransPattern};
pub use filter_name::{filter_bands, match_filter_slot, same_filter, FilterSlotMatch};
