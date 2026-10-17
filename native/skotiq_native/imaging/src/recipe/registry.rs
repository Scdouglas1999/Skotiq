//! Operation lookup by `(id, version)`.
//!
//! # Registering an operation
//!
//! Every operation this build can render is listed in [`builtin_ops`]. Adding an
//! operation means adding one line there; nothing discovers operations by
//! scanning, so the set a build renders is readable in one place.
//!
//! # Versions are permanent
//!
//! A registered `(id, version)` pair stays registered for the life of the
//! product. Improving an algorithm ships `op@N+1` and leaves `op@N` in the
//! binary, because a recipe written against `op@N` must keep rendering the
//! pixels it rendered the day it was written. Removing a version silently
//! rewrites finished images; the editor instead offers an explicit per-step
//! upgrade that shows the before and after.

use std::collections::BTreeSet;
use std::sync::Arc;

use super::model::{DarkroomOp, OpMap};
use super::ops;

/// Faults raised while building a registry. Every variant is a programming
/// mistake caught at construction, never at render time.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum RegistryError {
    /// Two operations claim the same `(id, version)`.
    #[error("duplicate registration for {op_id}@{op_version}")]
    DuplicateRegistration {
        /// Operation id.
        op_id: String,
        /// Operation version.
        op_version: u32,
    },
    /// An operation reports version `0`, which no recipe may reference.
    #[error("operation {op_id} registered with version 0; versions start at 1")]
    ZeroVersion {
        /// Operation id.
        op_id: String,
    },
    /// An operation reports an empty id.
    #[error("operation registered with an empty id")]
    EmptyId,
}

/// The set of operations a render may use.
#[derive(Clone, Default)]
pub struct OpRegistry {
    ops: OpMap,
}

impl std::fmt::Debug for OpRegistry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OpRegistry")
            .field("registered", &self.keys())
            .finish()
    }
}

impl OpRegistry {
    /// An empty registry. Renders against it succeed only for recipes with no
    /// enabled steps; every enabled step reports
    /// [`RecipeError::UnknownOp`](super::model::RecipeError::UnknownOp).
    pub fn new() -> Self {
        Self { ops: OpMap::new() }
    }

    /// The registry this build renders with: every operation from
    /// [`builtin_ops`].
    pub fn builtin() -> Result<Self, RegistryError> {
        let mut registry = Self::new();
        for op in builtin_ops() {
            registry.register(op)?;
        }
        Ok(registry)
    }

    /// Add one operation. A second registration of the same `(id, version)` is
    /// rejected rather than overwriting the first.
    pub fn register(&mut self, op: Arc<dyn DarkroomOp>) -> Result<(), RegistryError> {
        let id = op.id();
        if id.is_empty() {
            return Err(RegistryError::EmptyId);
        }
        let version = op.version();
        if version == 0 {
            return Err(RegistryError::ZeroVersion {
                op_id: id.to_string(),
            });
        }
        let key = (id.to_string(), version);
        if self.ops.contains_key(&key) {
            return Err(RegistryError::DuplicateRegistration {
                op_id: id.to_string(),
                op_version: version,
            });
        }
        self.ops.insert(key, op);
        Ok(())
    }

    /// The operation registered as `id@version`.
    pub fn get(&self, id: &str, version: u32) -> Option<&Arc<dyn DarkroomOp>> {
        self.ops.get(&(id.to_string(), version))
    }

    /// The highest version registered for `id`.
    pub fn latest_version(&self, id: &str) -> Option<u32> {
        self.ops
            .keys()
            .filter(|(op_id, _)| op_id == id)
            .map(|(_, version)| *version)
            .max()
    }

    /// Every registered `(id, version)` pair, in sorted order.
    pub fn keys(&self) -> Vec<(String, u32)> {
        self.ops.keys().cloned().collect()
    }

    /// Every distinct operation id, in sorted order.
    pub fn ids(&self) -> Vec<String> {
        self.ops
            .keys()
            .map(|(id, _)| id.clone())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect()
    }

    /// Number of registered `(id, version)` pairs.
    pub fn len(&self) -> usize {
        self.ops.len()
    }

    /// Whether no operation is registered.
    pub fn is_empty(&self) -> bool {
        self.ops.is_empty()
    }
}

/// The operations this build renders, in registration order.
///
/// A line is added here and never removed: a recipe referencing an operation
/// this list no longer carries stops rendering the image it was written for.
/// Operations the v1 vocabulary names but that this list does not yet carry are
/// reported as [`RecipeError::UnknownOp`](super::model::RecipeError::UnknownOp)
/// wherever a recipe asks this build to run them, which is the honest result for
/// a build without them. A step naming one while disabled runs nowhere, so it is
/// listed as unregistered rather than refused.
pub fn builtin_ops() -> Vec<Arc<dyn DarkroomOp>> {
    vec![
        Arc::new(ops::background_extract::BackgroundExtractV1),
        Arc::new(ops::stretch::StretchV1),
        Arc::new(ops::crop::CropV1),
        Arc::new(ops::color_calibrate::ColorCalibrateV1),
        Arc::new(ops::denoise::DenoiseV1),
        Arc::new(ops::star_reduce::StarReduceV1),
        Arc::new(ops::saturation::SaturationV1),
        Arc::new(ops::curves::CurvesV1),
    ]
}

#[cfg(test)]
#[path = "registry_tests.rs"]
mod registry_tests;
