//! The words every crate uses about a frame, below the drivers, imaging, the
//! sequencer and the bridge: the color filter array of a one-shot-color
//! sensor ([`cfa`]), the filter-name rule ([`filter_name`]), what a frame is
//! ([`frame_type`]) and what its `IMAGETYP` card says it is ([`frame_kind`]).

pub mod cfa;
pub mod filter_name;
pub mod frame_kind;
pub mod frame_type;

pub use cfa::{BayerColor, BayerPattern, ColorFilterArray, XTransPattern};
pub use filter_name::{filter_bands, match_filter_slot, same_filter, FilterSlotMatch};
pub use frame_kind::FrameKind;
pub use frame_type::FrameType;
