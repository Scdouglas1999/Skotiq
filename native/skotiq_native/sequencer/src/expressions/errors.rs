//! Errors returned by the interpolation engine.
//!
//! The resolver never substitutes empty strings for unknown variables: every
//! failure path produces a typed error that names exactly what went wrong so
//! the user can fix their template.

use thiserror::Error;

/// Failure modes for [`crate::expressions::interpolate`].
#[derive(Debug, Error, PartialEq, Eq, Clone)]
pub enum InterpolationError {
    /// The template referenced a variable that the resolver does not know.
    /// The message includes the offending name so the user can correct it.
    #[error(
        "Unknown variable `${{{name}}}` at offset {offset} in template. \
             See the variable catalog for the supported list."
    )]
    UnknownVariable { name: String, offset: usize },

    /// The template referenced a known variable, but the runtime data
    /// required to resolve it is not available (e.g. `${target.alt}` without
    /// a configured observer location).
    #[error("Variable `${{{name}}}` cannot be resolved: {reason}")]
    Unresolvable { name: String, reason: String },

    /// The template contains a malformed placeholder (unbalanced braces,
    /// empty name, etc).
    #[error("Malformed interpolation at offset {offset}: {reason}")]
    Malformed { offset: usize, reason: String },

    /// The format specifier after the colon could not be parsed.
    #[error("Invalid format spec `:{spec}` for `${{{name}}}` at offset {offset}: {reason}")]
    InvalidFormatSpec {
        name: String,
        spec: String,
        offset: usize,
        reason: String,
    },

    /// The format spec was syntactically valid but is not compatible with
    /// the variable's actual type (e.g. `:.2f` applied to a string).
    #[error(
        "Format spec `:{spec}` is incompatible with `${{{name}}}` value type \
         `{value_type}`: {reason}"
    )]
    IncompatibleFormatSpec {
        name: String,
        spec: String,
        value_type: &'static str,
        reason: String,
    },
}
