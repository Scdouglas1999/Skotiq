//! Variable / expression interpolation engine for the sequencer.
//!
//! See [`catalog`] for the canonical list of supported `${...}` placeholders,
//! [`parser`] for the tokenizer, and [`resolver`] for the runtime evaluator.
//!
//! ## Syntax
//!
//! * `${path}` — interpolate a variable. The path is a dotted name like
//!   `target.name`, `exposure.duration`, or `frame`.
//! * `${path:spec}` — interpolate with a format spec. Two forms are supported:
//!   * Integer padding: `${frame:04}` → `"0008"` (4-digit zero-pad).
//!   * Fixed-point precision: `${target.alt:.1f}` → `"42.7"`.
//! * `$${` — literal `${`. The doubled `$` escapes interpolation.
//!
//! Unknown variables throw an `InterpolationError`; there is no silent
//! fallback.
//!
//! ## Integration
//!
//! The `interpolate` entry point is called from:
//! * `node::instructions::run_script` (script arguments + env vars)
//! * `node::instructions::notification` (title + message)
//! * `instructions::execute_exposure` (`save_to` template + FITS filename)
//! * `node::runtime` (node display name on lifecycle progress events)

pub mod catalog;
pub mod errors;
pub mod parser;
pub mod resolver;

pub use catalog::{catalog_json, variable_catalog, VariableEntry, VariableGroup};
pub use errors::InterpolationError;
pub use parser::{parse_template, TemplatePart};
pub use resolver::{
    interpolate, interpolate_optional, resolve_variable, EvaluationFrame, VariableValue,
};

/// Convenience: convert a struct that carries the per-frame counters
/// (current frame, exposure config snapshot) into an [`EvaluationFrame`].
///
/// Callers in `expose.rs` build a [`EvaluationFrame`] per-frame and pass it
/// to [`interpolate`]; this keeps the call site free of bookkeeping for the
/// "what is the current frame number" question.
pub use resolver::EvaluationFrame as Frame;

/// Convert a dotted catalog name (`target.alt`, `equipment.focal_length`,
/// `frame`) into the UPPER_SNAKE_CASE form used for `SKOTIQ_*` env vars
/// that RunScript exposes to child processes.
///
/// Examples:
/// * `target.name` → `TARGET_NAME`
/// * `equipment.focal_length` → `EQUIPMENT_FOCAL_LENGTH`
/// * `frame` → `FRAME`
pub fn catalog_name_to_env(name: &str) -> String {
    name.replace('.', "_").to_uppercase()
}

/// Stringify a resolved variable for env-var injection. Floats use the
/// default-render form (e.g. `42.7`, `180` for integer-valued floats).
pub fn format_variable_for_env(value: &VariableValue) -> String {
    match value {
        VariableValue::Str(s) => s.clone(),
        VariableValue::Int(i) => i.to_string(),
        VariableValue::Float(f) => {
            if f.fract() == 0.0 && f.abs() < 1.0e16 {
                format!("{}", *f as i64)
            } else {
                format!("{f}")
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_name_to_env_replaces_dots() {
        assert_eq!(catalog_name_to_env("target.name"), "TARGET_NAME");
        assert_eq!(
            catalog_name_to_env("equipment.focal_length"),
            "EQUIPMENT_FOCAL_LENGTH"
        );
        assert_eq!(catalog_name_to_env("frame"), "FRAME");
        assert_eq!(catalog_name_to_env("session.id"), "SESSION_ID");
    }

    #[test]
    fn format_variable_for_env_renders_each_type() {
        assert_eq!(
            format_variable_for_env(&VariableValue::Str("M42".into())),
            "M42"
        );
        assert_eq!(format_variable_for_env(&VariableValue::Int(8)), "8");
        // Integer-valued floats render without the trailing ".0".
        assert_eq!(format_variable_for_env(&VariableValue::Float(180.0)), "180");
        assert_eq!(format_variable_for_env(&VariableValue::Float(42.7)), "42.7");
    }
}
