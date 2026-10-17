//! The Darkroom recipe engine: a non-destructive, replayable operation stack
//! over a linear master.
//!
//! The pipeline splits in two. Calibration, registration, rejection and
//! integration are objective and destructive, and produce the linear master —
//! the irreplaceable artifact. Everything after that is interpretation, and
//! lives here as *data*: a [`Recipe`] of `{opId, opVersion, params, enabled}`
//! records that renders to pixels on demand. A "post-gradient master" or a
//! "starless master" is [`render`] stopped after step `N`, not a file on disk.
//!
//! # Pieces
//!
//! * [`model`] — the wire format, [`OpImage`], [`OpContext`], [`DarkroomOp`].
//! * [`ops`] — the operations themselves, one module per registry id.
//! * [`params`] — one parameter-reading taxonomy for every operation.
//! * [`registry`] — lookup by `(id, version)`; old versions stay forever.
//! * [`render`] — validation and replay, with a per-step-boundary cache.
//! * [`cache`] — the boundary cache, keyed by canonical recipe prefix.
//! * [`pyramid`] — the power-of-two pyramid a preview renders over.
//!
//! # Determinism
//!
//! A recipe replays bit-identically for a fixed `(params, op version)`. Ops read
//! no clock, draw no unseeded randomness, and iterate no unordered collection on
//! a path that reaches a pixel. Improving an algorithm ships `op@N+1` and leaves
//! `op@N` registered, so an image rendered last season renders the same today.
//!
//! # Astrometry
//!
//! [`OpImage`] carries the master's FITS header through every step untouched, so
//! `CRVAL`/`CRPIX`/`CD`/SIP, `DATE-OBS`, `EXPTIME`, `FILTER` and `OBJECT` reach
//! export. An operation that changes geometry updates the geometry keywords it
//! invalidates; one that does not, changes nothing.

pub mod cache;
pub mod model;
pub mod ops;
pub mod params;
pub mod pyramid;
pub mod registry;
pub mod render;

#[cfg(test)]
pub(crate) mod testkit;

#[cfg(test)]
#[path = "determinism_tests.rs"]
mod determinism_tests;

pub use cache::{CacheKey, RenderCache, DEFAULT_CACHE_CAPACITY_BYTES};
pub use model::{
    canonical_json, fingerprint_hex, wcs_from_header, CatalogError, CatalogStar, DarkroomOp,
    OpApplied, OpContext, OpError, OpImage, OpStage, PhotometryCatalog, Recipe, RecipeAuthor,
    RecipeError, RecipeParent, RecipeStep, CANCEL_POLL_PIXELS, RECIPE_SCHEMA_VERSION,
};
pub use params::Params;
pub use pyramid::{downsample_2x, ImagePyramid, DEFAULT_MIN_PYRAMID_DIMENSION};
pub use registry::{builtin_ops, OpRegistry, RegistryError};
pub use render::{
    render, render_full, render_preview, validate, RenderOptions, RenderOutput, RenderReport,
    StepOutcome, StepReport,
};
