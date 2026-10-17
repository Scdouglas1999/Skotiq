//! The operations this build renders.
//!
//! One module per `(id)`; every registered version of an operation lives in the
//! module named after its id, so `op@1` stays beside `op@2` and a recipe written
//! against either keeps rendering. [`super::registry::builtin_ops`] is the only
//! place the set is assembled.

pub mod background_extract;
pub mod color_calibrate;
pub mod crop;
pub mod curves;
pub mod denoise;
pub mod saturation;
pub mod star_reduce;
pub mod stretch;

mod star_detect;
