//! Parameter reading with one error taxonomy for every operation.
//!
//! An operation's parameters are a JSON object. Every key is declared once via
//! [`Params::allow`]; every read states its type, its range and its default in
//! the same call, so [`DarkroomOp::validate_params`] and [`DarkroomOp::apply`]
//! cannot disagree about what a payload means.
//!
//! Defaults live in code, not in the stored recipe: a recipe written before a
//! parameter existed renders with that parameter's documented default, and the
//! default is frozen for the life of the operation version.

use std::ops::RangeInclusive;

use serde_json::{Map, Value};

use super::model::{DarkroomOp, OpError};

/// A validated view over one step's parameter object.
pub struct Params<'a> {
    op_id: &'static str,
    op_version: u32,
    map: &'a Map<String, Value>,
}

/// The JSON type name of a value, for error messages.
///
/// Shared with [`super::model::Recipe::from_json`], so the whole recipe surface
/// names a payload the same way whether the object it wanted was the recipe or
/// one operation's parameters.
pub(super) fn type_name(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "a boolean",
        Value::Number(_) => "a number",
        Value::String(_) => "a string",
        Value::Array(_) => "an array",
        Value::Object(_) => "an object",
    }
}

impl<'a> Params<'a> {
    /// Open a parameter object for an operation. A payload that is not an
    /// object is rejected here, including `null`.
    pub fn new(op: &dyn DarkroomOp, params: &'a Value) -> Result<Self, OpError> {
        match params {
            Value::Object(map) => Ok(Self {
                op_id: op.id(),
                op_version: op.version(),
                map,
            }),
            other => Err(OpError::ParamsNotObject {
                op_id: op.id(),
                op_version: op.version(),
                found: type_name(other),
            }),
        }
    }

    /// Reject any key not in `keys`. Called first in `validate_params`, so a
    /// typo in a hand-edited recipe surfaces instead of silently rendering the
    /// default.
    pub fn allow(&self, keys: &[&str]) -> Result<(), OpError> {
        for key in self.map.keys() {
            if !keys.contains(&key.as_str()) {
                return Err(OpError::UnknownParam {
                    op_id: self.op_id,
                    op_version: self.op_version,
                    key: key.clone(),
                });
            }
        }
        Ok(())
    }

    /// Whether the payload carries this key.
    pub fn has(&self, key: &str) -> bool {
        self.map.contains_key(key)
    }

