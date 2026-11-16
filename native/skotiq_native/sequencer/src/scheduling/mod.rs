//! Target scheduling: the target scorer (now and over a night), the altitude
//! floor, the scheduler's ephemeris and the in-run target triggers.

pub mod adaptive_exposure;
pub mod adaptive_swap;
pub mod altitude_floor;
pub mod astronomy;
pub mod clock;
pub mod ephemeris;
pub mod frame_context;
pub mod integration_budget;
pub mod night_scoring;
pub mod scoring;
pub mod target_trigger;

pub use adaptive_exposure::*;
pub use adaptive_swap::*;
pub use altitude_floor::*;
pub use astronomy::*;
pub use clock::*;
pub use frame_context::*;
pub use integration_budget::*;
pub use night_scoring::*;
pub use scoring::*;
pub use target_trigger::*;
