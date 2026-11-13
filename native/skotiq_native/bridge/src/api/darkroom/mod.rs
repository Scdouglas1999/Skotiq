//! Darkroom FFI surface: validate, render and export a recipe, and the
//! operation catalogue.
//!
//! The service is [`skotiq_processing::darkroom`]. Four entry points are
//! `String -> Result<String, String>` JSON; the preview returns RGBA bytes in
//! the shape the viewer already decodes for a captured frame.

pub mod entrypoints;