    fn get(&self, key: &str) -> Option<&'a Value> {
        self.map.get(key)
    }

    fn type_error(&self, key: &str, expected: &'static str, found: &Value) -> OpError {
        OpError::ParamType {
            op_id: self.op_id,
            op_version: self.op_version,
            key: key.to_string(),
            expected,
            found: type_name(found),
        }
    }

    fn range_error(&self, key: &str, value: String, range: String) -> OpError {
        OpError::ParamRange {
            op_id: self.op_id,
            op_version: self.op_version,
            key: key.to_string(),
            value,
            range,
        }
    }

    fn missing(&self, key: &str) -> OpError {
        OpError::MissingParam {
            op_id: self.op_id,
            op_version: self.op_version,
            key: key.to_string(),
        }
    }

    /// A finite float inside `range`, falling back to `default` when absent.
    pub fn f64_or(
        &self,
        key: &str,
        range: RangeInclusive<f64>,
        default: f64,
    ) -> Result<f64, OpError> {
        match self.get(key) {
            None => Ok(default),
            Some(value) => self.read_f64(key, value, range),
        }
    }

    /// A finite float inside `range`; the key must be present.
    pub fn f64_required(&self, key: &str, range: RangeInclusive<f64>) -> Result<f64, OpError> {
        let value = self.get(key).ok_or_else(|| self.missing(key))?;
        self.read_f64(key, value, range)
    }

    fn read_f64(
        &self,
        key: &str,
        value: &Value,
        range: RangeInclusive<f64>,
    ) -> Result<f64, OpError> {
        let n = value
            .as_f64()
            .ok_or_else(|| self.type_error(key, "a number", value))?;
        if !n.is_finite() {
            return Err(self.range_error(key, n.to_string(), "a finite number".to_string()));
        }
        if !range.contains(&n) {
            return Err(self.range_error(
                key,
                n.to_string(),
                format!("[{}, {}]", range.start(), range.end()),
            ));
        }
        Ok(n)
    }

    /// A non-negative integer inside `range`, falling back to `default` when
    /// absent.
    pub fn u32_or(
        &self,
        key: &str,
        range: RangeInclusive<u32>,
        default: u32,
    ) -> Result<u32, OpError> {
        match self.get(key) {
            None => Ok(default),
            Some(value) => self.read_u32(key, value, range),
        }
    }

    /// A non-negative integer inside `range`; the key must be present.
    pub fn u32_required(&self, key: &str, range: RangeInclusive<u32>) -> Result<u32, OpError> {
        let value = self.get(key).ok_or_else(|| self.missing(key))?;
        self.read_u32(key, value, range)
    }

    fn read_u32(
        &self,
        key: &str,
        value: &Value,
        range: RangeInclusive<u32>,
    ) -> Result<u32, OpError> {
        let n = value
            .as_u64()
            .ok_or_else(|| self.type_error(key, "a non-negative integer", value))?;
        let n = u32::try_from(n).map_err(|_| {
            self.range_error(
                key,
                n.to_string(),
                format!("[{}, {}]", range.start(), range.end()),
            )
        })?;
        if !range.contains(&n) {
            return Err(self.range_error(
                key,
                n.to_string(),
                format!("[{}, {}]", range.start(), range.end()),
            ));
        }
        Ok(n)
    }

    /// A boolean, falling back to `default` when absent.
    pub fn bool_or(&self, key: &str, default: bool) -> Result<bool, OpError> {
        match self.get(key) {
            None => Ok(default),
            Some(value) => value
                .as_bool()
                .ok_or_else(|| self.type_error(key, "a boolean", value)),
        }
    }

    /// One of `allowed`, falling back to `default` when absent. Returns the
    /// matching entry from `allowed`, so callers match on `&'static str`.
    pub fn enum_or(
        &self,
        key: &str,
        allowed: &[&'static str],
        default: &'static str,
    ) -> Result<&'static str, OpError> {
        let Some(value) = self.get(key) else {
            return Ok(default);
        };
        let s = value
            .as_str()
            .ok_or_else(|| self.type_error(key, "a string", value))?;
        allowed
            .iter()
            .find(|candidate| **candidate == s)
            .copied()
            .ok_or_else(|| self.range_error(key, format!("\"{s}\""), format!("one of {allowed:?}")))
    }

    /// A fixed-length array of finite floats, each inside `range`, falling back
    /// to `default` when absent.
    pub fn f64_array_or(
        &self,
        key: &str,
        len: usize,
        range: RangeInclusive<f64>,
        default: &[f64],
    ) -> Result<Vec<f64>, OpError> {
        let Some(value) = self.get(key) else {
            return Ok(default.to_vec());
        };
        let items = value
            .as_array()
            .ok_or_else(|| self.type_error(key, "an array of numbers", value))?;
        if items.len() != len {
            return Err(self.range_error(
                key,
                format!(
                    "{} element{}",
                    items.len(),
                    if items.len() == 1 { "" } else { "s" }
                ),
                format!("exactly {len} element{}", if len == 1 { "" } else { "s" }),
            ));
        }
        let mut out = Vec::with_capacity(len);
        for item in items {
            out.push(self.read_f64(key, item, range.clone())?);
        }
        Ok(out)
    }

    /// A variable-length array of finite floats, each inside `range`, whose
    /// length lies inside `len_range`, falling back to `default` when absent.
    ///
    /// For a payload whose length is part of its meaning — a tone curve's
    /// control points, where two points and eight points are both valid — as
    /// opposed to [`Params::f64_array_or`], whose length is fixed by the
    /// operation.
    pub fn f64_list_or(
        &self,
        key: &str,
        len_range: RangeInclusive<usize>,
        range: RangeInclusive<f64>,
        default: &[f64],
    ) -> Result<Vec<f64>, OpError> {
        let Some(value) = self.get(key) else {
            return Ok(default.to_vec());
        };
        let items = value
            .as_array()
            .ok_or_else(|| self.type_error(key, "an array of numbers", value))?;
        if !len_range.contains(&items.len()) {
            return Err(self.range_error(
                key,
                format!(
                    "{} element{}",
                    items.len(),
                    if items.len() == 1 { "" } else { "s" }
                ),
                format!("{} to {} elements", len_range.start(), len_range.end()),
            ));
        }
        let mut out = Vec::with_capacity(items.len());
        for item in items {
            out.push(self.read_f64(key, item, range.clone())?);
        }
        Ok(out)
    }
}

#[cfg(test)]
#[path = "params_tests.rs"]
mod params_tests;
