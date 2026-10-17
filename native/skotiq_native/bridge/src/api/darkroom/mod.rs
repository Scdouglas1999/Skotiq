//! Darkroom FFI surface: validate, render, export, and the operation
//! catalogue.
//!
//! The Darkroom is the interpretation half of the 7.0 pipeline. The data half
//! ends at a linear master, and everything after it lives as a **recipe** — an
//! ordered list of `{opId, opVersion, params, enabled}` records that renders to
//! pixels on demand. This module is the boundary Dart crosses to check a recipe,
//! to see one rendered, and to write one out.
//!
//! # Shape of the boundary
//!
//! Four of the five entry points are the post-session pattern: `String ->
//! Result<String, String>`, `camelCase` JSON decoded with `#[serde(default)]`,
//! so a knob added later rides inside the payload and needs no codegen run.
//!
//! [`api_darkroom_render_preview`] is the exception. It returns pixels, and the
//! buffer `AstroImageViewer` decodes is RGBA bytes plus a width and a height —
//! the same shape the capture display path already hands it. Encoding that
//! buffer as JSON would cost a base64 round trip per parameter drag, so the
//! preview is a typed function and the editor reuses the existing viewer whole.
//!
//! # Entry points
//!
//! * [`api_darkroom_validate`] — check a recipe against this build's operations.
//! * [`api_darkroom_render_preview`] — render at a pyramid level into RGBA.
//! * [`api_darkroom_render_export`] — write a stage to FITS / PNG / JPEG / TIFF
//!   with the recipe recorded in the file and in a `.nsrecipe` sidecar.
//! * [`api_darkroom_registry`] — the operation catalogue and a first-draft
//!   recipe for a master.
//! * [`api_darkroom_cancel`] — raise, read or drop a render's cancel flag.
//!
//! # State
//!
//! Unlike post-session, the Darkroom holds process state: the operation
//! registry, the step-boundary render cache and the base-master pyramid cache,
//! all byte-budgeted, plus the cancellation flags. See [`state`] for the budgets
//! and the lock order.
//!
//! # Honesty
//!
//! A render reports what every step did, including the reason a step was
//! **skipped** — a `color_calibrate` with no photometry on the install says so
//! rather than passing the image through as if it had run. An export names the
//! domain its pixels are in and refuses an 8-bit file for linear pixels unless
//! the caller asks for a screen transfer, which the reply then names.

mod args;
mod catalog;
pub mod entrypoints;
mod export;
mod render;
mod schema;
mod state;

pub use entrypoints::*;

#[cfg(test)]
mod tests;
