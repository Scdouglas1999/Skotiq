//! Processing of frames that are already on disk.
//!
//! Every pipeline here takes its request as JSON and answers in JSON, so a
//! setting added to one rides inside the payload. None of them reaches a
//! device: the bridge's FFI layer forwards the request text and returns the
//! reply.
//!
//! * [`post_session`]: calibration masters, integration of a session's subs,
//!   multi-night masters and their delivery.
//! * [`darkroom`]: recipes rendered over a linear master, for preview and export.
//! * [`finishing`]: night analysis, color calibration, drizzle, background
//!   extraction, deconvolution and star reduction on a master.
//! * [`mosaic`]: panels stitched onto one grid.
//! * [`sky_atlas`]: the all-sky accumulator; [`difference_image`] compares a new
//!   frame against it.

pub mod darkroom;
pub mod difference_image;
pub mod finishing;
pub mod mosaic;
mod output;
pub mod post_session;
mod run_cancel;
pub mod sky_atlas;
